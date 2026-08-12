import Foundation

// MARK: - Formatting
func fmtTemp(_ c: Float, fahrenheit: Bool) -> String {
    if c.isNaN { return "—" }
    return fahrenheit ? String(format: "%.0f°F", c * 9/5 + 32) : String(format: "%.0f°C", c)
}

enum FanMode: String, Codable, CaseIterable, Identifiable {
    case auto, manual, curve
    var id: String { rawValue }
    var title: String {
        switch self { case .auto: return L.t("fanmode.auto"); case .manual: return L.t("fanmode.manual"); case .curve: return L.t("fanmode.curve") }
    }
}

// Averaging window for the top-CPU process list. Instantaneous sampling flaps
// tick-to-tick; a rolling window makes the readout represent sustained load.
enum CPUWindow: String, Codable, CaseIterable, Identifiable {
    case realtime, tenMin, thirtyMin
    var id: String { rawValue }
    var seconds: Double {
        switch self { case .realtime: return 0; case .tenMin: return 600; case .thirtyMin: return 1800 }
    }
    var title: String {
        switch self {
        case .realtime:  return L.t("cpuwin.realtime")
        case .tenMin:    return L.t("cpuwin.10m")
        case .thirtyMin: return L.t("cpuwin.30m")
        }
    }
}

// How the top SoC/SSD/Fans cluster is drawn: instantaneous ring gauge, or a
// rolling time-series (area line / bars) over `topWidgetWindow`.
enum TopWidgetStyle: String, Codable, CaseIterable, Identifiable {
    case ring, line, bars
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ring: return L.t("chart.style.ring")
        case .line: return L.t("chart.style.line")
        case .bars: return L.t("chart.style.bars")
        }
    }
    var isChart: Bool { self != .ring }
}

// How far back the top-widget time-series charts look.
enum ChartWindow: String, Codable, CaseIterable, Identifiable {
    case fiveMin, thirtyMin, oneHour
    var id: String { rawValue }
    var seconds: Double {
        switch self { case .fiveMin: return 300; case .thirtyMin: return 1800; case .oneHour: return 3600 }
    }
    var title: String {
        switch self {
        case .fiveMin:   return L.t("chart.win.5m")
        case .thirtyMin: return L.t("chart.win.30m")
        case .oneHour:   return L.t("chart.win.1h")
        }
    }
}

// Line (area) vs bars — used by the expanded network history chart.
enum ChartKind: String, Codable, CaseIterable, Identifiable {
    case line, bars
    var id: String { rawValue }
    var title: String { self == .line ? L.t("chart.style.line") : L.t("chart.style.bars") }
}

// A point on the temperature→speed curve. Y is a fan-agnostic percent (0–100)
// mapped per fan onto [min,max] rpm.
struct CurvePoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var temp: Double     // °C
    var pct: Double      // 0–100
}

// MARK: - Persisted configuration
struct OmniStatsConfig: Codable, Equatable {
    var fahrenheit: Bool = false
    var appearance: AppearanceMode = .dark
    var language: AppLanguage = .system
    var accent: AccentPreset = .teal
    var menuNumberColor: MenuNumberColorMode = .tempGradient
    var showTempInMenuBar: Bool = true
    var showNetworkInMenuBar: Bool = true
    var showNetworkPanel: Bool = true
    var showProcesses: Bool = true
    var cpuWindow: CPUWindow = .tenMin   // averaging window for the top-CPU list
    var topWidgetStyle: TopWidgetStyle = .ring     // SoC/SSD/Fans cluster: ring gauge vs time-series
    var topWidgetWindow: ChartWindow = .fiveMin    // history span for the top-widget charts
    var netChartKind: ChartKind = .line            // expanded network 1h chart: line vs bars
    var autoCheckUpdates: Bool = true
    var autoDownloadUpdates: Bool = true   // auto-download in background, then prompt to install
    var mode: FanMode = .auto
    var manualPct: Double = 40           // manual mode target (percent)
    var curve: [CurvePoint] = defaultCurve
    var rampUpPctPerSec: Double = 12     // slew limit rising  (percent/sec)
    var rampDownPctPerSec: Double = 6    // slew limit falling (percent/sec)
    var deadbandPct: Double = 2          // hysteresis

    static let defaultCurve: [CurvePoint] = [
        CurvePoint(temp: 40, pct: 0),
        CurvePoint(temp: 55, pct: 20),
        CurvePoint(temp: 70, pct: 55),
        CurvePoint(temp: 85, pct: 100),
    ]

    // One-click presets.
    static let presetQuiet: [CurvePoint] = [   // 静音:尽量安静,晚升速
        CurvePoint(temp: 48, pct: 0),
        CurvePoint(temp: 66, pct: 12),
        CurvePoint(temp: 80, pct: 45),
        CurvePoint(temp: 92, pct: 85),
    ]
    static let presetBalanced: [CurvePoint] = defaultCurve   // 均衡
    static let presetCool: [CurvePoint] = [    // 高性能:早升速,压温度
        CurvePoint(temp: 38, pct: 18),
        CurvePoint(temp: 52, pct: 45),
        CurvePoint(temp: 66, pct: 75),
        CurvePoint(temp: 78, pct: 100),
    ]

    /// Linear interpolation of the curve at a temperature, clamped to the endpoints.
    func curvePct(at tempC: Double) -> Double {
        let pts = curve.sorted { $0.temp < $1.temp }
        guard let first = pts.first, let last = pts.last else { return 0 }
        if tempC <= first.temp { return first.pct }
        if tempC >= last.temp { return last.pct }
        for i in 0..<pts.count-1 {
            let a = pts[i], b = pts[i+1]
            if tempC >= a.temp && tempC <= b.temp {
                let f = (tempC - a.temp) / (b.temp - a.temp)
                return a.pct + (b.pct - a.pct) * f
            }
        }
        return last.pct
    }
}

// Tolerant decoding: missing keys (older saved configs / future additions) fall
// back to defaults instead of failing the whole load.
extension OmniStatsConfig {
    enum CodingKeys: String, CodingKey {
        case fahrenheit, appearance, language, accent, menuNumberColor,
             showTempInMenuBar, showNetworkInMenuBar, showNetworkPanel, showProcesses, cpuWindow,
             topWidgetStyle, topWidgetWindow, netChartKind,
             autoCheckUpdates, autoDownloadUpdates, mode, manualPct, curve, rampUpPctPerSec, rampDownPctPerSec, deadbandPct
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var cfg = OmniStatsConfig()
        cfg.fahrenheit        = try c.decodeIfPresent(Bool.self,          forKey: .fahrenheit)        ?? cfg.fahrenheit
        cfg.appearance        = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance)       ?? cfg.appearance
        cfg.language          = try c.decodeIfPresent(AppLanguage.self,   forKey: .language)          ?? cfg.language
        cfg.accent            = try c.decodeIfPresent(AccentPreset.self,  forKey: .accent)            ?? cfg.accent
        cfg.menuNumberColor   = try c.decodeIfPresent(MenuNumberColorMode.self, forKey: .menuNumberColor) ?? cfg.menuNumberColor
        cfg.showTempInMenuBar    = try c.decodeIfPresent(Bool.self, forKey: .showTempInMenuBar)    ?? cfg.showTempInMenuBar
        cfg.showNetworkInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showNetworkInMenuBar) ?? cfg.showNetworkInMenuBar
        cfg.showNetworkPanel     = try c.decodeIfPresent(Bool.self, forKey: .showNetworkPanel)     ?? cfg.showNetworkPanel
        cfg.showProcesses        = try c.decodeIfPresent(Bool.self, forKey: .showProcesses)        ?? cfg.showProcesses
        cfg.cpuWindow            = try c.decodeIfPresent(CPUWindow.self, forKey: .cpuWindow)         ?? cfg.cpuWindow
        cfg.topWidgetStyle       = try c.decodeIfPresent(TopWidgetStyle.self, forKey: .topWidgetStyle) ?? cfg.topWidgetStyle
        cfg.topWidgetWindow      = try c.decodeIfPresent(ChartWindow.self, forKey: .topWidgetWindow) ?? cfg.topWidgetWindow
        cfg.netChartKind         = try c.decodeIfPresent(ChartKind.self,  forKey: .netChartKind)     ?? cfg.netChartKind
        cfg.autoCheckUpdates  = try c.decodeIfPresent(Bool.self,          forKey: .autoCheckUpdates)  ?? cfg.autoCheckUpdates
        cfg.autoDownloadUpdates = try c.decodeIfPresent(Bool.self,        forKey: .autoDownloadUpdates) ?? cfg.autoDownloadUpdates
        cfg.mode              = try c.decodeIfPresent(FanMode.self,        forKey: .mode)              ?? cfg.mode
        cfg.manualPct         = try c.decodeIfPresent(Double.self,        forKey: .manualPct)         ?? cfg.manualPct
        cfg.curve             = try c.decodeIfPresent([CurvePoint].self,  forKey: .curve)             ?? cfg.curve
        cfg.rampUpPctPerSec   = try c.decodeIfPresent(Double.self,        forKey: .rampUpPctPerSec)   ?? cfg.rampUpPctPerSec
        cfg.rampDownPctPerSec = try c.decodeIfPresent(Double.self,        forKey: .rampDownPctPerSec) ?? cfg.rampDownPctPerSec
        cfg.deadbandPct       = try c.decodeIfPresent(Double.self,        forKey: .deadbandPct)       ?? cfg.deadbandPct
        self = cfg
    }
}

// MARK: - Config store (ObservableObject, auto-persists)
final class ConfigStore: ObservableObject {
    @Published var config: OmniStatsConfig { didSet { save() } }
    private let key = "OmniStatsConfig.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let c = try? JSONDecoder().decode(OmniStatsConfig.self, from: data) {
            config = c
        } else {
            config = OmniStatsConfig()
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
