import SwiftUI

// Reusable mini time-series views, sharing the Canvas/Path idiom of CurveEditor.
// Two consumers: the top SoC/SSD/Fans cluster (single-series area/bars) and the
// expanded network panel (dual up/down history).

// How values map onto the vertical axis.
//
// Temperatures and percentages live in a bounded band, so they read best on a
// linear axis. Network rates span three or more orders of magnitude — idle
// chatter at a few KB/s next to a burst at tens of MB/s — and a linear axis
// scaled to the peak flattens everything else onto the baseline. `.log` maps the
// value logarithmically between `yRange.lowerBound` (the noise floor; must be
// > 0) and `yRange.upperBound`.
enum ChartScale { case linear, log }

// Longest gap between consecutive samples still drawn as a continuous line.
// A sampler that stops (display sleep, app suspension) would otherwise have its
// resume point joined straight back to the last pre-gap sample, drawing a slope
// that never happened.
private let maxGapSeconds: Double = 8

// Split samples into runs of contiguous readings, dropping anything older than x0.
private func segments(_ samples: [TimedSample], from x0: CFAbsoluteTime) -> [[TimedSample]] {
    var out: [[TimedSample]] = []
    var run: [TimedSample] = []
    for p in samples where p.t >= x0 {
        if let last = run.last, p.t - last.t > maxGapSeconds {
            if !run.isEmpty { out.append(run) }
            run = []
        }
        run.append(p)
    }
    if !run.isEmpty { out.append(run) }
    return out
}

// Maps a value onto [0,1] of the chart height for the given range and scale.
private func normalize(_ v: Double, _ range: ClosedRange<Double>, _ scale: ChartScale) -> Double {
    switch scale {
    case .linear:
        let span = max(0.0001, range.upperBound - range.lowerBound)
        return min(1, max(0, (v - range.lowerBound) / span))
    case .log:
        let lo = max(1, range.lowerBound)
        let hi = max(lo * 1.0001, range.upperBound)
        return min(1, max(0, (log10(max(v, lo)) - log10(lo)) / (log10(hi) - log10(lo))))
    }
}

// A single-series sparkline over a fixed time window and value range.
// x maps time into [now-window, now] so the chart fills in as history accrues;
// y maps `yRange` onto the full height. Draws either an area+line or bars.
struct Sparkline: View {
    var samples: [TimedSample]
    var windowSeconds: Double
    var now: CFAbsoluteTime
    var yRange: ClosedRange<Double>
    var kind: ChartKind
    var color: Color
    var scale: ChartScale = .linear
    var showBaseline: Bool = true

    var body: some View {
        Canvas { ctx, size in
            let W = size.width, H = size.height
            guard windowSeconds > 0, W > 1, H > 1 else { return }
            let x0 = now - windowSeconds
            func X(_ t: CFAbsoluteTime) -> CGFloat { CGFloat((t - x0) / windowSeconds) * W }
            func Y(_ v: Double) -> CGFloat { H - CGFloat(normalize(v, yRange, scale)) * H }

            if showBaseline {
                var base = Path(); base.move(to: CGPoint(x: 0, y: H - 0.5)); base.addLine(to: CGPoint(x: W, y: H - 0.5))
                ctx.stroke(base, with: .color(Theme.line.opacity(0.7)), lineWidth: 1)
            }

            let pts = samples.filter { $0.t >= x0 }
            guard !pts.isEmpty else { return }

            if kind == .bars {
                // Bucket into ~36 columns; draw the max in each bucket.
                let cols = max(8, min(48, Int(W / 5)))
                var buckets = [Double?](repeating: nil, count: cols)
                for p in pts {
                    let idx = min(cols - 1, max(0, Int((p.t - x0) / windowSeconds * Double(cols))))
                    buckets[idx] = max(buckets[idx] ?? 0, p.v)
                }
                let bw = W / CGFloat(cols)
                for (i, b) in buckets.enumerated() {
                    guard let v = b else { continue }
                    let x = CGFloat(i) * bw
                    let y = Y(v)
                    let rect = CGRect(x: x + bw * 0.15, y: y, width: bw * 0.7, height: max(1, H - y))
                    ctx.fill(Path(roundedRect: rect, cornerRadius: min(1.5, bw * 0.3)), with: .color(color))
                }
            } else {
                // One area+line per contiguous run, so sampling gaps stay gaps.
                for run in segments(pts, from: x0) {
                    var line = Path()
                    line.move(to: CGPoint(x: X(run[0].t), y: Y(run[0].v)))
                    for p in run.dropFirst() { line.addLine(to: CGPoint(x: X(p.t), y: Y(p.v))) }
                    var area = line
                    area.addLine(to: CGPoint(x: X(run.last!.t), y: H))
                    area.addLine(to: CGPoint(x: X(run[0].t), y: H))
                    area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(
                        Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: H)))
                    ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// Several series sharing one coordinate system: a single y-scale (`yRange`) and
// x-window, with each series drawn in its own fixed color so overlapping curves
// (e.g. SoC vs SSD, both temperatures) stay distinguishable. Faint gridlines make
// the shared scale legible. Used by the top cluster's combined line/bars chart.
struct MultiSparkline: View {
    struct Series: Identifiable { let id: Int; var samples: [TimedSample]; var color: Color }
    var series: [Series]
    var windowSeconds: Double
    var now: CFAbsoluteTime
    var yRange: ClosedRange<Double>
    var kind: ChartKind

    var body: some View {
        Canvas { ctx, size in
            let W = size.width, H = size.height
            guard windowSeconds > 0, W > 1, H > 1 else { return }
            let x0 = now - windowSeconds
            func X(_ t: CFAbsoluteTime) -> CGFloat { CGFloat((t - x0) / windowSeconds) * W }
            func Y(_ v: Double) -> CGFloat { H - CGFloat(normalize(v, yRange, .linear)) * H }

            // Shared-scale gridlines at 25/50/75% plus the baseline.
            for frac in [0.25, 0.5, 0.75] {
                var g = Path(); let y = H - CGFloat(frac) * H
                g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: W, y: y))
                ctx.stroke(g, with: .color(Theme.line.opacity(0.35)), lineWidth: 0.5)
            }
            var base = Path(); base.move(to: CGPoint(x: 0, y: H - 0.5)); base.addLine(to: CGPoint(x: W, y: H - 0.5))
            ctx.stroke(base, with: .color(Theme.line.opacity(0.7)), lineWidth: 1)

            if kind == .bars {
                // Grouped columns: within each time bucket, one thin bar per series.
                let cols = max(6, min(20, Int(W / 12)))
                let n = max(1, series.count)
                let bw = W / CGFloat(cols)
                let sub = bw * 0.72 / CGFloat(n)   // per-series bar width inside the group
                for (si, s) in series.enumerated() {
                    var buckets = [Double?](repeating: nil, count: cols)
                    for p in s.samples where p.t >= x0 {
                        let idx = min(cols - 1, max(0, Int((p.t - x0) / windowSeconds * Double(cols))))
                        buckets[idx] = max(buckets[idx] ?? 0, p.v)
                    }
                    for (i, b) in buckets.enumerated() {
                        guard let v = b else { continue }
                        let x = CGFloat(i) * bw + bw * 0.14 + CGFloat(si) * sub
                        let y = Y(v)
                        let rect = CGRect(x: x, y: y, width: max(1, sub * 0.85), height: max(1, H - y))
                        ctx.fill(Path(roundedRect: rect, cornerRadius: min(1.2, sub * 0.3)), with: .color(s.color))
                    }
                }
            } else {
                for s in series {
                    for run in segments(s.samples, from: x0) {
                        var line = Path()
                        line.move(to: CGPoint(x: X(run[0].t), y: Y(run[0].v)))
                        for p in run.dropFirst() { line.addLine(to: CGPoint(x: X(p.t), y: Y(p.v))) }
                        ctx.stroke(line, with: .color(s.color),
                                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
    }
}

// Labelled gridlines for a log-scaled rate chart, stepping ×8 from the noise
// floor: 8K, 64K, 512K, 4M, 32M, 256M, 2G. Powers of 1024 alone leave only one
// or two lines across a typical range; ×8 triples the density while keeping
// every label a round binary figure and short enough for an 84pt chart.
private struct LogRateGrid: View {
    var yRange: ClosedRange<Double>

    var body: some View {
        Canvas { ctx, size in
            let W = size.width, H = size.height
            guard W > 1, H > 1 else { return }
            var v = 8.0 * 1024
            while v <= yRange.upperBound {
                if v > yRange.lowerBound {
                    let y = H - CGFloat(normalize(v, yRange, .log)) * H
                    var g = Path(); g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: W, y: y))
                    ctx.stroke(g, with: .color(Theme.line.opacity(0.45)), lineWidth: 0.5)
                    let text = Text(axisRate(v)).font(.system(size: 8)).foregroundStyle(Theme.ink3)
                    ctx.draw(text, at: CGPoint(x: 3, y: y - 1), anchor: .bottomLeading)
                }
                v *= 8
            }
        }
    }
}

// The expanded network history: upload + download over a shared logarithmic
// y-scale, tinted by their current rate via Theme.speed (same thermal language
// as temperature).
//
// The axis is logarithmic because network rates routinely span three decades: a
// linear axis scaled to the window's peak leaves an hour of ordinary 200 KB/s
// traffic pinned flat to the baseline after one 50 MB/s burst.
struct DualSparkline: View {
    var up: [TimedSample]        // tx
    var down: [TimedSample]      // rx
    var windowSeconds: Double
    var now: CFAbsoluteTime
    var kind: ChartKind
    var height: CGFloat = 84

    private static let floorBps = 1024.0        // 1 KB/s — quieter than this reads as idle
    private static let minCeiling = 128.0 * 1024

    private var yRange: ClosedRange<Double> {
        let x0 = now - windowSeconds
        var peak = 0.0
        for s in up  where s.t >= x0 { peak = max(peak, s.v) }
        for s in down where s.t >= x0 { peak = max(peak, s.v) }
        return Self.floorBps...max(peak * 1.25, Self.minCeiling)
    }

    var body: some View {
        let range = yRange
        let upColor = Theme.speed(up.last?.v ?? 0)
        let downColor = Theme.speed(down.last?.v ?? 0)
        return VStack(spacing: 5) {
            ZStack {
                LogRateGrid(yRange: range)
                Sparkline(samples: down, windowSeconds: windowSeconds, now: now, yRange: range,
                          kind: kind, color: downColor, scale: .log, showBaseline: false)
                Sparkline(samples: up, windowSeconds: windowSeconds, now: now, yRange: range,
                          kind: kind, color: upColor, scale: .log, showBaseline: false)
            }
            .frame(height: height)
            .background(Theme.mode == .dark ? Color(hex: 0x0B0E13) : Color(hex: 0xEDF0F4))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))

            HStack(spacing: 14) {
                legend("arrow.up", up.last?.v ?? 0, upColor)
                legend("arrow.down", down.last?.v ?? 0, downColor)
                Spacer()
                // Scale hint: the axis is logarithmic, so name it as such.
                Text("log · \(humanRate(range.upperBound))")
                    .font(.system(size: 9)).foregroundStyle(Theme.ink3)
            }
        }
    }

    private func legend(_ icon: String, _ rate: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text(humanRate(rate)).font(Theme.telemetry(10)).foregroundStyle(color)
        }
    }
}
