import Foundation

// Live network throughput for the most active physical interface.
//
// Reads per-interface byte counters via getifaddrs(AF_LINK) once a second and
// differentiates them into bytes/sec. "Most active" = the en* interface (Wi-Fi
// or Ethernet) with the largest rx+tx delta this tick; when everything is idle
// it sticks with the last chosen interface so the readout doesn't flap.
final class NetSampler: ObservableObject {
    @Published var rxBps: Double = 0     // download, bytes/sec (EMA-smoothed)
    @Published var txBps: Double = 0     // upload,   bytes/sec (EMA-smoothed)
    @Published var iface: String = ""

    // 1h rolling history for the expanded network panel (native 1s tick).
    let rxHistory = MetricSeries(retention: 3600)
    let txHistory = MetricSeries(retention: 3600)

    private struct Counter { var rx: UInt32; var tx: UInt32 }
    private var prev: [String: Counter] = [:]
    private var prevTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var chosen = ""
    private var timer: Timer?
    private let alpha = 0.45             // display smoothing

    init() {
        prev = readCounters()            // prime so the first tick has a baseline
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keep ticking while a menu is open
        timer = t
    }

    private func readCounters() -> [String: Counter] {
        var out: [String: Counter] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return out }
        defer { freeifaddrs(ifap) }
        var ptr = ifap
        while let cur = ptr {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK), let raw = ifa.ifa_data {
                let name = String(cString: ifa.ifa_name)
                let d = raw.assumingMemoryBound(to: if_data.self).pointee
                out[name] = Counter(rx: d.ifi_ibytes, tx: d.ifi_obytes)
            }
            ptr = ifa.ifa_next
        }
        return out
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(0.2, now - prevTime)
        let curr = readCounters()

        var best = "", bestActivity = -1.0, bestRx = 0.0, bestTx = 0.0
        for (name, c) in curr where name.hasPrefix("en") {
            guard let p = prev[name] else { continue }
            let drx = Double(c.rx &- p.rx), dtx = Double(c.tx &- p.tx)   // wrapping sub handles 32-bit rollover
            if drx + dtx > bestActivity { bestActivity = drx + dtx; best = name; bestRx = drx / dt; bestTx = dtx / dt }
        }
        // Idle tick: keep the previously chosen interface and report its (near-zero) rate.
        if bestActivity <= 0, !chosen.isEmpty, let p = prev[chosen], let c = curr[chosen] {
            best = chosen
            bestRx = Double(c.rx &- p.rx) / dt
            bestTx = Double(c.tx &- p.tx) / dt
        }
        if !best.isEmpty { chosen = best }

        prev = curr
        prevTime = now
        rxBps += alpha * (max(0, bestRx) - rxBps)
        txBps += alpha * (max(0, bestTx) - txBps)
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
