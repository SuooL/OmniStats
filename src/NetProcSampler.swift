import Foundation

struct NetProcUsage: Identifiable {
    let id = UUID()
    let name: String
    let rxBps: Double     // download, bytes/sec
    let txBps: Double     // upload,   bytes/sec
}

// Top processes by network throughput, merged per app.
//
// macOS has no public per-process bandwidth API, so this shells out to the
// built-in `nettop` (works without root) in streaming log mode:
//   nettop -P -x -l 0 -s 2 -J bytes_in,bytes_out
// Each refresh prints a block of "name.pid  bytes_in  bytes_out" (cumulative).
// We diff consecutive blocks into bytes/sec, resolve each PID to its bundle
// name via `appDisplayName` (same merge as ProcSampler), sum per app, and
// publish the top 5. Only runs while `enabled` (the network panel is expanded),
// so the child process exists only when its output is on screen.
final class NetProcSampler: ObservableObject {
    @Published var top: [NetProcUsage] = []

    var enabled = false { didSet { if enabled != oldValue { enabled ? start() : stop() } } }

    private let interval = 2.0
    private var proc: Process?
    private var readHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.omnistats.netproc")
    private var buffer = Data()
    private var block: [String] = []               // rows accumulated for the current block
    private var prev: [pid_t: (rx: UInt64, tx: UInt64)] = [:]
    private var prevTime: CFAbsoluteTime = 0

    private func start() {
        queue.async { [weak self] in self?.launch() }
    }

    private func launch() {
        guard proc == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-x", "-l", "0", "-s", String(Int(interval)), "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.queue.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.proc = nil }
        }
        do { try p.run() } catch { return }
        prev = [:]; prevTime = 0; buffer.removeAll(); block.removeAll()
        proc = p
        readHandle = pipe.fileHandleForReading
    }

    private func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.readHandle?.readabilityHandler = nil
            self.readHandle = nil
            self.proc?.terminate()
            self.proc = nil
            self.buffer.removeAll(); self.block.removeAll(); self.prev = [:]
            DispatchQueue.main.async { self.top = [] }
        }
    }

    // MARK: parse (on `queue`)
    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self)
            if line.contains("bytes_in") {
                if !block.isEmpty { finishBlock() }   // header starts a new block
                block.removeAll()
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                block.append(line)
            }
        }
    }

    private func finishBlock() {
        var cur: [pid_t: (rx: UInt64, tx: UInt64)] = [:]
        for line in block {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard toks.count >= 3,
                  let txOut = UInt64(toks[toks.count - 1]),
                  let rxIn = UInt64(toks[toks.count - 2]),
                  let dot = toks[0].lastIndex(of: "."),
                  let pid = pid_t(toks[0][toks[0].index(after: dot)...])
            else { continue }
            cur[pid] = (rxIn, txOut)
        }

        let now = CFAbsoluteTimeGetCurrent()
        defer { prev = cur; prevTime = now }
        guard prevTime > 0 else { return }              // first block: baseline only
        let dt = max(0.5, now - prevTime)

        var byName: [String: (rx: Double, tx: Double)] = [:]
        for (pid, c) in cur {
            guard let p = prev[pid], c.rx >= p.rx, c.tx >= p.tx else { continue }
            let drx = Double(c.rx - p.rx) / dt, dtx = Double(c.tx - p.tx) / dt
            if drx + dtx < 1 { continue }               // ignore idle
            let name = appDisplayName(pid)
            byName[name, default: (0, 0)].rx += drx
            byName[name, default: (0, 0)].tx += dtx
        }

        let ranked = byName.sorted { ($0.value.rx + $0.value.tx) > ($1.value.rx + $1.value.tx) }
            .prefix(5)
            .map { NetProcUsage(name: $0.key, rxBps: $0.value.rx, txBps: $0.value.tx) }
        DispatchQueue.main.async { [weak self] in self?.top = ranked }
    }
}
