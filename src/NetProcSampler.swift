import Foundation
import Darwin

struct NetProcUsage: Identifiable {
    var id: String { name }
    let name: String
    let rxBps: Double
    let txBps: Double
}

// nettop -l emits whitespace-separated blocks with cumulative byte counters.
// Parse rows immediately instead of retaining every line of a block. Both the
// partial line and process table are bounded even if the subprocess misbehaves.
struct NetTopParser {
    struct Counter { let rx: UInt64; let tx: UInt64 }
    struct Frame { let time: Double; let counters: [pid_t: Counter] }
    private var buffer = Data()
    private var rows: [pid_t: Counter] = [:]
    private var headerTime: Double?
    private(set) var overflowed = false

    mutating func consume(_ data: Data, at time: Double) -> [Frame] {
        guard buffer.count + data.count <= 1_048_576 else { resetOverflow(); return [] }
        buffer.append(data)
        var frames: [Frame] = []
        var cursor = buffer.startIndex
        while cursor < buffer.endIndex, let newline = buffer[cursor...].firstIndex(of: 10) {
            let line = String(decoding: buffer[cursor..<newline], as: UTF8.self)
            cursor = buffer.index(after: newline)
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            if tokens.contains("bytes_in") && tokens.contains("bytes_out") {
                if let headerTime { frames.append(Frame(time: headerTime, counters: rows)) }
                rows.removeAll(keepingCapacity: true); headerTime = time
            } else if headerTime != nil, tokens.count >= 3,
                      let rx = UInt64(tokens[tokens.count - 2]), let tx = UInt64(tokens[tokens.count - 1]) {
                let identifier = tokens[tokens.count - 3]
                if let dot = identifier.lastIndex(of: "."),
                   let pid = pid_t(identifier[identifier.index(after: dot)...]), pid > 0 {
                    guard rows.count < 8192 || rows[pid] != nil else { resetOverflow(); return [] }
                    rows[pid] = Counter(rx: rx, tx: tx)
                }
            }
        }
        if cursor > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<cursor) }
        if buffer.count > 4096 { resetOverflow(); return [] }
        return frames
    }
    private mutating func resetOverflow() {
        buffer.removeAll(); rows.removeAll(); headerTime = nil; overflowed = true
    }
}

struct NetTopRates {
    private var previous: NetTopParser.Frame?
    mutating func consume(_ frame: NetTopParser.Frame, name: (pid_t) -> String = appDisplayName) -> [NetProcUsage]? {
        defer { previous = frame }
        guard let previous else { return nil }
        let dt = frame.time - previous.time
        guard dt > 0, dt < 60 else { return [] }
        var values: [String: (rx: Double, tx: Double)] = [:]
        for (pid, current) in frame.counters {
            guard let old = previous.counters[pid], current.rx >= old.rx, current.tx >= old.tx else { continue }
            let rx = Double(current.rx - old.rx) / dt, tx = Double(current.tx - old.tx) / dt
            guard rx + tx >= 1 else { continue }
            let app = name(pid)
            values[app, default: (0, 0)].rx += rx
            values[app, default: (0, 0)].tx += tx
        }
        return values.sorted {
            let a = $0.value.rx + $0.value.tx, b = $1.value.rx + $1.value.tx
            return a == b ? $0.key < $1.key : a > b
        }.prefix(5).map { NetProcUsage(name: $0.key, rxBps: $0.value.rx, txBps: $0.value.tx) }
    }
}

// Process lifecycle and published state are main-queue owned. Each launch gets
// an independent parser and generation; callbacks from an old child cannot
// clear or overwrite a newer session after rapid expand/collapse interactions.
final class NetProcSampler: ObservableObject {
    enum State { case stopped, warmingUp, running, unavailable }
    @Published var top: [NetProcUsage] = []
    @Published private(set) var state: State = .stopped
    var enabled = false { didSet { if enabled != oldValue { update() } } }
    var suspended = false { didSet { if suspended != oldValue { update() } } }
    private var process: Process?
    private let runnerURL: URL?
    init(runnerURL: URL? = Bundle.main.url(forResource: "omnistats-nettop", withExtension: nil)) {
        self.runnerURL = runnerURL
    }
    var processIdentifier: pid_t? { process?.processIdentifier }
    private var readSource: DispatchSourceRead?
    private var generation = UUID()
    private let parseQueue = DispatchQueue(label: "com.omnistats.netproc", qos: .utility)
    private final class Session { var parser = NetTopParser(); var rates = NetTopRates() }

    deinit {
        readSource?.cancel()
        if process?.isRunning == true { process?.terminate() }
    }
    private func update() { enabled && !suspended ? start() : stop() }
    private func start() {
        guard process == nil else { return }
        guard let runnerURL else { state = .unavailable; return }
        generation = UUID()
        let id = generation, session = Session()
        // nettop fully buffers stdout when attached to a pipe. A PTY makes
        // each sample arrive promptly even on machines with few processes.
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { state = .unavailable; return }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        let writer = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let child = Process()
        // The runner keeps stdin open and reaps nettop even after an app crash.
        child.executableURL = runnerURL
        child.standardOutput = writer; child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        state = .warmingUp
        let fd = master
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: parseQueue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
            guard count > 0 else {
                DispatchQueue.main.async { [weak self] in self?.finished(id) }
                return
            }
            let frames = session.parser.consume(Data(bytes.prefix(count)), at: sampleTime())
            if session.parser.overflowed {
                DispatchQueue.main.async { [weak self] in self?.finished(id) }
                return
            }
            for frame in frames {
                guard let ranked = session.rates.consume(frame) else { continue }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id, self.enabled, !self.suspended else { return }
                    self.top = ranked; self.state = .running
                }
            }
        }
        readSource = source; source.resume()
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.finished(id) }
        }
        do {
            try child.run(); process = child
            try? writer.close()
        } catch { try? writer.close(); finished(id) }
    }
    private func finished(_ id: UUID) {
        guard generation == id else { return }
        stop(); state = .unavailable
    }
    private func stop() {
        generation = UUID()
        readSource?.cancel(); readSource = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; top = []; state = .stopped
    }
}
