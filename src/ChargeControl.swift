import Foundation

// Charge-control state as reported by the helper's BSTATUS command.
struct ChargeControlStatus: Equatable {
    enum Backend: String { case none, chte, ch0bc }
    var backend: Backend
    var settings: ChargeLimitSettings
    var topUp: Bool
    var inhibited: Bool
    var heatHeld: Bool
    var charging: Bool
    var temperature: Double?   // °C
    var ledSupported: Bool
    var adapterSupported: Bool
    var adapterCut: Bool          // OmniStats is running the Mac from its battery
    var plugged: Bool             // the adapter is physically connected
    var dischargeTarget: Int?     // manual discharge session
    var calibration: Calibration
    var calibrationElapsed: TimeInterval
    var calibrationResult: Int    // 0 none, 1 finished, 2 stopped early
    var percent: Int?             // the helper's last battery reading
    var conflict: String?
    var writeFailed: Bool

    enum Calibration: Int { case idle, charge1, hold1, discharge, charge2, hold2, toLimit }

    init?(reply: String) {
        guard reply.hasPrefix("OK ") else { return nil }
        var fields: [String: String] = [:]
        for token in reply.dropFirst(3).split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            fields[String(parts[0])] = String(parts[1])
        }
        func flag(_ key: String) -> Bool? { fields[key].flatMap { Int($0) }.map { $0 != 0 } }
        guard let backend = fields["backend"].flatMap(Backend.init(rawValue:)),
              let enabled = flag("enabled"), let limit = fields["limit"].flatMap({ Int($0) }),
              let sailing = fields["sailing"].flatMap({ Int($0) }),
              let sleepStop = flag("sleepstop"), let stayAwake = flag("stayawake"),
              let heat = flag("heat"), let heatLimit = fields["heatlimit"].flatMap({ Int($0) }),
              let led = fields["led"].flatMap({ Int($0) }).flatMap(ChargeLimitSettings.LedMode.init(rawValue:)),
              let topUp = flag("topup"), let inhibited = flag("inhibited"), let heatHeld = flag("heatheld"),
              let charging = flag("charging"), let temperature = fields["temp"].flatMap({ Int($0) }),
              let ledSupported = flag("ledsupported"),
              let adapter = flag("adapter"), let cut = flag("cut"), let plugged = flag("plugged"),
              let discharge = fields["discharge"].flatMap({ Int($0) }), let autoDischarge = flag("autodischarge"),
              let calibration = fields["calibration"].flatMap({ Int($0) }).flatMap(Calibration.init(rawValue:)),
              let calibrationElapsed = fields["calelapsed"].flatMap({ Int($0) }),
              let calibrationResult = fields["calresult"].flatMap({ Int($0) }),
              let conflict = fields["conflict"], let writeFailed = flag("writefailed") else { return nil }
        self.backend = backend
        settings = ChargeLimitSettings(enabled: enabled, limit: limit, sailing: sailing,
                                       sleepStop: sleepStop, stayAwake: stayAwake,
                                       heatProtect: heat, heatLimit: heatLimit, ledMode: led, autoDischarge: autoDischarge)
        self.topUp = topUp; self.inhibited = inhibited; self.heatHeld = heatHeld; self.charging = charging
        self.temperature = temperature > 0 ? Double(temperature) / 100 : nil
        self.ledSupported = ledSupported; self.writeFailed = writeFailed
        adapterSupported = adapter; adapterCut = cut; self.plugged = plugged
        dischargeTarget = discharge > 0 ? discharge : nil
        self.calibration = calibration; self.calibrationElapsed = TimeInterval(calibrationElapsed)
        self.calibrationResult = calibrationResult
        percent = fields["percent"].flatMap { Int($0) }.flatMap { (1...100).contains($0) ? $0 : nil }
        self.conflict = conflict == "-" ? nil : conflict
    }
}

// What the user edits; the helper validates and persists it.
struct ChargeLimitSettings: Equatable {
    var enabled: Bool
    var limit: Int
    var sailing: Int
    var sleepStop: Bool
    var stayAwake: Bool
    var heatProtect: Bool
    var heatLimit: Int         // °C
    var ledMode: LedMode
    var autoDischarge: Bool = false

    // macOS keeps the MagSafe LED, OmniStats shows charging (orange) or not (green), or it stays off.
    enum LedMode: Int, CaseIterable, Identifiable { case system, status, off; var id: Int { rawValue } }

    static let limitRange = 20...100
    static let sailingRange = 1...20
    static let heatRange = 30...50
    var resumeAt: Int { max(0, limit - sailing) }
    var command: String {
        "BSET enabled=\(enabled ? 1 : 0) limit=\(limit) sailing=\(sailing) "
            + "sleepstop=\(sleepStop ? 1 : 0) stayawake=\(stayAwake ? 1 : 0) "
            + "heat=\(heatProtect ? 1 : 0) heatlimit=\(heatLimit) led=\(ledMode.rawValue) "
            + "autodischarge=\(autoDischarge ? 1 : 0)"
    }
}

// macOS's own charge limit (System Settings › Battery). Reading it takes a private
// entitlement that only system tools carry, so this asks pmset.
enum NativeChargeLimit {
    static func parse(_ output: String) -> Int? {
        var limits: [Int] = []
        for block in output.components(separatedBy: "{").dropFirst() {
            var fields: [String: String] = [:]
            for line in (block.components(separatedBy: "}").first ?? "").split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                fields[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            }
            // Only the user's manual limit: other reasons (e.g. optimized charging) are temporary.
            guard fields["chargeSocLimitReason"] == "manualChargeLimit", fields["Terminated"] != "1",
                  let soc = fields["chargeSocLimitSoc"].flatMap({ Int($0) }), (1...100).contains(soc) else { continue }
            limits.append(soc)
        }
        return limits.min()
    }

    static func read() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "battlimit"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }
}

// Polls the helper while the panel or Settings shows charge control; edits go
// straight to the helper, which owns the policy.
final class ChargeController: ObservableObject {
    @Published private(set) var status: ChargeControlStatus?
    @Published private(set) var nativeLimit: Int?
    @Published private(set) var lastError: String?
    typealias Request = (String, @escaping (String?) -> Void) -> Void
    private let request: Request
    private let readNativeLimit: () -> Int?
    private let nativeQueue = DispatchQueue(label: "com.omnistats.nativelimit", qos: .utility)
    private var timer: Timer?
    private var lastNativeRead: TimeInterval = -.infinity
    private(set) var pollingInterval: TimeInterval?

    init(monitor: Monitor, request: Request? = nil, readNativeLimit: @escaping () -> Int? = NativeChargeLimit.read) {
        self.request = request ?? { [weak monitor] command, completion in
            guard let monitor else { completion(nil); return }
            monitor.helperRequest(command, completion: completion)
        }
        self.readNativeLimit = readNativeLimit
    }
    deinit { timer?.invalidate() }

    func setPollingInterval(_ interval: TimeInterval?) {
        guard interval != pollingInterval else { return }
        pollingInterval = interval
        timer?.invalidate(); timer = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        refresh(forceNative: true)
    }

    func refresh(forceNative: Bool = false) {
        request("BSTATUS") { [weak self] reply in
            guard let self else { return }
            let next = reply.flatMap(ChargeControlStatus.init(reply:))
            if self.status != next { self.status = next }
        }
        // pmset is a process launch: at most every 30 s.
        guard forceNative || sampleTime() - lastNativeRead >= 30 else { return }
        lastNativeRead = sampleTime()
        nativeQueue.async { [weak self, readNativeLimit] in
            let limit = readNativeLimit()
            DispatchQueue.main.async { [weak self] in
                if let self, self.nativeLimit != limit { self.nativeLimit = limit }
            }
        }
    }

    func apply(_ settings: ChargeLimitSettings) { send(settings.command) }
    func setTopUp(_ enabled: Bool) { send("BTOPUP \(enabled ? 1 : 0)") }
    func perform(_ command: AutomationCommand) { command.helperCommand.map(send) }
    // Not reachable from links or schedules: these run the Mac from its battery.
    func discharge(to target: Int?) { send("BDISCHARGE \(target ?? 0)") }
    func calibrate(_ start: Bool) { send("BCALIBRATE \(start ? 1 : 0)") }

    private func send(_ command: String) {
        request(command) { [weak self] reply in
            guard let self else { return }
            self.lastError = reply == "OK" ? nil : (reply ?? L.t("cc.unreachable"))
            self.refresh()
        }
    }
}
