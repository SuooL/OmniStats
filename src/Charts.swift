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

// One top-cluster widget: a ring gauge, or a titled time-series card. Keeps a
// consistent ~68pt-tall footprint whichever style is active.
struct MetricWidget: View {
    var style: TopWidgetStyle
    var title: String
    var label: String            // current-value text (e.g. "48°C", "62%")
    var color: Color
    // ring
    var ringValue: Double        // 0…1
    // chart
    var samples: [TimedSample]
    var windowSeconds: Double
    var now: CFAbsoluteTime
    var yRange: ClosedRange<Double>

    var body: some View {
        if style == .ring {
            Ring(value: ringValue, title: title, label: label, color: color)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
                    Spacer()
                    Text(label).font(Theme.telemetry(11, .bold)).foregroundStyle(color)
                }
                Sparkline(samples: samples, windowSeconds: windowSeconds, now: now,
                          yRange: yRange, kind: style == .bars ? .bars : .line, color: color)
                    .frame(height: 40)
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
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
