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
// The counters are differentiated once a second into bytes/sec. "Most active" =
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

    // 1h rolling history for the expanded network panel (native 1s tick).
    let rxHistory = MetricSeries(retention: 3600)
    let txHistory = MetricSeries(retention: 3600)

    private struct Counter { var rx: UInt64; var tx: UInt64 }
    private var prev: [String: Counter] = [:]
    private var prevTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var chosen = ""
    private var timer: Timer?

    init() {
        prev = readCounters()            // prime so the first tick has a baseline
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keep ticking while the panel is open
        timer = t
    }

    deinit { timer?.invalidate() }

    /// Number of interface rows in the IFMIB tree. Indices are 1…ifCount.
    private func ifCount() -> Int32 {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        var n: Int32 = 0
        var len = MemoryLayout<Int32>.size
        guard sysctl(&mib, 5, &n, &len, nil, 0) == 0 else { return 0 }
        return n
    }

    private func readCounters() -> [String: Counter] {
        var out: [String: Counter] = [:]
        let n = ifCount()
        guard n > 0 else { return out }
        for idx in 1...n {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, idx, IFDATA_GENERAL]
            var d = ifmibdata()
            var len = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, 6, &d, &len, nil, 0) == 0 else { continue }
            let name = withUnsafePointer(to: d.ifmd_name) { p in
                p.withMemoryRebound(to: CChar.self, capacity: Int(IFNAMSIZ)) { String(cString: $0) }
            }
            guard !name.isEmpty else { continue }
            out[name] = Counter(rx: d.ifmd_data.ifi_ibytes, tx: d.ifmd_data.ifi_obytes)
        }
        return out
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(0.2, now - prevTime)
        let curr = readCounters()

        // Deltas are computed on 64-bit counters, so a negative result can only
        // mean the interface was torn down and re-created (counters reset) —
        // treat that as "no data" rather than a bogus spike.
        func delta(_ name: String) -> (rx: Double, tx: Double)? {
            guard let p = prev[name], let c = curr[name], c.rx >= p.rx, c.tx >= p.tx else { return nil }
            return (Double(c.rx - p.rx), Double(c.tx - p.tx))
        }

        var best = "", bestActivity = -1.0, bestRx = 0.0, bestTx = 0.0
        for name in curr.keys where name.hasPrefix("en") {
            guard let d = delta(name) else { continue }
            if d.rx + d.tx > bestActivity {
                bestActivity = d.rx + d.tx; best = name
                bestRx = d.rx / dt; bestTx = d.tx / dt
            }
        }
        // Idle tick: keep the previously chosen interface and report its (near-zero) rate.
        if bestActivity <= 0, !chosen.isEmpty, let d = delta(chosen) {
            best = chosen
            bestRx = d.rx / dt
            bestTx = d.tx / dt
        }
        if !best.isEmpty { chosen = best }

        prev = curr
        prevTime = now
        rxBps = max(0, bestRx)
        txBps = max(0, bestTx)
        iface = chosen
        rxHistory.record(rxBps, at: now)
        txHistory.record(txBps, at: now)
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
