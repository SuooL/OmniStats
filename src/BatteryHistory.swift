import Foundation
import IOKit
import Combine

// Battery history for the charts: one record a minute for 30 days, plus one
// health snapshot a day for a year. The gauge refreshes the AppleSmartBattery
// entry every 60 s and posts a status message on the service each time
// (measured on macOS 26), so recording follows that message instead of a timer.
// Nothing runs on Macs without a battery. Records are fixed-size little-endian
// integers; serial-number fields are never read.

// kIOPMMessageBatteryStatusHasChanged = iokit_family_msg(sub_iokit_pmu, 0x100);
// the macro does not import into Swift.
private let batteryStatusChanged: natural_t = 0xE002_4100

// IOKit integers pass through their 64-bit pattern, so negative values survive.
private func registryInt(_ value: Any?) -> Int? {
    (value as? NSNumber).map { Int(Int64(bitPattern: $0.uint64Value)) }
}

// MARK: - Records

// 28 bytes on disk and in memory. Unknown temperature is `noTemperature`,
// unknown voltage or capacity 0; the power fields are valid only with `.telemetry`.
struct BatteryHistoryRecord: Equatable {
    struct Flags: OptionSet, Equatable {
        let rawValue: UInt8
        static let external = Flags(rawValue: 1 << 0)
        static let charging = Flags(rawValue: 1 << 1)
        static let fullyCharged = Flags(rawValue: 1 << 2)
        static let telemetry = Flags(rawValue: 1 << 3)
    }
    static let noTemperature = Int16.min
    static let cadence: TimeInterval = 60        // the gauge's refresh interval
    static let gap: TimeInterval = 90            // longer between samples means data is missing
    static let minimumSpacing: UInt32 = 45       // closer readings are kept only on a state change

    var time: UInt32                 // wall clock, seconds since 1970
    var percent: UInt8               // what the macOS battery menu shows
    var flags: Flags = []
    var temperature = noTemperature  // 0.01 °C
    var rawCurrent: UInt16 = 0       // mAh
    var rawMax: UInt16 = 0           // mAh
    var voltage: UInt16 = 0          // mV
    var current: Int16 = 0           // mA, InstantAmperage, negative while discharging
    var systemPowerIn: Int32 = 0     // mW drawn from the adapter
    var systemLoad: Int32 = 0        // mW used by the whole system
    var batteryPower: Int32 = 0      // mW, negative while discharging

    var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }
}

extension BatteryHistoryRecord {
    static let registryKeys = [
        "UpdateTime", "CurrentCapacity", "MaxCapacity", "AppleRawCurrentCapacity", "AppleRawMaxCapacity",
        "Voltage", "InstantAmperage", "Temperature", "ExternalConnected", "IsCharging", "FullyCharged",
        "PowerTelemetryData",
    ]

    // nil without a charge reading. Stamped with the gauge's own UpdateTime when
    // that is plausible wall-clock time, otherwise with `now`.
    init?(registry: [String: Any], now: TimeInterval) {
        guard let charge = registryInt(registry["CurrentCapacity"]), charge >= 0,
              let full = registryInt(registry["MaxCapacity"]), full > 0 else { return nil }
        let updated = registryInt(registry["UpdateTime"]).map(TimeInterval.init)
        time = UInt32(clamping: Int(updated.flatMap { $0 > now - 86400 && $0 < now + 300 ? $0 : nil } ?? now))
        percent = UInt8(min(100, charge * 100 / full))
        func flag(_ key: String) -> Bool { (registry[key] as? NSNumber)?.boolValue ?? false }
        if flag("ExternalConnected") { flags.insert(.external) }
        if flag("IsCharging") { flags.insert(.charging) }
        if flag("FullyCharged") { flags.insert(.fullyCharged) }
        if let t = registryInt(registry["Temperature"]), (-2000...10000).contains(t) { temperature = Int16(t) }
        rawCurrent = UInt16(clamping: max(0, registryInt(registry["AppleRawCurrentCapacity"]) ?? 0))
        rawMax = UInt16(clamping: max(0, registryInt(registry["AppleRawMaxCapacity"]) ?? 0))
        voltage = UInt16(clamping: max(0, registryInt(registry["Voltage"]) ?? 0))
        current = Int16(clamping: registryInt(registry["InstantAmperage"]) ?? 0)
        // SystemPowerIn = SystemLoad + BatteryPower, all mW.
        if let telemetry = registry["PowerTelemetryData"] as? [String: Any],
           let input = registryInt(telemetry["SystemPowerIn"]), let load = registryInt(telemetry["SystemLoad"]) {
            systemPowerIn = Int32(clamping: max(0, input)); systemLoad = Int32(clamping: max(0, load))
            batteryPower = Int32(clamping: registryInt(telemetry["BatteryPower"]) ?? input - load)
            flags.insert(.telemetry)
        }
    }

    // Chart series in display units: %, °C, V, A, W and mAh.
    enum Field: CaseIterable { case percent, temperature, voltage, current, systemPowerIn, systemLoad, batteryPower, rawCurrent }

    func value(_ field: Field) -> Double? {
        let telemetry = flags.contains(.telemetry)
        switch field {
        case .percent: return Double(percent)
        case .temperature: return temperature == Self.noTemperature ? nil : Double(temperature) / 100
        case .voltage: return voltage == 0 ? nil : Double(voltage) / 1000
        case .current: return Double(current) / 1000
        case .systemPowerIn: return telemetry ? Double(systemPowerIn) / 1000 : nil
        case .systemLoad: return telemetry ? Double(systemLoad) / 1000 : nil
        case .batteryPower: return telemetry ? Double(batteryPower) / 1000 : nil
        case .rawCurrent: return rawMax == 0 ? nil : Double(rawCurrent)
        }
    }
}

// One a day, kept for a year. 13 bytes.
struct BatteryHealthSnapshot: Equatable {
    var day: UInt32                   // local date as yyyymmdd
    var nominalCapacity: UInt16 = 0   // mAh, NominalChargeCapacity
    var rawMaxCapacity: UInt16 = 0    // mAh, AppleRawMaxCapacity
    var designCapacity: UInt16 = 0    // mAh
    var cycleCount: UInt16 = 0
    // System Settings' "Maximum Capacity", 0 when unavailable. On macOS 26 the
    // registry and IOPS descriptions lack it, and the IOPS call that has it
    // refuses unentitled callers, so this stays 0 for now.
    var maximumCapacityPercent: UInt8 = 0

    static let registryKeys = ["NominalChargeCapacity", "AppleRawMaxCapacity", "DesignCapacity", "CycleCount"]
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    static func day(for time: TimeInterval) -> UInt32 {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: time))
        return UInt32(clamping: (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0))
    }
    var date: Date? {
        Self.calendar.date(from: DateComponents(year: Int(day / 10000), month: Int(day / 100 % 100), day: Int(day % 100)))
    }
    // Same definition as BatterySnapshot.health.
    var health: Double? {
        nominalCapacity > 0 && designCapacity > 0 ? min(100, Double(nominalCapacity) / Double(designCapacity) * 100) : nil
    }
}

extension BatteryHealthSnapshot {
    // nil without any capacity reading.
    init?(registry: [String: Any], day: UInt32) {
        func value(_ key: String) -> UInt16 { UInt16(clamping: max(0, registryInt(registry[key]) ?? 0)) }
        self.init(day: day, nominalCapacity: value("NominalChargeCapacity"), rawMaxCapacity: value("AppleRawMaxCapacity"),
                  designCapacity: value("DesignCapacity"), cycleCount: value("CycleCount"))
        if nominalCapacity == 0 && rawMaxCapacity == 0 && designCapacity == 0 { return nil }
    }
}

// MARK: - File format
//
// An 8-byte header (4-byte magic, UInt16 format version, UInt16 record size)
// followed by records, all little-endian. A file with any other header is moved
// aside as `<name>.corrupt` and history starts fresh.

protocol PackedRecord: Equatable {
    static var magic: [UInt8] { get }
    static var version: UInt16 { get }
    static var size: Int { get }
    var key: UInt32 { get }          // strictly increasing within a file
    init(packed: UnsafeRawBufferPointer, at offset: Int)
    func pack(into buffer: UnsafeMutableRawBufferPointer, at offset: Int)
}

private extension UnsafeRawBufferPointer {
    func le<T: FixedWidthInteger>(_ offset: Int) -> T { T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self)) }
}
private extension UnsafeMutableRawBufferPointer {
    func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) { storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self) }
}

extension BatteryHistoryRecord: PackedRecord {
    static let magic = Array("OSBH".utf8), version: UInt16 = 1, size = 28
    var key: UInt32 { time }
    init(packed b: UnsafeRawBufferPointer, at o: Int) {
        time = b.le(o); percent = b.le(o + 4); flags = Flags(rawValue: b.le(o + 5)); temperature = b.le(o + 6)
        rawCurrent = b.le(o + 8); rawMax = b.le(o + 10); voltage = b.le(o + 12); current = b.le(o + 14)
        systemPowerIn = b.le(o + 16); systemLoad = b.le(o + 20); batteryPower = b.le(o + 24)
    }
    func pack(into b: UnsafeMutableRawBufferPointer, at o: Int) {
        b.put(time, o); b.put(percent, o + 4); b.put(flags.rawValue, o + 5); b.put(temperature, o + 6)
        b.put(rawCurrent, o + 8); b.put(rawMax, o + 10); b.put(voltage, o + 12); b.put(current, o + 14)
        b.put(systemPowerIn, o + 16); b.put(systemLoad, o + 20); b.put(batteryPower, o + 24)
    }
}

extension BatteryHealthSnapshot: PackedRecord {
    static let magic = Array("OSBD".utf8), version: UInt16 = 1, size = 13
    var key: UInt32 { day }
    init(packed b: UnsafeRawBufferPointer, at o: Int) {
        self.init(day: b.le(o), nominalCapacity: b.le(o + 4), rawMaxCapacity: b.le(o + 6),
                  designCapacity: b.le(o + 8), cycleCount: b.le(o + 10), maximumCapacityPercent: b.le(o + 12))
    }
    func pack(into b: UnsafeMutableRawBufferPointer, at o: Int) {
        b.put(day, o); b.put(nominalCapacity, o + 4); b.put(rawMaxCapacity, o + 6)
        b.put(designCapacity, o + 8); b.put(cycleCount, o + 10); b.put(maximumCapacityPercent, o + 12)
    }
}

enum PackedFile {
    static let headerSize = 8
    static let sizeLimit = 16 << 20   // ~13 full histories; anything larger is not ours

    // Records in file order. `damaged` asks for a rewrite: the file was moved
    // aside, or ends in a partial record from an interrupted append.
    static func load<R: PackedRecord>(_ url: URL, as _: R.Type = R.self) -> (records: [R], damaged: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], false) }
        let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        let records: [R]? = data?.withUnsafeBytes { b in
            guard b.count >= headerSize, b.count <= sizeLimit, Array(b.prefix(4)) == R.magic,
                  b.le(4) as UInt16 == R.version, Int(b.le(6) as UInt16) == R.size else { return nil }
            return (0..<(b.count - headerSize) / R.size).map { R(packed: b, at: headerSize + $0 * R.size) }
        }
        guard let records, let data else { quarantine(url); return ([], true) }
        return (records, (data.count - headerSize) % R.size != 0)
    }

    static func encode<R: PackedRecord>(_ records: some Collection<R>, header: Bool) -> Data {
        var data = Data(count: (header ? headerSize : 0) + records.count * R.size)
        data.withUnsafeMutableBytes { b in
            var offset = 0
            if header {
                for (i, byte) in R.magic.enumerated() { b[i] = byte }
                b.put(R.version, 4); b.put(UInt16(R.size), 6); offset = headerSize
            }
            for record in records { record.pack(into: b, at: offset); offset += R.size }
        }
        return data
    }

    // Atomic: readers see either the old file or the new one.
    static func write<R: PackedRecord>(_ records: [R], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(records, header: true).write(to: url, options: .atomic)
    }

    static func append<R: PackedRecord>(_ records: ArraySlice<R>, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encode(records, header: false))
    }

    static func quarantine(_ url: URL) {
        let aside = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: aside)
        if (try? FileManager.default.moveItem(at: url, to: aside)) == nil { try? FileManager.default.removeItem(at: url) }
    }
}

extension Array where Element: PackedRecord {
    // Sorted by key within [low, high], one record per key.
    func normalized(from low: UInt32, through high: UInt32) -> [Element] {
        var kept = filter { $0.key >= low && $0.key <= high }
        guard zip(kept, kept.dropFirst()).contains(where: { $0.key >= $1.key }) else { return kept }
        kept.sort { $0.key < $1.key }
        var unique: [Element] = []; unique.reserveCapacity(kept.count)
        for record in kept where unique.last.map({ $0.key < record.key }) ?? true { unique.append(record) }
        return unique
    }
}

extension Array where Element == BatteryHistoryRecord {
    // Index of the first record at or after `time`; records are sorted.
    func firstIndex(atOrAfter time: TimeInterval) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if TimeInterval(self[mid].time) < time { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

// MARK: - Storage

// Queue-owned. `records` stays sorted; the newest `pending` are not on disk yet.
final class BatteryHistoryStore {
    static let retention: TimeInterval = 30 * 86400
    static let healthRetention: TimeInterval = 365 * 86400
    static let capacity = 30 * 1440 * 3 / 2   // hard bound if a gauge refreshes faster
    let historyURL: URL, healthURL: URL
    private(set) var records: [BatteryHistoryRecord] = []
    private(set) var snapshots: [BatteryHealthSnapshot] = []
    private(set) var lastFlush: TimeInterval = 0, lastCompaction: TimeInterval = 0
    private var pending = 0, needsRewrite = false, healthDirty = false

    init(directory: URL) {
        historyURL = directory.appendingPathComponent("battery-history.bin")
        healthURL = directory.appendingPathComponent("battery-health.bin")
    }

    func load(now: TimeInterval) {
        let history = PackedFile.load(historyURL, as: BatteryHistoryRecord.self)
        let health = PackedFile.load(healthURL, as: BatteryHealthSnapshot.self)
        records = history.records; snapshots = health.records
        pending = 0; needsRewrite = history.damaged; healthDirty = health.damaged
        compact(now: now)
    }

    // Drops what is past retention (or in the future after a clock change),
    // rewriting atomically only when something changed.
    func compact(now: TimeInterval) {
        var kept = records.normalized(from: UInt32(clamping: Int(now - Self.retention)), through: UInt32(clamping: Int(now + 3600)))
        if kept.count > Self.capacity { kept.removeFirst(kept.count - Self.capacity) }
        if kept != records { needsRewrite = true; records = kept }
        records.reserveCapacity(30 * 1440 + 1440)   // pages are only touched as records arrive
        let days = snapshots.normalized(from: BatteryHealthSnapshot.day(for: now - Self.healthRetention),
                                        through: BatteryHealthSnapshot.day(for: now + 86400))
        if days != snapshots { snapshots = days; healthDirty = true }
        lastCompaction = now
        flush(now: now)
    }

    // false for a duplicate: not newer than the last record, or closer than
    // `minimumSpacing` without a state change.
    @discardableResult
    func append(_ record: BatteryHistoryRecord) -> Bool {
        if let last = records.last {
            if record.time <= last.time {
                // The clock moved back by over an hour: forget the "future" instead
                // of refusing every reading until it is reached again.
                guard Int(last.time) - Int(record.time) > 3600 else { return false }
                records.removeSubrange(records.firstIndex(atOrAfter: TimeInterval(record.time))...)
                needsRewrite = true; pending = 0
            } else if record.time - last.time < BatteryHistoryRecord.minimumSpacing && record.flags == last.flags {
                return false
            }
        }
        records.append(record); pending += 1
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
        return true
    }

    func hasSnapshot(for day: UInt32) -> Bool { snapshots.last?.day == day || snapshots.contains { $0.day == day } }

    @discardableResult
    func add(_ snapshot: BatteryHealthSnapshot) -> Bool {
        guard !hasSnapshot(for: snapshot.day) else { return false }
        snapshots.append(snapshot)
        if snapshots.count > 1 && snapshots[snapshots.count - 2].day > snapshot.day { snapshots.sort { $0.day < $1.day } }
        writeHealth()
        return true
    }

    // Appends pending records; a failed or impossible append becomes a full
    // atomic rewrite on the next flush.
    func flush(now: TimeInterval) {
        lastFlush = now
        if healthDirty { writeHealth() }
        guard pending > 0 || needsRewrite else { return }
        do {
            if needsRewrite || !FileManager.default.fileExists(atPath: historyURL.path) {
                try PackedFile.write(records, to: historyURL)
            } else {
                try PackedFile.append(records.suffix(pending), to: historyURL)
            }
            needsRewrite = false
        } catch { needsRewrite = true }
        pending = 0
    }

    private func writeHealth() { healthDirty = (try? PackedFile.write(snapshots, to: healthURL)) == nil }
}

// MARK: - Queries (pure)

// One downsampled chart point: the extremes and mean of the samples in one slot.
struct BatteryHistoryBucket: Equatable {
    var start: Date, end: Date      // first and last sample in the slot
    var low: Double, high: Double, mean: Double
    var count: Int
}

extension BatteryHistoryBucket {
    // Contiguous runs, at most `maxPoints` buckets in total over [from, to]:
    // equal slots, never narrower than a minute, each keeping its samples' min,
    // max and mean so peaks survive. Samples further apart than `gap` (or than a
    // slot, once slots are wider) end a run, so missing minutes, sleep and time
    // the app was not running stay gaps; nothing is interpolated. Samples without
    // the field count as missing.
    static func series(_ records: [BatteryHistoryRecord], _ field: BatteryHistoryRecord.Field,
                       from: TimeInterval, to: TimeInterval, maxPoints: Int,
                       gap: TimeInterval = BatteryHistoryRecord.gap) -> [[BatteryHistoryBucket]] {
        guard maxPoints > 0, to > from else { return [] }
        let width = max(BatteryHistoryRecord.cadence, ((to - from) / Double(maxPoints)).rounded(.up))
        let limit = max(gap, width)
        var runs: [[BatteryHistoryBucket]] = [], run: [BatteryHistoryBucket] = []
        var slot = -1, previous = -Double.infinity, first = 0.0
        var low = 0.0, high = 0.0, sum = 0.0, count = 0
        func close() {
            guard count > 0 else { return }
            run.append(BatteryHistoryBucket(start: Date(timeIntervalSince1970: first), end: Date(timeIntervalSince1970: previous),
                                            low: low, high: high, mean: sum / Double(count), count: count))
            count = 0
        }
        for record in records[records.firstIndex(atOrAfter: from)...] {
            let t = TimeInterval(record.time)
            if t > to { break }
            guard let v = record.value(field) else { continue }
            let s = min(maxPoints - 1, Int((t - from) / width))
            if t - previous > limit {
                close()
                if !run.isEmpty { runs.append(run); run = [] }
            } else if s != slot { close() }
            if count == 0 { first = t; low = v; high = v; sum = 0 }
            low = min(low, v); high = max(high, v); sum += v; count += 1
            slot = s; previous = t
        }
        close()
        if !run.isEmpty { runs.append(run) }
        return runs
    }
}

// Where the power went, for the strip under the charge chart.
enum BatteryPowerState: Equatable {
    case charging, pluggedIdle, onBattery
    init(_ flags: BatteryHistoryRecord.Flags) {
        self = !flags.contains(.external) ? .onBattery : flags.contains(.charging) ? .charging : .pluggedIdle
    }
}

struct BatteryStateSegment: Equatable {
    var state: BatteryPowerState
    var start: Date, end: Date
}

extension BatteryStateSegment {
    // Consecutive samples in one state merge into a segment that runs until the
    // next sample; a gap longer than `gap` ends it there, so gaps stay empty.
    static func segments(_ records: [BatteryHistoryRecord], from: TimeInterval, to: TimeInterval,
                         gap: TimeInterval = BatteryHistoryRecord.gap) -> [BatteryStateSegment] {
        guard to > from else { return [] }
        var result: [BatteryStateSegment] = []
        let first = Swift.max(0, records.firstIndex(atOrAfter: from) - 1)
        guard first < records.count else { return [] }
        for i in first..<records.count {
            let record = records[i], t = TimeInterval(record.time)
            if t > to { break }
            let next = i + 1 < records.count ? TimeInterval(records[i + 1].time) : t
            // The last sample, or one before a gap, covers only its own minute.
            let end = Swift.min(to, next - t <= gap && next > t ? next : t + BatteryHistoryRecord.cadence)
            let start = Swift.max(from, t)
            guard end > start else { continue }
            let state = BatteryPowerState(record.flags)
            if var last = result.last, last.state == state, abs(last.end.timeIntervalSince1970 - start) < 1 {
                last.end = Date(timeIntervalSince1970: end); result[result.count - 1] = last
            } else {
                result.append(BatteryStateSegment(state: state, start: Date(timeIntervalSince1970: start),
                                                  end: Date(timeIntervalSince1970: end)))
            }
        }
        return result
    }
}

// Time and energy over [from, to] from consecutive samples no further apart than
// `gap`. Each interval takes its first sample's state; power is the mean of its
// two ends. Gaps count for nothing. Durations are seconds.
struct BatteryDayStats: Equatable {
    static let idleCurrent = 50                 // mA; below this the battery is idle

    var wallEnergy = 0.0                        // Wh drawn from the adapter
    var heldAtLimit: TimeInterval = 0           // on AC, battery idle within `tolerance` of the limit
    var full: TimeInterval = 0                  // at ≥ 99 % or fully charged
    var onBattery: TimeInterval = 0
    var covered: TimeInterval = 0               // time with samples at both ends

    init() {}
    init(_ records: [BatteryHistoryRecord], from: TimeInterval, to: TimeInterval, limit: Int, tolerance: Int = 2,
         gap: TimeInterval = BatteryHistoryRecord.gap) {
        var i = max(0, records.firstIndex(atOrAfter: from) - 1)
        while i + 1 < records.count {
            let a = records[i], b = records[i + 1]
            i += 1
            let start = TimeInterval(a.time), end = TimeInterval(b.time)
            if start >= to { break }
            let overlap = min(end, to) - max(start, from)
            guard end - start <= gap, overlap > 0 else { continue }
            covered += overlap
            if a.flags.contains(.telemetry) && b.flags.contains(.telemetry) {
                wallEnergy += Double(Int(a.systemPowerIn) + Int(b.systemPowerIn)) / 2 * overlap / 3_600_000
            }
            if !a.flags.contains(.external) { onBattery += overlap }
            else if !a.flags.contains(.charging) && abs(Int(a.current)) <= Self.idleCurrent
                        && abs(Int(a.percent) - limit) <= tolerance { heldAtLimit += overlap }
            if a.percent >= 99 || a.flags.contains(.fullyCharged) { full += overlap }
        }
    }
}

enum BatteryEstimate {
    static let minimumCurrent = 50.0            // mA
    static let freshness: TimeInterval = 180

    // Mean current (mA) of the newest samples that share the latest one's power
    // state, within `window` and without gaps. nil when the latest sample is
    // stale or there are fewer than `minimumSamples`.
    static func recentCurrent(_ records: [BatteryHistoryRecord], now: TimeInterval, window: TimeInterval = 600,
                              minimumSamples: Int = 3, gap: TimeInterval = BatteryHistoryRecord.gap) -> Double? {
        guard let latest = records.last, now - TimeInterval(latest.time) <= freshness else { return nil }
        let state = latest.flags.intersection([.external, .charging])
        var sum = 0.0, count = 0, previous = TimeInterval(latest.time)
        for record in records.reversed() {
            let t = TimeInterval(record.time)
            guard TimeInterval(latest.time) - t <= window, previous - t <= gap,
                  record.flags.intersection([.external, .charging]) == state else { break }
            sum += Double(record.current); count += 1; previous = t
        }
        return count >= minimumSamples ? sum / Double(count) : nil
    }

    // Seconds until the charge reaches `target` % of the raw full-charge capacity
    // at `current` mA. AvgTimeToFull covers only 100 %, but a charge limit stops
    // earlier. Assumes the shown percent tracks raw ÷ raw max. nil unless charging
    // toward a target above the present charge.
    static func timeToTarget(_ target: Int, rawCurrent: Int, rawMax: Int, current: Double) -> TimeInterval? {
        guard (1...100).contains(target), rawMax > 0, rawCurrent >= 0, current >= minimumCurrent else { return nil }
        let needed = Double(target * rawMax) / 100 - Double(rawCurrent)
        return needed > 0 ? needed / current * 3600 : nil
    }

    // Seconds until the raw remaining charge runs out at `current` mA, which is
    // negative while discharging. nil unless discharging.
    static func timeToEmpty(rawCurrent: Int, current: Double) -> TimeInterval? {
        guard rawCurrent > 0, current <= -minimumCurrent else { return nil }
        return Double(rawCurrent) / -current * 3600
    }
}

// MARK: - Recorder

// Lives for the app's lifetime. Records on the battery-status message; all
// state is owned by `queue`. Queries block briefly on it, so call them from the
// main thread, never from a history callback.
final class BatteryHistory: ObservableObject {
    static let watchdogInterval: TimeInterval = 300
    static let staleAfter: TimeInterval = 180
    static let flushInterval: TimeInterval = 600
    static let compactionInterval: TimeInterval = 86400
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmniStats", isDirectory: true)
    }

    // The newest record, set on the main queue after each new sample and once
    // after loading. It can be old; check its `date`.
    @Published private(set) var latest: BatteryHistoryRecord?
    let isPresent: Bool
    private let queue = DispatchQueue(label: "com.omnistats.battery-history", qos: .utility)
    private let store: BatteryHistoryStore
    private let reader: BatteryReader?      // nil when readings are injected
    private let read: ([String]) -> [String: Any]?
    private let clock: () -> TimeInterval
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var observedEntry: UInt64 = 0
    private var watchdog: DispatchSourceTimer?
    private var lastUpdateTime: Int?
    private var started = false

    init(isPresent: Bool? = nil, directory: URL = BatteryHistory.defaultDirectory,
         read: (([String]) -> [String: Any]?)? = nil, clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        if let read {
            reader = nil; self.read = read
        } else {
            let reader = BatteryReader()
            self.reader = reader; self.read = { reader.read($0) }
        }
        self.isPresent = isPresent ?? BatteryReader.isPresent
        store = BatteryHistoryStore(directory: directory)
        self.clock = clock
    }
    deinit {
        watchdog?.cancel()
        if notification != 0 { IOObjectRelease(notification) }
        if let port { IONotificationPortDestroy(port) }
    }

    // Loads and compacts the stored history, then records every gauge refresh.
    func start() {
        guard isPresent, !started else { return }
        started = true
        queue.async { [self] in
            store.load(now: clock())
            publish(store.records.last)
            observe()
            // Safety net, not a sampler: if the battery message stops arriving
            // (perhaps during display sleep, which is untested), this still records
            // about every five minutes. It reads only when the newest record is
            // over three minutes old, and the minute of leeway lets the system
            // coalesce the wakeup.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval, leeway: .seconds(60))
            timer.setEventHandler { [weak self] in self?.watchdogTick() }
            timer.resume(); watchdog = timer
            sample()
        }
    }

    // Writes pending records; call on termination.
    func flush() { queue.sync { store.flush(now: clock()) } }

    // A reading now, as a battery message would trigger. Synchronous.
    func recordNow() {
        guard isPresent else { return }
        queue.sync { sample() }
    }

    // The watchdog's tick, normally run by its timer.
    func runWatchdog() {
        guard isPresent else { return }
        queue.sync { watchdogTick() }
    }

    // MARK: Queries for the charts

    func series(_ field: BatteryHistoryRecord.Field, from: Date, to: Date, maxPoints: Int) -> [[BatteryHistoryBucket]] {
        queue.sync {
            BatteryHistoryBucket.series(store.records, field, from: from.timeIntervalSince1970,
                                        to: to.timeIntervalSince1970, maxPoints: maxPoints)
        }
    }

    func states(from: Date, to: Date) -> [BatteryStateSegment] {
        queue.sync {
            BatteryStateSegment.segments(store.records, from: from.timeIntervalSince1970, to: to.timeIntervalSince1970)
        }
    }

    var snapshots: [BatteryHealthSnapshot] { queue.sync { store.snapshots } }

    // Since local midnight.
    func todayStats(limit: Int, tolerance: Int = 2) -> BatteryDayStats {
        queue.sync {
            let now = clock()
            let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
            return BatteryDayStats(store.records, from: midnight, to: now, limit: limit, tolerance: tolerance)
        }
    }

    // Seconds until the shown charge reaches `percent` at the recent charge current.
    func timeToReach(_ percent: Int) -> TimeInterval? {
        queue.sync {
            guard let latest = store.records.last,
                  let current = BatteryEstimate.recentCurrent(store.records, now: clock()) else { return nil }
            return BatteryEstimate.timeToTarget(percent, rawCurrent: Int(latest.rawCurrent), rawMax: Int(latest.rawMax), current: current)
        }
    }

    // Seconds until empty at the recent discharge current.
    func timeToEmpty() -> TimeInterval? {
        queue.sync {
            guard let latest = store.records.last,
                  let current = BatteryEstimate.recentCurrent(store.records, now: clock()) else { return nil }
            return BatteryEstimate.timeToEmpty(rawCurrent: Int(latest.rawCurrent), current: current)
        }
    }

    // MARK: Recording (on `queue`)

    private func sample() {
        let now = clock()
        // A repeated message, or a tick between refreshes, costs a single key.
        if let previous = lastUpdateTime, registryInt(read(["UpdateTime"])?["UpdateTime"]) == previous {
            return maintain(now)
        }
        guard let registry = read(BatteryHistoryRecord.registryKeys),
              let record = BatteryHistoryRecord(registry: registry, now: now) else { return maintain(now) }
        lastUpdateTime = registryInt(registry["UpdateTime"])
        if store.append(record) { publish(record) }
        let day = BatteryHealthSnapshot.day(for: now)
        if !store.hasSnapshot(for: day), let health = read(BatteryHealthSnapshot.registryKeys),
           let snapshot = BatteryHealthSnapshot(registry: health, day: day) {
            store.add(snapshot)
        }
        maintain(now)
    }

    private func watchdogTick() {
        observe()   // re-arm if the battery entry was replaced
        let now = clock()
        if now - TimeInterval(store.records.last?.time ?? 0) >= Self.staleAfter { sample() } else { maintain(now) }
    }

    // Batched appends and daily compaction; `abs` so clock changes cannot stall them.
    private func maintain(_ now: TimeInterval) {
        if abs(now - store.lastCompaction) >= Self.compactionInterval { store.compact(now: now) }
        else if abs(now - store.lastFlush) >= Self.flushInterval { store.flush(now: now) }
    }

    private func publish(_ record: BatteryHistoryRecord?) {
        guard let record else { return }
        DispatchQueue.main.async { [weak self] in self?.latest = record }
    }

    // The gauge posts kIOPMMessageBatteryStatusHasChanged on its service after
    // every refresh; the port delivers it on `queue`.
    private func observe() {
        guard let reader else { return }
        let service = reader.entry
        var id: UInt64 = 0
        guard service != 0, IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS, id != observedEntry else { return }
        if notification != 0 { IOObjectRelease(notification); notification = 0 }
        if port == nil {
            port = IONotificationPortCreate(kIOMainPortDefault)
            IONotificationPortSetDispatchQueue(port, queue)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, message, _ in
            guard let context, message == batteryStatusChanged else { return }
            Unmanaged<BatteryHistory>.fromOpaque(context).takeUnretainedValue().sample()
        }, context, &notification)
        observedEntry = result == KERN_SUCCESS ? id : 0
    }
}
