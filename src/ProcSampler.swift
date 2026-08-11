import Foundation

struct ProcUsage: Identifiable {
    let id = UUID()
    let name: String
    let cpu: Double     // percent; 100% == one full core (like Activity Monitor / top)
}

// Top processes by CPU, merged per program.
//
// Samples cumulative CPU time (user+system) per PID via proc_pid_rusage every
// couple seconds and differentiates it against the previous sample. Processes
// belonging to the same app (all `Foo.app/…` helpers) are merged under "Foo",
// so e.g. Chrome's many helpers roll up into one line. Ranking is robust to the
// exact time unit since it's monotonic; percentages assume ri_*_time in ns.
final class ProcSampler: ObservableObject {
    @Published var top: [ProcUsage] = []
    var enabled = true                  // display gate; skips sampling work when off

    private var prevCPU: [pid_t: UInt64] = [:]
    private var prevTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var timer: Timer?
    private let ncpu = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    init() {
        prime()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: sampling
    private func listPids() -> [pid_t] {
        let need = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard need > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(need) / MemoryLayout<pid_t>.stride)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, need)
        guard got > 0 else { return [] }
        let count = Int(got) / MemoryLayout<pid_t>.stride
        return pids.prefix(count).filter { $0 > 0 }
    }

    private func cpuTimeNs(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard rc == 0 else { return nil }
        return info.ri_user_time &+ info.ri_system_time
    }

    private func displayName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)   // 4 * MAXPATHLEN; macro not importable to Swift
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            // Merge all "Foo.app/…" helpers into the top-level bundle name "Foo".
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

    private func prime() {
        var m: [pid_t: UInt64] = [:]
        for pid in listPids() { if let t = cpuTimeNs(pid) { m[pid] = t } }
        prevCPU = m
        prevTime = CFAbsoluteTimeGetCurrent()
    }

    private func tick() {
        guard enabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(0.5, now - prevTime)
        var newPrev: [pid_t: UInt64] = [:]
        var byName: [String: Double] = [:]
        for pid in listPids() {
            guard let t = cpuTimeNs(pid) else { continue }
            newPrev[pid] = t
            guard let p = prevCPU[pid], t >= p else { continue }   // skip new/rolled pids
            let pct = Double(t - p) / (dt * 1_000_000_000) * 100
            if pct <= 0.05 { continue }                            // ignore noise; also limits name lookups
            byName[displayName(pid), default: 0] += pct
        }
        prevCPU = newPrev
        prevTime = now
        let result = byName.sorted { $0.value > $1.value }.prefix(5)
            .map { ProcUsage(name: $0.key, cpu: min($0.value, ncpu * 100)) }
        top = result
    }
}
