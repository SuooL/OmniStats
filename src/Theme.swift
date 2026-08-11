import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case dark, light
    var id: String { rawValue }
    var title: String { self == .dark ? L.t("appearance.dark") : L.t("appearance.light") }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

// MARK: - Accent presets
// A curated set of accent colors (dark/light pair each). Drives ring gauges,
// progress bars, curve highlights, buttons — anywhere `Theme.accent` is read.
enum AccentPreset: String, Codable, CaseIterable, Identifiable {
    case teal, graphite, aurora, sunset, indigo
    var id: String { rawValue }
    var title: String { L.t("accent.\(rawValue)") }

    // (dark, light) hex pairs.
    private var hex: (UInt32, UInt32) {
        switch self {
        case .teal:     return (0x37C2C4, 0x0B8E92)
        case .graphite: return (0x9AA7B4, 0x55606C)
        case .aurora:   return (0x53D08A, 0x1E9E63)
        case .sunset:   return (0xF2884A, 0xD1642A)
        case .indigo:   return (0x7C8CF8, 0x4B5BD6)
        }
    }
    func color(_ mode: AppearanceMode) -> Color { Color(hex: mode == .dark ? hex.0 : hex.1) }
    /// Swatch color for the picker (dark variant reads well on both chrome).
    var swatch: Color { Color(hex: hex.0) }
}

// How the menu-bar numbers (temperature / network) are tinted.
enum MenuNumberColorMode: String, Codable, CaseIterable, Identifiable {
    case tempGradient, accent, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tempGradient: return L.t("g.numColor.temp")
        case .accent:       return L.t("g.numColor.accent")
        case .mono:         return L.t("g.numColor.mono")
        }
    }
}

// Design tokens — a "thermal instrument" palette with dark & light variants.
// `Theme.mode` is set at the top of each root view's body so every token read
// during that render reflects the current theme.
enum Theme {
    static var mode: AppearanceMode = .dark
    static var accentPreset: AccentPreset = .teal   // set alongside `mode` at each root body

    private static func pick(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(hex: mode == .dark ? dark : light)
    }
    static var bg:      Color { pick(0x0E1116, 0xD6DCE3) }   // window / sidebar
    static var surface: Color { pick(0x171B22, 0xE4E8ED) }   // content area
    static var card:    Color { pick(0x1E242D, 0xF1F4F7) }
    static var line:    Color { pick(0x2A313B, 0xC7CFD8) }
    static var ink:     Color { pick(0xE6EAF0, 0x1A222C) }
    static var ink2:    Color { pick(0x9BA6B4, 0x52606E) }
    static var ink3:    Color { pick(0x5E6975, 0x82909E) }
    static var accent:  Color { accentPreset.color(mode) }

    static var cardShadow: Color { Color.black.opacity(mode == .dark ? 0.22 : 0.07) }

    private static let darkStops: [(Double, (Double, Double, Double))] = [
        (35, (63/255.0, 185/255.0, 80/255.0)),
        (60, (227/255.0, 179/255.0, 65/255.0)),
        (75, (240/255.0, 136/255.0, 62/255.0)),
        (90, (248/255.0, 81/255.0, 73/255.0)),
    ]
    private static let lightStops: [(Double, (Double, Double, Double))] = [
        (35, (46/255.0, 158/255.0, 67/255.0)),
        (60, (199/255.0, 146/255.0, 18/255.0)),
        (75, (219/255.0, 108/255.0, 39/255.0)),
        (90, (217/255.0, 48/255.0, 58/255.0)),
    ]
    private static var stops: [(Double, (Double, Double, Double))] { mode == .dark ? darkStops : lightStops }
    static func temp(_ c: Double) -> Color {
        if c.isNaN { return ink3 }
        let s = stops
        if c <= s.first!.0 { let r = s.first!.1; return Color(red: r.0, green: r.1, blue: r.2) }
        if c >= s.last!.0  { let r = s.last!.1;  return Color(red: r.0, green: r.1, blue: r.2) }
        for i in 0..<s.count-1 {
            let (t0, c0) = s[i], (t1, c1) = s[i+1]
            if c >= t0 && c <= t1 {
                let f = (c - t0) / (t1 - t0)
                return Color(red: c0.0 + (c1.0-c0.0)*f, green: c0.1 + (c1.1-c0.1)*f, blue: c0.2 + (c1.2-c0.2)*f)
            }
        }
        return accent
    }

    static func telemetry(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    static func label(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
