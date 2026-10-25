import Foundation

// Live network throughput for the most active physical interface.
//
// Counters come from the IFMIB sysctl tree
// (net.link.generic.ifdata.<index>.general → `struct ifmibdata`), which carries
// true 64-bit `if_data64` byte counts — the same source `netstat -ib` reads.
// getifaddrs' AF_LINK payload is a 32-bit `if_data`, which wraps every 4 GiB
// (measured: en0 on a normal machine had already wrapped 91 times), so it is
// unusable for a long-lived monitor.
//
// Counters are differentiated at the policy-selected interval into bytes/sec. "Most active" =
// the en* interface (Wi-Fi or Ethernet) with the largest rx+tx delta this tick;
// when everything is idle it sticks with the last chosen interface so the
// readout doesn't flap.
//
// Rates are published raw, not EMA-smoothed: an exponential average with a 1 s
// tick reaches only 45% of a step in the first second, so bursts used to read
// roughly half their true size and the recorded history — and therefore the
// chart's y-scale — inherited the same deflation.
final class NetSampler: ObservableObject {
    @Published var rxBps: Double = 0     // download, bytes/sec
    @Published var txBps: Double = 0     // upload,   bytes/sec
    @Published var iface: String = ""

    // 1h rolling history for the expanded network panel at the selected cadence.
    let rxHistory = MetricSeries(retention: 3600)
    let txHistory = MetricSeries(retention: 3600)

    struct Counter { var rx: UInt64; var tx: UInt64 }
    private var prev: [String: Counter] = [:]
    private var prevTime: TimeInterval = 0
    private var chosen = ""
    private var timer: Timer?
    private(set) var samplingInterval: TimeInterval?

    init() { setSamplingInterval(3) }
    deinit { timer?.invalidate() }

    func setSamplingInterval(_ interval: TimeInterval?) {
        guard interval != samplingInterval else { return }
        timer?.invalidate(); timer = nil
        let wasPaused = samplingInterval == nil
        samplingInterval = interval
        guard let interval else {
            prev.removeAll(); prevTime = 0
            rxBps = 0; txBps = 0; iface = ""
            return
        }
        if wasPaused { prime() }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func prime() {
        prev = readCounters(); prevTime = sampleTime()
    }

    private func readCounters() -> [String: Counter] {
        var out: [String: Counter] = [:]
        // IFCOUNT is a count, not the highest index: interface indices can have
        // holes. Enumerate names and query only physical en* interfaces.
        guard let interfaces = if_nameindex() else { return out }
        defer { if_freenameindex(interfaces) }
        var row = interfaces
        while row.pointee.if_index != 0, let rawName = row.pointee.if_name {
            let name = String(cString: rawName)
            if name.hasPrefix("en") {
                var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA,
                                   Int32(row.pointee.if_index), IFDATA_GENERAL]
                var data = ifmibdata()
                var length = MemoryLayout<ifmibdata>.size
                if sysctl(&mib, 6, &data, &length, nil, 0) == 0 {
                    out[name] = Counter(rx: data.ifmd_data.ifi_ibytes, tx: data.ifmd_data.ifi_obytes)
                }
            }
            row = row.advanced(by: 1)
        }
        return out
    }

    private func tick() { accept(readCounters(), at: sampleTime()) }

    // Independent of sysctl so counter reset/removal behavior is testable.
    func accept(_ current: [String: Counter], at now: TimeInterval) {
        defer { prev = current; prevTime = now }
        let dt = now - prevTime
        guard prevTime > 0, dt > 0, dt < 60 else { rxBps = 0; txBps = 0; return }
        var best = "", activity = -1.0, rx = 0.0, tx = 0.0
        for name in current.keys.sorted() {
            guard let old = prev[name], let new = current[name],
                  new.rx >= old.rx, new.tx >= old.tx else { continue }
            let drx = Double(new.rx - old.rx), dtx = Double(new.tx - old.tx)
            if drx + dtx > activity || (drx + dtx == activity && name == chosen) {
                best = name; activity = drx + dtx
                rx = drx / dt; tx = dtx / dt
            }
        }
        chosen = best
        rxHistory.record(rx, at: now, cadence: samplingInterval ?? 2)
        txHistory.record(tx, at: now, cadence: samplingInterval ?? 2)
        rxBps = rx; txBps = tx
        if iface != chosen { iface = chosen }
    }

}

// Human-readable byte-rate: "512 B/s", "12 KB/s", "3.4 MB/s", "1.05 GB/s".
func humanRate(_ bytesPerSec: Double) -> String {
    let b = max(0, bytesPerSec)
    if b < 1024 { return String(format: "%.0f B/s", b) }
    let kb = b / 1024
    if kb < 1024 { return String(format: kb < 10 ? "%.1f KB/s" : "%.0f KB/s", kb) }
    let mb = kb / 1024
    if mb < 1024 { return String(format: mb < 10 ? "%.2f MB/s" : "%.1f MB/s", mb) }
    return String(format: "%.2f GB/s", mb / 1024)
}

// Compact byte-rate for chart axis labels: "1K", "64K", "10M", "1G" (per second
// is implied by the chart). Keeps decade gridline labels to 2–3 characters.
func axisRate(_ bytesPerSec: Double) -> String {
    let b = max(0, bytesPerSec)
    if b < 1000 { return String(format: "%.0f", b) }
    let kb = b / 1024
    if kb < 1000 { return String(format: kb < 10 ? "%.1fK" : "%.0fK", kb) }
    let mb = kb / 1024
    if mb < 1000 { return String(format: mb < 10 ? "%.1fM" : "%.0fM", mb) }
    return String(format: "%.1fG", mb / 1024)
}

// Fixed-width byte-rate for the menu bar. Always 9 characters: a 4-cell number
// field followed by a 4-cell unit ("   0  B/s", " 999 KB/s", "12.3 KB/s",
// "1.23 MB/s"). The value carries 3 significant figures — decimals shrink as it
// grows (2 below 10, 1 below 100, 0 below 1000) and the unit promotes before the
// integer would hit 4 digits — so the number never exceeds 3 digits + 1 point.
// The number field is right-padded to a constant 4 cells; render in a monospaced
// font so every cell (digits, point, padding) is one column and the menu bar
// stops shifting.
func menuBarRate(_ bytesPerSec: Double) -> String {
    let units = [" B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
    var v = max(0, bytesPerSec)
    var u = 0
    // Promote before the number would round up to 4 digits, so it stays ≤ 3 digits.
    while v >= 999.5 && u < units.count - 1 { v /= 1024; u += 1 }
    let num: String
    if u == 0          { num = String(format: "%.0f", v) }   // whole bytes, 0…999
    else if v < 9.995  { num = String(format: "%.2f", v) }   // "1.23"
    else if v < 99.95  { num = String(format: "%.1f", v) }   // "12.3"
    else               { num = String(format: "%.0f", v) }   // "123"
    let padded = String(repeating: " ", count: max(0, 4 - num.count)) + num
    return padded + " " + units[u]
}
