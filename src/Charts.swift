import SwiftUI

// Reusable mini time-series views, sharing the Canvas/Path idiom of CurveEditor.
// Two consumers: the top SoC/SSD/Fans cluster (single-series area/bars) and the
// expanded network panel (dual up/down history).

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

    var body: some View {
        Canvas { ctx, size in
            let W = size.width, H = size.height
            guard windowSeconds > 0, W > 1, H > 1 else { return }
            let span = max(0.0001, yRange.upperBound - yRange.lowerBound)
            let x0 = now - windowSeconds
            func X(_ t: CFAbsoluteTime) -> CGFloat { CGFloat((t - x0) / windowSeconds) * W }
            func Y(_ v: Double) -> CGFloat {
                let f = min(1, max(0, (v - yRange.lowerBound) / span))
                return H - CGFloat(f) * H
            }

            // baseline
            var base = Path(); base.move(to: CGPoint(x: 0, y: H - 0.5)); base.addLine(to: CGPoint(x: W, y: H - 0.5))
            ctx.stroke(base, with: .color(Theme.line.opacity(0.7)), lineWidth: 1)

            let pts = samples.filter { $0.t >= x0 }
            guard pts.count >= 1 else { return }

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
                var line = Path()
                line.move(to: CGPoint(x: X(pts[0].t), y: Y(pts[0].v)))
                for p in pts.dropFirst() { line.addLine(to: CGPoint(x: X(p.t), y: Y(p.v))) }
                var area = line
                area.addLine(to: CGPoint(x: X(pts.last!.t), y: H))
                area.addLine(to: CGPoint(x: X(pts[0].t), y: H))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: H)))
                ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
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
            let span = max(0.0001, yRange.upperBound - yRange.lowerBound)
            let x0 = now - windowSeconds
            func X(_ t: CFAbsoluteTime) -> CGFloat { CGFloat((t - x0) / windowSeconds) * W }
            func Y(_ v: Double) -> CGFloat {
                let f = min(1, max(0, (v - yRange.lowerBound) / span))
                return H - CGFloat(f) * H
            }

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
                    let pts = s.samples.filter { $0.t >= x0 }
                    guard pts.count >= 1 else { continue }
                    var line = Path()
                    line.move(to: CGPoint(x: X(pts[0].t), y: Y(pts[0].v)))
                    for p in pts.dropFirst() { line.addLine(to: CGPoint(x: X(p.t), y: Y(p.v))) }
                    ctx.stroke(line, with: .color(s.color),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// The expanded network history: upload + download over the same y-scale, tinted
// by their current rate via Theme.speed (same thermal language as temperature).
struct DualSparkline: View {
    var up: [TimedSample]        // tx
    var down: [TimedSample]      // rx
    var windowSeconds: Double
    var now: CFAbsoluteTime
    var kind: ChartKind
    var height: CGFloat = 84

    private var yMax: Double {
        let x0 = now - windowSeconds
        let peak = (up + down).filter { $0.t >= x0 }.map(\.v).max() ?? 0
        return max(peak * 1.15, 8 * 1024)   // floor at 8 KB/s so idle isn't all-flat noise
    }

    var body: some View {
        let range = 0...yMax
        let upColor = Theme.speed(up.last?.v ?? 0)
        let downColor = Theme.speed(down.last?.v ?? 0)
        return VStack(spacing: 5) {
            ZStack {
                Sparkline(samples: down, windowSeconds: windowSeconds, now: now, yRange: range, kind: kind, color: downColor)
                Sparkline(samples: up, windowSeconds: windowSeconds, now: now, yRange: range, kind: kind, color: upColor)
            }
            .frame(height: height)
            .background(Theme.mode == .dark ? Color(hex: 0x0B0E13) : Color(hex: 0xEDF0F4))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))

            HStack(spacing: 14) {
                legend("arrow.up", up.last?.v ?? 0, upColor)
                legend("arrow.down", down.last?.v ?? 0, downColor)
                Spacer()
                Text(humanRate(yMax)).font(.system(size: 9)).foregroundStyle(Theme.ink3)   // scale hint
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
