import SwiftUI

// The signature element: an interactive temperature → fan-speed curve with a
// live "operating point" that rides the curve at (driving temp, commanded speed).
struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    var liveTemp: Double        // smoothed driving temperature (°C)
    var commandedPct: Double    // engine's current commanded percent
    var fahrenheit: Bool
    var height: CGFloat = 320

    let tMin = 30.0, tMax = 95.0
    private let padL: CGFloat = 38, padR: CGFloat = 18, padT: CGFloat = 20, padB: CGFloat = 26
    @State private var selected: UUID?

    private func pw(_ w: CGFloat) -> CGFloat { max(1, w - padL - padR) }
    private func ph(_ h: CGFloat) -> CGFloat { max(1, h - padT - padB) }
    private func px(_ t: Double, _ w: CGFloat) -> CGFloat { padL + CGFloat((t - tMin)/(tMax - tMin)) * pw(w) }
    private func py(_ p: Double, _ h: CGFloat) -> CGFloat { padT + CGFloat(1 - p/100) * ph(h) }
    private func toTemp(_ x: CGFloat, _ w: CGFloat) -> Double { min(tMax, max(tMin, tMin + Double((x - padL)/pw(w))*(tMax - tMin))) }
    private func toPct(_ y: CGFloat, _ h: CGFloat) -> Double { min(100, max(0, Double(1 - (y - padT)/ph(h))*100)) }
    private var sorted: [CurvePoint] { points.sorted { $0.temp < $1.temp } }

    private var tempGradient: LinearGradient {
        LinearGradient(colors: [Theme.temp(38), Theme.temp(58), Theme.temp(74), Theme.temp(90)],
                       startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    grid(w, h)
                    areaPath(w, h).fill(
                        LinearGradient(colors: [Theme.accent.opacity(0.14), Theme.accent.opacity(0.0)],
                                       startPoint: .top, endPoint: .bottom))
                    linePath(w, h).stroke(tempGradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    operatingPoint(w, h)
                    ForEach(points) { p in dot(p, w, h) }
                }
                .contentShape(Rectangle())
            }
            .frame(height: height)
            .background(Theme.mode == .dark ? Color(hex: 0x0B0E13) : Color(hex: 0xEDF0F4))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))

            controls
        }
    }

    private func grid(_ w: CGFloat, _ h: CGFloat) -> some View {
        Canvas { ctx, size in
            let W = size.width, H = size.height
            for p in [0.0, 25, 50, 75, 100] {
                let y = py(p, H)
                var line = Path(); line.move(to: CGPoint(x: padL, y: y)); line.addLine(to: CGPoint(x: W - padR, y: y))
                ctx.stroke(line, with: .color(Theme.line.opacity(p == 0 ? 0.9 : 0.45)), lineWidth: p == 0 ? 1 : 0.5)
                ctx.draw(Text("\(Int(p))%").font(.system(size: 8)).foregroundColor(Theme.ink3),
                         at: CGPoint(x: padL - 16, y: y))
            }
            for t in [40.0, 55, 70, 85] {
                let x = px(t, W)
                var line = Path(); line.move(to: CGPoint(x: x, y: padT)); line.addLine(to: CGPoint(x: x, y: H - padB))
                ctx.stroke(line, with: .color(Theme.line.opacity(0.35)), lineWidth: 0.5)
                let lbl = fahrenheit ? "\(Int(t*9/5+32))°" : "\(Int(t))°"
                ctx.draw(Text(lbl).font(.system(size: 8)).foregroundColor(Theme.ink3),
                         at: CGPoint(x: x, y: H - padB + 12))
            }
        }
    }
    private func linePath(_ w: CGFloat, _ h: CGFloat) -> Path {
        var path = Path(); let pts = sorted
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: px(first.temp, w), y: py(first.pct, h)))
        for p in pts.dropFirst() { path.addLine(to: CGPoint(x: px(p.temp, w), y: py(p.pct, h))) }
        return path
    }
    private func areaPath(_ w: CGFloat, _ h: CGFloat) -> Path {
        var path = linePath(w, h); let pts = sorted
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: px(last.temp, w), y: py(0, h)))
            path.addLine(to: CGPoint(x: px(first.temp, w), y: py(0, h)))
            path.closeSubpath()
        }
        return path
    }
    private func operatingPoint(_ w: CGFloat, _ h: CGFloat) -> some View {
        let t = min(tMax, max(tMin, liveTemp.isNaN ? tMin : liveTemp))
        let color = Theme.temp(liveTemp.isNaN ? 40 : liveTemp)
        return ZStack {
            Circle().fill(color.opacity(0.22)).frame(width: 26, height: 26)
            Circle().fill(color).frame(width: 11, height: 11)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
        }
        .position(x: px(t, w), y: py(commandedPct, h))
        .shadow(color: color.opacity(0.6), radius: 6)
        .animation(.easeOut(duration: 0.5), value: commandedPct)
        .allowsHitTesting(false)
    }
    private func dot(_ p: CurvePoint, _ w: CGFloat, _ h: CGFloat) -> some View {
        let isSel = selected == p.id
        return Circle()
            .fill(Theme.card)
            .overlay(Circle().stroke(isSel ? Theme.accent : Theme.ink2, lineWidth: isSel ? 2.5 : 1.5))
            .frame(width: 15, height: 15)
            .position(x: px(p.temp, w), y: py(p.pct, h))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    selected = p.id
                    guard let idx = points.firstIndex(where: { $0.id == p.id }) else { return }
                    var t = toTemp(g.location.x, w)
                    let pc = toPct(g.location.y, h)
                    let lower = points.filter { $0.id != p.id && $0.temp < points[idx].temp }.map { $0.temp }.max()
                    let higher = points.filter { $0.id != p.id && $0.temp > points[idx].temp }.map { $0.temp }.min()
                    if let l = lower { t = max(t, l + 1) }
                    if let hi = higher { t = min(t, hi - 1) }
                    points[idx].temp = t; points[idx].pct = pc
                })
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { addPoint() } label: { Label(L.t("c.addPoint"), systemImage: "plus") }
            Button { removeSelected() } label: { Label(L.t("c.removePoint"), systemImage: "minus") }
                .disabled(selected == nil || points.count <= 2)
            Spacer()
            Button { points = OmniStatsConfig.defaultCurve; selected = nil } label: { Label(L.t("c.reset"), systemImage: "arrow.counterclockwise") }
        }
        .buttonStyle(.bordered).controlSize(.small).font(.system(size: 11)).tint(Theme.accent)
    }
    private func addPoint() {
        let pts = sorted; var gap = 0.0, at = 62.0
        for i in 0..<max(0, pts.count-1) where pts[i+1].temp - pts[i].temp > gap {
            gap = pts[i+1].temp - pts[i].temp; at = (pts[i].temp + pts[i+1].temp)/2
        }
        var cfg = OmniStatsConfig(); cfg.curve = points
        let np = CurvePoint(temp: at, pct: cfg.curvePct(at: at))
        points.append(np); selected = np.id
    }
    private func removeSelected() {
        guard let id = selected, points.count > 2 else { return }
        points.removeAll { $0.id == id }; selected = nil
    }
}
