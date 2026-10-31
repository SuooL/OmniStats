import SwiftUI
import AppKit
import Combine

// Apply dark/light chrome (window borders, traffic lights, popover edge) to match
// the chosen theme; .system hands it back to macOS. No-op when already correct.
func applyAppChrome(_ m: AppearanceMode) {
    let want: NSAppearance.Name? = m == .system ? nil : m == .dark ? .darkAqua : .aqua
    if NSApp?.appearance?.name != want { NSApp?.appearance = want.flatMap(NSAppearance.init(named:)) }
}

// Apply presentation once per configuration change, outside SwiftUI body
// evaluation. Reading/mutating AppKit appearance from a body can establish
// observation dependencies that feed back into AppKit/SwiftUI layout.
func syncPresentation(_ cfg: OmniStatsConfig) {
    applyAppChrome(cfg.appearance)
    Theme.mode = cfg.appearance.resolved
    Theme.accentPreset = cfg.accent
    L.lang = cfg.language
}

// MARK: - Privileged helper install (single native admin prompt, no Terminal)
enum HelperInstaller {
    static let plistDst = "/Library/LaunchDaemons/com.omnistats.smcd.plist"
    static let binDst   = "/usr/local/sbin/omnistats-smcd"

    static func runPrivileged(_ shell: String) -> Bool {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        else { return false }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        return err == nil
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func install() -> Bool {
        guard let res = Bundle.main.resourcePath else { return false }
        // `cp -X` drops extended attributes: a copy from a downloaded bundle would
        // otherwise carry com.apple.quarantine, and the macOS 27 release notes say
        // launchd no longer loads property lists that have it.
        let cmd = [
            "mkdir -p /usr/local/sbin",
            "cp -X \(shellQuote(res + "/omnistats-smcd")) \(shellQuote(binDst))",
            "chown root:wheel '\(binDst)'", "chmod 755 '\(binDst)'",
            "cp -X \(shellQuote(res + "/com.omnistats.smcd.plist")) \(shellQuote(plistDst))",
            "chown root:wheel '\(plistDst)'", "chmod 644 '\(plistDst)'",
            "(launchctl unload '\(plistDst)' 2>/dev/null || true)",
            "launchctl load -w '\(plistDst)'",
        ].joined(separator: " && ")
        return runPrivileged(cmd)
    }
    static func uninstall() -> Bool {
        let cmd = [
            "(launchctl unload '\(plistDst)' 2>/dev/null || true)",
            "rm -f '\(plistDst)' '\(binDst)' /var/run/omnistats.sock",
            "rm -rf '/Library/Application Support/OmniStats'",
        ].joined(separator: " && ")
        return runPrivileged(cmd)
    }
}

// MARK: - Sensor monitor
final class Monitor: ObservableObject {
    @Published var socMax = Float.nan
    @Published var socAvg = Float.nan
    @Published var ssd = Float.nan
    @Published var battery = Float.nan
    @Published var power = Float.nan
    @Published var volt = Float.nan
    @Published var fanCount = 0
    @Published var fanRPM: [Float] = []
    @Published var fanMin: [Float] = []
    @Published var fanMax: [Float] = []
    @Published var fanMode: [Int] = []
    @Published var helperAvailable = false
    @Published var busy = false

    // Rolling history for the top-cluster charts at the display sampling cadence.
    // Reference buffers — reads happen during body re-renders driven by the
    // @Published sensor values above, so they need no separate publishing.
    let socHistory = MetricSeries(retention: 3600)
    let ssdHistory = MetricSeries(retention: 3600)
    let fanHistory = MetricSeries(retention: 3600)

    // Average fan speed as a percent of range (0…100), NaN-safe.
    var fanAvgPct: Double {
        guard fanCount > 0 else { return 0 }
        var sum = 0.0, n = 0
        for i in 0..<fanCount where i < fanRPM.count && i < fanMax.count && !fanRPM[i].isNaN && fanMax[i] > 0 {
            sum += Double(fanRPM[i] / fanMax[i]) * 100; n += 1
        }
        return n > 0 ? sum / Double(n) : 0
    }

    @Published private(set) var lastSampleTime: TimeInterval = 0
    @Published private(set) var helperNeedsUpdate = false
    @Published var controlError: String?
    private let sensorQueue = DispatchQueue(label: "com.omnistats.sensors", qos: .utility)
    private let control = ControlChannel()
    private var timer: Timer?
    private var sampleInFlight = false
    private var generation = 0
    private var rediscover = true
    private(set) var samplingInterval: TimeInterval?
    private(set) var hardwareSamplingInterval: TimeInterval?
    private(set) var latestSnapshot: Snapshot?
    private var lastHelperPoll: TimeInterval = 0

    init(startSampling: Bool = true) {
        if startSampling { setSamplingInterval(10) }
    }
    deinit { timer?.invalidate() }

    func setSamplingInterval(_ interval: TimeInterval?, controlInterval: TimeInterval? = nil) {
        let hardware = [interval, controlInterval].compactMap { $0 }.min()
        guard interval != samplingInterval || hardware != hardwareSamplingInterval else { return }
        let wasPaused = hardwareSamplingInterval == nil
        samplingInterval = interval; hardwareSamplingInterval = hardware; generation += 1
        timer?.invalidate(); timer = nil
        guard let hardware else { lastSampleTime = 0; latestSnapshot = nil; return }
        let timer = Timer(timeInterval: hardware, repeats: true) { [weak self] _ in self?.refresh(forcePublication: false) }
        timer.tolerance = hardware * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if wasPaused { rediscover = true; refresh(forcePublication: interval != nil) }
    }

    struct Snapshot {
        var time = sampleTime()
        var socMax: Float = .nan, socAvg: Float = .nan, ssd: Float = .nan, battery: Float = .nan
        var power: Float = .nan, volt: Float = .nan
        var fanRPM: [Float] = [], fanMin: [Float] = [], fanMax: [Float] = []
        var fanMode: [Int] = []
        static func read() -> Snapshot {
            var result = Snapshot()
            cb_refresh()
            result.socMax = cb_soc_max(); result.socAvg = cb_soc_avg()
            result.ssd = cb_ssd(); result.battery = cb_battery()
            result.power = cb_power(); result.volt = cb_volt()
            let count = min(8, max(0, Int(cb_fan_count())))
            result.fanRPM = (0..<count).map { cb_fan_rpm(Int32($0)) }
            result.fanMin = (0..<count).map { cb_fan_min(Int32($0)) }
            result.fanMax = (0..<count).map { cb_fan_max(Int32($0)) }
            result.fanMode = (0..<count).map { Int(cb_fan_mode(Int32($0))) }
            return result
        }
    }

    func refresh(forcePublication: Bool = true) {
        guard !sampleInFlight else { return }
        sampleInFlight = true
        let current = generation, shouldDiscover = rediscover
        rediscover = false
        sensorQueue.async { [weak self] in
            if shouldDiscover { cb_sensors_init() }
            let result = Snapshot.read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sampleInFlight = false
                guard self.generation == current else { return }
                let publish = forcePublication || self.samplingInterval.map {
                    self.lastSampleTime == 0 || result.time - self.lastSampleTime >= $0 - 0.05
                } == true
                self.accept(result, publish: publish)
            }
        }
        guard !busy, forcePublication || sampleTime() - lastHelperPoll >= (samplingInterval ?? 10) else { return }
        lastHelperPoll = sampleTime()
        control.poll { [weak self] available, version in
            guard let self else { return }
            if self.helperAvailable != available { self.helperAvailable = available }
            let needsUpdate = available && version < 8
            if self.helperNeedsUpdate != needsUpdate { self.helperNeedsUpdate = needsUpdate }
        }
    }

    func accept(_ result: Snapshot, publish: Bool = true) {
        latestSnapshot = result
        guard publish else { return }
        socMax = result.socMax; socAvg = result.socAvg
        ssd = result.ssd; battery = result.battery
        power = result.power; volt = result.volt
        fanRPM = result.fanRPM; fanMin = result.fanMin
        fanMax = result.fanMax; fanMode = result.fanMode
        if fanCount != fanRPM.count { fanCount = fanRPM.count }
        let cadence = samplingInterval ?? 2
        if socMax.isFinite { socHistory.record(Double(socMax), at: result.time, cadence: cadence) }
        if ssd.isFinite { ssdHistory.record(Double(ssd), at: result.time, cadence: cadence) }
        if fanCount > 0 { fanHistory.record(fanAvgPct, at: result.time, cadence: cadence) }
        lastSampleTime = result.time
    }

    func hasFreshTemperature(at now: TimeInterval) -> Bool {
        guard let sample = latestSnapshot else { return false }
        return sample.socMax.isFinite && sample.time > 0 && now >= sample.time && now - sample.time <= 6
    }
    func command(_ plan: ControlPlan) {
        guard !busy else { return }
        control.submit(plan) { [weak self] success in
            guard let self else { return }
            if !success && self.helperAvailable { self.controlError = L.t("control.failed") }
            else if success { self.controlError = nil }
        }
    }
    func revertAll() { command(.automatic) }
    // Battery control needs protocol 8; older helpers get the update prompt.
    var helperSupportsBattery: Bool { helperAvailable && !helperNeedsUpdate }
    func helperRequest(_ command: String, completion: @escaping (String?) -> Void) {
        guard !busy, helperSupportsBattery else { completion(nil); return }
        control.request(command, completion: completion)
    }
    func shutdown() { timer?.invalidate(); control.shutdown() }

    func enableControl(_ done: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true; controlError = nil
        control.disconnect { [weak self] in
            DispatchQueue.global().async {
                let ok = HelperInstaller.install()
                DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 1 : 0)) {
                    guard let self else { return }
                    self.busy = false
                    if !ok { self.controlError = L.t("control.installFailed") }
                    self.refresh(); done?()
                }
            }
        }
    }
    func disableControl() {
        guard !busy else { return }
        busy = true; controlError = nil
        control.disconnect { [weak self] in
            DispatchQueue.global().async {
                let ok = HelperInstaller.uninstall()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy = false
                    if !ok { self.controlError = L.t("control.installFailed") }
                    self.refresh()
                }
            }
        }
    }
}

// An independent 1.5s control loop runs only in manual/curve modes. Display
// energy settings never slow it down. Stale curve input hands control back to
// firmware; resuming requires a fresh sample and restarts smoothing/slew state.
final class Engine: ObservableObject {
    let monitor: Monitor
    let store: ConfigStore
    @Published private(set) var drivingTemp = Double.nan
    @Published private(set) var safetyPaused = false
    private var timer: Timer?
    private var currentPct: [Double] = []
    private var smoothedTemp = Double.nan
    private var lastStep = sampleTime()
    private var suspended = false
    private var bag = Set<AnyCancellable>()
    private(set) var isRunning = false
    var commandedPct: Double { currentPct.first ?? 0 }

    init(monitor: Monitor, store: ConfigStore) {
        self.monitor = monitor; self.store = store
        Publishers.Merge(store.$config.map(\.mode).removeDuplicates().map { _ in () },
                         monitor.$fanCount.removeDuplicates().map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.configure() }.store(in: &bag)
        monitor.$lastSampleTime.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, self.store.config.mode == .auto else { return }
            self.step()
        }.store(in: &bag)
        monitor.$helperAvailable.receive(on: RunLoop.main).sink { [weak self] available in
            if available { self?.step() }
        }.store(in: &bag)
        configure()
    }
    deinit { timer?.invalidate() }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        smoothedTemp = .nan; currentPct = []; lastStep = sampleTime()
        configure()
    }
    private func configure() {
        let shouldRun = !suspended && store.config.mode != .auto && monitor.fanCount > 0
        if shouldRun != isRunning {
            timer?.invalidate(); timer = nil
            isRunning = shouldRun; lastStep = sampleTime()
            if shouldRun {
                let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.step() }
                RunLoop.main.add(t, forMode: .common); timer = t
            }
        }
        step()
    }
    private func pctFromRPM(_ fan: Int) -> Double {
        let actual = monitor.latestSnapshot?.fanRPM ?? monitor.fanRPM
        let minima = monitor.latestSnapshot?.fanMin ?? monitor.fanMin
        let maxima = monitor.latestSnapshot?.fanMax ?? monitor.fanMax
        guard fan < actual.count, fan < minima.count, fan < maxima.count else { return 0 }
        let rpm = Double(actual[fan]), minimum = Double(minima[fan]), maximum = Double(maxima[fan])
        guard rpm.isFinite, minimum.isFinite, maximum.isFinite, maximum > minimum else { return 0 }
        return min(100, max(0, (rpm - minimum) / (maximum - minimum) * 100))
    }

    func step(at now: TimeInterval = sampleTime()) {
        let dt = max(0, min(3, now - lastStep)); lastStep = now
        let cfg = store.config.validated()
        let count = monitor.latestSnapshot?.fanRPM.count ?? monitor.fanCount
        let minima = monitor.latestSnapshot?.fanMin ?? monitor.fanMin
        let maxima = monitor.latestSnapshot?.fanMax ?? monitor.fanMax
        if suspended || cfg.mode == .auto || count == 0 {
            if monitor.helperAvailable { monitor.revertAll() }
            currentPct = (0..<count).map { pctFromRPM($0) }
            drivingTemp = Double(monitor.socMax)
            safetyPaused = false; smoothedTemp = .nan
            return
        }
        guard cfg.mode != .curve || monitor.hasFreshTemperature(at: now) else {
            monitor.revertAll()
            safetyPaused = true; smoothedTemp = .nan; currentPct = []
            drivingTemp = .nan
            return
        }
        guard minima.count == count, maxima.count == count,
              (0..<count).allSatisfy({ minima[$0].isFinite && maxima[$0].isFinite
                  && minima[$0] >= 0 && maxima[$0] > minima[$0]
                  && maxima[$0] < Float(Int32.max) }) else {
            monitor.revertAll(); safetyPaused = true; return
        }
        safetyPaused = false
        if currentPct.count != count { currentPct = (0..<count).map { pctFromRPM($0) } }
        let raw = Double(monitor.latestSnapshot?.socMax ?? monitor.socMax)
        if raw.isFinite {
            let alpha = 1 - pow(0.75, dt / 1.5)
            smoothedTemp = smoothedTemp.isFinite ? smoothedTemp + alpha * (raw - smoothedTemp) : raw
        }
        let desired = cfg.mode == .manual ? cfg.manualPct : cfg.curvePct(at: smoothedTemp)
        guard desired.isFinite else { monitor.revertAll(); safetyPaused = true; return }
        var rpms: [Int] = []
        for fan in 0..<count {
            let current = currentPct[fan]
            if abs(desired - current) > cfg.deadbandPct {
                currentPct[fan] = desired > current ? min(desired, current + cfg.rampUpPctPerSec * dt)
                    : max(desired, current - cfg.rampDownPctPerSec * dt)
            }
            let minimum = Double(minima[fan]), maximum = Double(maxima[fan])
            rpms.append(Int(minimum + currentPct[fan] / 100 * (maximum - minimum)))
        }
        drivingTemp = smoothedTemp
        if monitor.helperAvailable {
            let expiry = cfg.mode == .curve ? (monitor.latestSnapshot?.time ?? 0) + 6 : now + 3
            monitor.command(.manual(rpms: rpms, validUntil: expiry))
        }
    }
}
