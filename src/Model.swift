import SwiftUI
import AppKit

// Apply dark/light chrome (window borders, traffic lights, popover edge) to match
// the chosen theme. No-op when already correct.
func applyAppChrome(_ m: AppearanceMode) {
    let want: NSAppearance.Name = (m == .dark) ? .darkAqua : .aqua
    if NSApp.appearance?.name != want {
        DispatchQueue.main.async { NSApp.appearance = NSAppearance(named: want) }
    }
}

// Push the config's presentation choices into the global render state. Called at
// the top of every root view body so each render reflects the current theme,
// accent, and language (SwiftUI re-runs the body when `ConfigStore` publishes).
func syncPresentation(_ cfg: OmniStatsConfig) {
    Theme.mode = cfg.appearance
    Theme.accentPreset = cfg.accent
    L.lang = cfg.language
    applyAppChrome(cfg.appearance)
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
    static func install() -> Bool {
        guard let res = Bundle.main.resourcePath else { return false }
        let cmd = [
            "mkdir -p /usr/local/sbin",
            "cp '\(res)/omnistats-smcd' '\(binDst)'",
            "chown root:wheel '\(binDst)'", "chmod 755 '\(binDst)'",
            "cp '\(res)/com.omnistats.smcd.plist' '\(plistDst)'",
            "chown root:wheel '\(plistDst)'", "chmod 644 '\(plistDst)'",
            "launchctl unload '\(plistDst)' 2>/dev/null || true",
            "launchctl load -w '\(plistDst)'",
        ].joined(separator: " && ")
        return runPrivileged(cmd)
    }
    static func uninstall() -> Bool {
        let cmd = [
            "launchctl unload '\(plistDst)' 2>/dev/null || true",
            "rm -f '\(plistDst)' '\(binDst)' /var/run/omnistats.sock",
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

    // Rolling history for the top-cluster time-series charts (up to 1h @ 2s tick).
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

    private var timer: Timer?

    init() {
        cb_sensors_init()
        fanCount = Int(cb_fan_count())
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        cb_refresh()
        socMax = cb_soc_max(); socAvg = cb_soc_avg()
        ssd = cb_ssd(); battery = cb_battery()
        power = cb_power(); volt = cb_volt()
        fanRPM  = (0..<fanCount).map { cb_fan_rpm(Int32($0)) }
        fanMin  = (0..<fanCount).map { cb_fan_min(Int32($0)) }
        fanMax  = (0..<fanCount).map { cb_fan_max(Int32($0)) }
        fanMode = (0..<fanCount).map { Int(cb_fan_mode(Int32($0))) }
        helperAvailable = (cb_ctl_available() == 1)

        let now = CFAbsoluteTimeGetCurrent()
        if !socMax.isNaN { socHistory.record(Double(socMax), at: now) }
        if !ssd.isNaN    { ssdHistory.record(Double(ssd), at: now) }
        if fanCount > 0  { fanHistory.record(fanAvgPct, at: now) }
    }
    func revertAll() { _ = cb_ctl_auto_all() }

    func enableControl(_ done: (() -> Void)? = nil) {
        busy = true
        DispatchQueue.global().async {
            let ok = HelperInstaller.install()
            DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 1.0 : 0)) {
                self.busy = false; self.refresh(); done?()
            }
        }
    }
    func disableControl() {
        revertAll(); busy = true
        DispatchQueue.global().async {
            _ = HelperInstaller.uninstall()
            DispatchQueue.main.async { self.busy = false; self.refresh() }
        }
    }
}

// MARK: - Hardware-friendly control engine
// Drives every fan toward a target derived from the current mode, moving the
// commanded speed by a bounded step each tick (slew-rate limiting) with a
// hysteresis deadband — no abrupt RPM jumps.
final class Engine: ObservableObject {
    let monitor: Monitor
    let store: ConfigStore
    private var timer: Timer?
    private var currentPct: [Double] = []      // slewed command per fan (percent)
    private var lastMode: FanMode = .auto
    private let tick = 1.5

    // Temperature smoothing (EMA) so brief spikes don't make fans surge.
    private var smoothedTemp: Double = .nan
    private let tempAlpha = 0.25               // ~6s time constant at 1.5s tick
    var drivingTemp: Double = .nan             // smoothed temp actually driving the curve

    init(monitor: Monitor, store: ConfigStore) {
        self.monitor = monitor
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in self?.step() }
    }

    private func pctToRpm(_ fan: Int, _ pct: Double) -> Int {
        let mn = fan < monitor.fanMin.count && !monitor.fanMin[fan].isNaN ? Double(monitor.fanMin[fan]) : 1200
        let mx = fan < monitor.fanMax.count && !monitor.fanMax[fan].isNaN ? Double(monitor.fanMax[fan]) : 6000
        return Int(mn + max(0, min(100, pct)) / 100 * (mx - mn))
    }
    private func rpmToPct(_ fan: Int, _ rpm: Float) -> Double {
        guard fan < monitor.fanMin.count, fan < monitor.fanMax.count,
              !rpm.isNaN, !monitor.fanMin[fan].isNaN, !monitor.fanMax[fan].isNaN else { return 0 }
        let mn = Double(monitor.fanMin[fan]), mx = Double(monitor.fanMax[fan])
        guard mx > mn else { return 0 }
        return max(0, min(100, (Double(rpm) - mn) / (mx - mn) * 100))
    }

    // The commanded percent applied to fan 0 (for the live "operating point").
    var commandedPct: Double { currentPct.first ?? 0 }

    private func step() {
        let n = monitor.fanCount
        guard n > 0 else { return }
        if currentPct.count != n {
            currentPct = (0..<n).map { rpmToPct($0, $0 < monitor.fanRPM.count ? monitor.fanRPM[$0] : .nan) }
        }
        // EMA-smooth the driving temperature every tick.
        let raw = Double(monitor.socMax)
        if !raw.isNaN { smoothedTemp = smoothedTemp.isNaN ? raw : smoothedTemp + tempAlpha * (raw - smoothedTemp) }
        drivingTemp = smoothedTemp

        let cfg = store.config
        switch cfg.mode {
        case .auto:
            if lastMode != .auto { for i in 0..<n { _ = cb_ctl_auto(Int32(i)) } }
            for i in 0..<n { currentPct[i] = rpmToPct(i, i < monitor.fanRPM.count ? monitor.fanRPM[i] : .nan) }
        case .manual, .curve:
            // Compute the slewed command even without the helper (live preview);
            // only actually push it to hardware when control is available.
            let temp = smoothedTemp.isNaN ? Double(monitor.socMax) : smoothedTemp
            for i in 0..<n {
                let desired = cfg.mode == .manual ? cfg.manualPct : cfg.curvePct(at: temp)
                let cur = currentPct[i]
                var next = cur
                if abs(desired - cur) > cfg.deadbandPct {
                    let up = cfg.rampUpPctPerSec * tick, down = cfg.rampDownPctPerSec * tick
                    next = desired > cur ? min(desired, cur + up) : max(desired, cur - down)
                }
                currentPct[i] = next
                if monitor.helperAvailable { _ = cb_ctl_set(Int32(i), Int32(pctToRpm(i, next))) }
            }
        }
        lastMode = cfg.mode
    }
}
