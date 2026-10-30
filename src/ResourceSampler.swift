import Foundation
import IOKit
import Darwin

struct CapacityUsage: Equatable {
    let used: Double
    let total: Double
    var fraction: Double { used / total }

    init?(used: Double, total: Double) {
        guard used.isFinite, total.isFinite, total > 0, used >= 0, used <= total else { return nil }
        self.used = used; self.total = total
    }
    func label(binary: Bool) -> String {
        let unit = binary ? 1_073_741_824.0 : 1_000_000_000.0
        return String(format: binary ? "%.1f / %.0f GiB · %.0f%%" : "%.0f / %.0f GB · %.0f%%",
                      used / unit, total / unit, fraction * 100)
    }
}

struct ResourceSnapshot: Equatable {
    var cpuPercent: Double?
    var memory: CapacityUsage?
    var disk: CapacityUsage?
    var gpuPercent: Double?
    var cpuWarmingUp = false
}

struct CPUUsageCounters {
    let user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
}

// Aggregate busy time across all cores, normalized to 0...100 (unlike the
// per-process ranking, where 100% represents one core). Mach ticks wrap at 32
// bits, so subtract each counter modulo 2^32 and sum in 64 bits.
struct SystemCPUUsage {
    private var previous: CPUUsageCounters?
    var needsBaseline: Bool { previous == nil }

    mutating func consume(_ counters: CPUUsageCounters?) -> Double? {
        defer { previous = counters }
        guard let counters, let previous else { return nil }
        let busy = UInt64(counters.user &- previous.user)
            + UInt64(counters.system &- previous.system) + UInt64(counters.nice &- previous.nice)
        let total = busy + UInt64(counters.idle &- previous.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}

// Queue-owned reader. No subprocess, sudo, recursive disk scan or GPU workload.
final class ResourceReader {
    private let host = mach_host_self()
    private var cpuUsage = SystemCPUUsage()
    private var accelerator: io_registry_entry_t = 0
    private var lastGPUDiscovery: TimeInterval = -.infinity
    deinit {
        mach_port_deallocate(mach_task_self_, host)
        if accelerator != 0 { IOObjectRelease(accelerator) }
    }

    func sample() -> ResourceSnapshot {
        let counters = cpuCounters()
        let percent = cpuUsage.consume(counters)
        // Apple Silicon tick counters can stall for up to about a second, so a
        // short follow-up may land in an empty interval. Readable counters
        // without a value yet mean "still warming up", not "unavailable".
        return ResourceSnapshot(cpuPercent: percent, memory: memoryUsage(), disk: diskUsage(),
                                gpuPercent: gpuUsage(), cpuWarmingUp: counters != nil && percent == nil)
    }
    func resetCPU() { cpuUsage = SystemCPUUsage() }

    private func cpuCounters() -> CPUUsageCounters? {
        var statistics = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = statistics.cpu_ticks
        return CPUUsageCounters(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }
    private func memoryUsage() -> CapacityUsage? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        // Anonymous resident + wired + physical compressor pages, excluding
        // purgeable anonymous pages. File cache is reclaimable, not app memory.
        let pages = max(0, Double(statistics.internal_page_count) - Double(statistics.purgeable_count))
            + Double(statistics.wire_count) + Double(statistics.compressor_page_count)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return CapacityUsage(used: min(total, pages * Double(pageSize)), total: total)
    }
    private func diskUsage() -> CapacityUsage? {
        // Data belongs to the startup volume group; do not sum APFS shared volumes.
        let path = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity,
              available >= 0, available <= total else { return nil }
        return CapacityUsage(used: Double(total - available), total: Double(total))
    }
    private func gpuUsage() -> Double? {
        if accelerator == 0, sampleTime() - lastGPUDiscovery >= 60 {
            lastGPUDiscovery = sampleTime()
            accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        }
        guard accelerator != 0 else { return nil }
        guard let property = IORegistryEntryCreateCFProperty(accelerator, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            IOObjectRelease(accelerator); accelerator = 0
            return nil
        }
        // Driver-specific telemetry: missing/invalid counters are unavailable,
        // never reported as zero. No renderer/tiler sum, which can double-count.
        guard let statistics = property as? [String: Any],
              let number = statistics["Device Utilization %"] as? NSNumber else { return nil }
        return Self.validGPUPercent(number.doubleValue)
    }
    static func validGPUPercent(_ value: Double) -> Double? {
        value.isFinite && (0...100).contains(value) ? value : nil
    }
}

final class ResourceSampler: ObservableObject {
    @Published private(set) var snapshot = ResourceSnapshot()
    @Published private(set) var hasSample = false
    private let queue = DispatchQueue(label: "com.omnistats.resources", qos: .utility)
    private let read: () -> ResourceSnapshot
    private let reset: () -> Void
    private var timer: Timer?
    private var inFlight = false
    private var warmups = 0
    // 10 × 0.2 s outlasts the ~1 s counter stalls measured on Apple Silicon.
    static let maximumWarmups = 10
    private var generation = 0
    private(set) var samplingInterval: TimeInterval?

    init(read: (() -> ResourceSnapshot)? = nil) {
        if let read {
            self.read = read
            self.reset = {}
        } else {
            let reader = ResourceReader()
            self.read = { reader.sample() }
            self.reset = { reader.resetCPU() }
        }
    }
    deinit { timer?.invalidate() }
    func setSamplingInterval(_ interval: TimeInterval?) {
        guard interval != samplingInterval else { return }
        let wasPaused = samplingInterval == nil
        samplingInterval = interval; generation += 1; warmups = 0
        timer?.invalidate(); timer = nil
        if interval == nil || wasPaused {
            queue.async { [reset] in reset() }
        }
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        hasSample = false
        refresh()
    }
    private func refresh() {
        guard !inFlight, samplingInterval != nil else { return }
        inFlight = true
        let current = generation
        queue.async { [weak self, read] in
            let value = read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard current == self.generation else {
                    // A quick close/reopen must not wait a full interval to prime.
                    self.refresh(); return
                }
                if self.snapshot != value { self.snapshot = value }
                if !self.hasSample { self.hasSample = true }
                if !value.cpuWarmingUp { self.warmups = 0 }
                if value.cpuWarmingUp, self.warmups < Self.maximumWarmups {
                    // Short follow-ups prime CPU without waiting 10 s or keeping a
                    // fast timer alive while the panel is hidden. Bounded so a
                    // counter that never advances cannot poll forever.
                    self.warmups += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard let self, self.generation == current else { return }
                        self.refresh()
                    }
                }
            }
        }
    }
}
