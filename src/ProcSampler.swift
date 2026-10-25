import Foundation

// Resolve a PID to a display name, merging all "Foo.app/…" helpers into the
// top-level bundle name "Foo" (so e.g. Chrome's helpers roll up into "Chrome").
// Shared by ProcSampler (CPU) and NetProcSampler (network).
func appDisplayName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)   // 4 * MAXPATHLEN; macro not importable to Swift
    if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
        let path = String(cString: buf)
        if let r = path.range(of: ".app/") {
            let before = path[..<r.lowerBound]
            if let slash = before.lastIndex(of: "/") {
                return String(before[before.index(after: slash)...])
            }
            return String(before)
        }
        return (path as NSString).lastPathComponent
    }
    // Fallback to the (truncated) accounting name, e.g. kernel_task.
    var nameBuf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
    if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
        let n = String(cString: nameBuf)
        if !n.isEmpty { return n }
    }
    return "pid \(pid)"
}

struct ProcUsage: Identifiable {
    var id: String { name }
    let name: String
    let cpu: Double     // percent; 100% == one full core (like Activity Monitor / top)
}

// Each interval contributes its measured duration, so switching between a
// foreground 2s cadence and background 10s cadence does not bias the average.
struct CPUHistory {
    struct Interval { let start: Double; let end: Double; let values: [String: Double] }
    private var intervals: [Interval] = []

    mutating func record(_ values: [String: Double], from start: Double, to end: Double) {
        guard end > start else { return }
        intervals.append(Interval(start: start, end: end, values: values))
        intervals.removeAll { $0.end <= end - 1800 }
        if intervals.count > 1801 { intervals.removeFirst(intervals.count - 1801) }
    }

    func average(window: Double, now: Double) -> [String: Double] {
        if window <= 0 { return intervals.last?.values ?? [:] }
        var sums: [String: Double] = [:]
        var duration = 0.0
        for interval in intervals {
            let weight = min(now, interval.end) - max(now - window, interval.start)
            guard weight > 0 else { continue }
            duration += weight
            for (name, value) in interval.values { sums[name, default: 0] += value * weight }
        }
        guard duration > 0 else { return [:] }
        return sums.mapValues { $0 / duration }
    }
}

// Owned exclusively by the sampling queue. Cache names only for the same
// process incarnation; reused PIDs must not inherit a previous app's counters.
private final class ProcessReader {
    struct Reading { let cpu: UInt64; let birth: UInt64; var name: String? }
    private var previous: [pid_t: Reading] = [:]
    private var previousTime = 0.0
    private var history = CPUHistory()

    func reset() { previous.removeAll(); previousTime = 0 }

    func sample(window: Double) -> [ProcUsage] {
        let now = sampleTime()
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { reset(); return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { reset(); return [] }
        let dt = now - previousTime
        var next: [pid_t: Reading] = [:]
        var values: [String: Double] = [:]
        for pid in pids.prefix(Int(count) / MemoryLayout<pid_t>.stride) where pid > 0 {
            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rc == 0 else { continue }
            let cpu = info.ri_user_time &+ info.ri_system_time
            let old = previous[pid]
            let sameProcess = old?.birth == info.ri_proc_start_abstime
            var reading = Reading(cpu: cpu, birth: info.ri_proc_start_abstime, name: sameProcess ? old?.name : nil)
            if let old, sameProcess, cpu >= old.cpu, previousTime > 0, dt > 0, dt < 60 {
                let percent = Double(cpu - old.cpu) / (dt * 1e9) * 100
                if percent > 0.05 {
                    let name = reading.name ?? appDisplayName(pid)
                    reading.name = name
                    values[name, default: 0] += percent
                }
            }
            next[pid] = reading
        }
        if previousTime > 0, dt > 0, dt < 60 { history.record(values, from: previousTime, to: now) }
        previous = next; previousTime = now
        let ceiling = Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) * 100
        return history.average(window: window, now: now)
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5).map { ProcUsage(name: $0.key, cpu: min(ceiling, $0.value)) }
    }
}

final class ProcSampler: ObservableObject {
    @Published var top: [ProcUsage] = []
    var enabled: Bool {
        get { samplingInterval != nil }
        set { setSamplingInterval(newValue ? (samplingInterval ?? 10) : nil) }
    }
    var windowSeconds: Double = 600
    private(set) var samplingInterval: TimeInterval?
    private let queue = DispatchQueue(label: "com.omnistats.processes", qos: .utility)
    private let reader = ProcessReader()
    private var timer: Timer?
    private var inFlight = false
    private var generation = 0

    init() { setSamplingInterval(10) }
    deinit { timer?.invalidate() }

    func setSamplingInterval(_ interval: TimeInterval?) {
        guard interval != samplingInterval else { return }
        let wasPaused = samplingInterval == nil
        samplingInterval = interval
        generation += 1
        timer?.invalidate(); timer = nil
        if interval == nil || wasPaused {
            queue.async { [reader] in reader.reset() }
        }
        guard let interval else { top = []; return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.15
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if wasPaused { tick() }
    }

    private func tick() {
        guard !inFlight, samplingInterval != nil else { return }
        inFlight = true
        let current = generation, window = windowSeconds
        queue.async { [weak self, reader] in
            let top = reader.sample(window: window)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard self.generation == current else { return }
                self.top = top
            }
        }
    }
}
