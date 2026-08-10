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
        switch self { case .auto: return "自动"; case .manual: return "手动"; case .curve: return "曲线" }
    }
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
    var autoCheckUpdates: Bool = true
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
        case fahrenheit, appearance, autoCheckUpdates, mode, manualPct, curve, rampUpPctPerSec, rampDownPctPerSec, deadbandPct
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var cfg = OmniStatsConfig()
        cfg.fahrenheit        = try c.decodeIfPresent(Bool.self,          forKey: .fahrenheit)        ?? cfg.fahrenheit
        cfg.appearance        = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance)       ?? cfg.appearance
        cfg.autoCheckUpdates  = try c.decodeIfPresent(Bool.self,          forKey: .autoCheckUpdates)  ?? cfg.autoCheckUpdates
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
