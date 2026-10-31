import Foundation
import IOKit
import IOKit.ps

// Read-only battery telemetry from the AppleSmartBattery registry entry: no
// root and no SMC. Serial-number fields are never read.
struct BatterySnapshot: Equatable {
    enum State: Equatable { case charging, notCharging, charged, discharging }

    var percent: Int?              // what the macOS battery menu shows
    var hardwarePercent: Double?   // raw remaining ÷ raw full-charge capacity
    var state: State = .discharging
    var timeToFullMinutes: Int?
    var timeToEmptyMinutes: Int?
    var cycleCount: Int?
    var designCycleCount: Int?
    var designCapacity: Int?       // mAh
    var nominalCapacity: Int?      // mAh
    var fullChargeCapacity: Int?   // mAh, what the cells hold today
    var temperature: Double?       // °C
    var voltage: Double?           // V
    var amperage: Double?          // A, negative while discharging
    var adapterWatts: Int?
    var adapterName: String?
    var systemPowerIn: Double?     // W drawn from the adapter
    var systemLoad: Double?        // W used by the whole system
    var adapterLoss: Double?       // W lost converting adapter power

    var externalPower: Bool { state != .discharging }

    // Positive while charging, negative while discharging.
    var batteryPower: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }

    // Nominal full-charge capacity ÷ design capacity. System Settings computes its
    // "Maximum Capacity" on its own schedule, so it can differ by a point or two.
    var health: Double? {
        guard let nominalCapacity, let designCapacity, designCapacity > 0, nominalCapacity > 0 else { return nil }
        return min(100, Double(nominalCapacity) / Double(designCapacity) * 100)
    }
}

extension BatterySnapshot {
    static let registryKeys = [
        "CurrentCapacity", "MaxCapacity", "AppleRawCurrentCapacity", "AppleRawMaxCapacity",
        "ExternalConnected", "IsCharging", "FullyCharged", "AvgTimeToFull", "AvgTimeToEmpty",
        "CycleCount", "DesignCycleCount9C", "DesignCapacity", "NominalChargeCapacity",
        "Temperature", "Voltage", "Amperage", "AdapterDetails", "PowerTelemetryData",
    ]

    // IOKit stores negative currents as 64-bit two's complement, so every integer
    // goes through its bit pattern. Units are mAh, mV, mA, mW and 0.01 °C.
    init(registry: [String: Any]) {
        func int(_ key: String, in dictionary: [String: Any]? = nil) -> Int? {
            ((dictionary ?? registry)[key] as? NSNumber).map { Int(Int64(bitPattern: $0.uint64Value)) }
        }
        func positive(_ key: String, in dictionary: [String: Any]? = nil) -> Int? {
            int(key, in: dictionary).flatMap { $0 > 0 ? $0 : nil }
        }
        func flag(_ key: String) -> Bool { (registry[key] as? NSNumber)?.boolValue ?? false }
        // 65535 means "still estimating"; 0 has no useful meaning either.
        func minutes(_ key: String) -> Int? { int(key).flatMap { $0 > 0 && $0 < 65535 ? $0 : nil } }

        if let current = int("CurrentCapacity"), let maximum = positive("MaxCapacity"), current >= 0 {
            percent = min(100, current * 100 / maximum)
        }
        if let current = int("AppleRawCurrentCapacity"), let full = positive("AppleRawMaxCapacity"), current >= 0 {
            hardwarePercent = min(100, Double(current) / Double(full) * 100)
        }
        if !flag("ExternalConnected") { state = .discharging }
        else if flag("IsCharging") { state = .charging }
        else if flag("FullyCharged") { state = .charged }
        else { state = .notCharging }
        timeToFullMinutes = state == .charging ? minutes("AvgTimeToFull") : nil
        timeToEmptyMinutes = state == .discharging ? minutes("AvgTimeToEmpty") : nil

        cycleCount = int("CycleCount").flatMap { $0 >= 0 ? $0 : nil }
        designCycleCount = positive("DesignCycleCount9C")
        designCapacity = positive("DesignCapacity")
        nominalCapacity = positive("NominalChargeCapacity")
        fullChargeCapacity = positive("AppleRawMaxCapacity")
        temperature = int("Temperature").map { Double($0) / 100 }.flatMap { (-20...100).contains($0) ? $0 : nil }
        voltage = positive("Voltage").map { Double($0) / 1000 }
        amperage = int("Amperage").map { Double($0) / 1000 }

        if externalPower, let adapter = registry["AdapterDetails"] as? [String: Any] {
            adapterWatts = positive("Watts", in: adapter)
            adapterName = (adapter["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let telemetry = registry["PowerTelemetryData"] as? [String: Any] {
            systemPowerIn = int("SystemPowerIn", in: telemetry).flatMap { $0 >= 0 ? Double($0) / 1000 : nil }
            systemLoad = int("SystemLoad", in: telemetry).flatMap { $0 >= 0 ? Double($0) / 1000 : nil }
            adapterLoss = int("AdapterEfficiencyLoss", in: telemetry).flatMap { $0 >= 0 ? Double($0) / 1000 : nil }
        }
    }
}

// Queue-owned reader. Fetches only the keys it needs instead of the whole entry,
// which also carries large per-cell tables.
final class BatteryReader {
    private var service: io_registry_entry_t = 0
    deinit { if service != 0 { IOObjectRelease(service) } }

    static var isPresent: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let installed = IORegistryEntryCreateCFProperty(service, "BatteryInstalled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        return installed ?? true
    }

    // The registry entry, looked up again after it disappears; 0 without a battery.
    var entry: io_registry_entry_t {
        if service == 0 {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        return service
    }

    // Only the requested keys; nil when none of them could be read.
    func read(_ keys: [String]) -> [String: Any]? {
        let service = entry
        guard service != 0 else { return nil }
        var registry: [String: Any] = [:]
        for key in keys {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                registry[key] = value
            }
        }
        guard !registry.isEmpty else {
            // A terminated entry reads as empty; look it up again next time.
            IOObjectRelease(service); self.service = 0
            return nil
        }
        return registry
    }

    func sample() -> BatterySnapshot? { read(BatterySnapshot.registryKeys).map(BatterySnapshot.init(registry:)) }
}

final class BatterySampler: ObservableObject {
    @Published private(set) var snapshot: BatterySnapshot?
    @Published private(set) var hasSample = false
    let isPresent: Bool
    private let queue = DispatchQueue(label: "com.omnistats.battery", qos: .utility)
    private let read: () -> BatterySnapshot?
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var inFlight = false
    private var generation = 0
    private(set) var samplingInterval: TimeInterval?

    init(isPresent: Bool? = nil, read: (() -> BatterySnapshot?)? = nil) {
        if let read {
            self.read = read
        } else {
            let reader = BatteryReader()
            self.read = { reader.sample() }
        }
        self.isPresent = isPresent ?? BatteryReader.isPresent
    }
    deinit {
        timer?.invalidate()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
    }

    func setSamplingInterval(_ interval: TimeInterval?) {
        let interval = isPresent ? interval : nil
        guard interval != samplingInterval else { return }
        samplingInterval = interval; generation += 1
        timer?.invalidate(); timer = nil
        observePowerSources(interval != nil)
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        refresh()
    }

    // Plugging or unplugging the adapter refreshes at once instead of waiting a
    // tick. Registered only while sampling, so a hidden panel gets no wakeups.
    private func observePowerSources(_ enabled: Bool) {
        if !enabled {
            if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
            powerSource = nil
            return
        }
        guard powerSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatterySampler>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
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
                guard current == self.generation else { self.refresh(); return }
                if self.snapshot != value { self.snapshot = value }
                if !self.hasSample { self.hasSample = true }
            }
        }
    }
}

// "1 h 20 min" / "45 min" in the current language.
func formatBatteryMinutes(_ minutes: Int) -> String {
    minutes >= 60 ? L.f("b.hm", minutes / 60, minutes % 60) : L.f("b.m", minutes)
}
