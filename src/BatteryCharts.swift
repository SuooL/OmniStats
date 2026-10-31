import SwiftUI

// Battery history charts: small multiples on one shared time axis, 2 pt lines,
// a hairline grid, and one crosshair that reads every chart at the same moment.
// Gaps in the data (sleep, the app not running) stay empty; nothing is drawn
// that wasn't measured. Redraws happen on new data or pointer movement only.

enum HistoryRange: String, CaseIterable, Identifiable {
    case hours2, hours24, days7, days30
    var id: String { rawValue }
    var title: String { L.t("hist.range.\(rawValue)") }
    var seconds: TimeInterval {
        switch self { case .hours2: return 7200; case .hours24: return 86400; case .days7: return 604_800; case .days30: return 2_592_000 }
    }
    // One point per minute, 5 minutes, 30 minutes and 2 hours.
    var maxPoints: Int {
        switch self { case .hours2: return 120; case .hours24: return 288; case .days7: return 336; case .days30: return 360 }
    }
    var tickStep: TimeInterval {
        switch self { case .hours2: return 1800; case .hours24: return 4 * 3600; case .days7: return 86400; case .days30: return 5 * 86400 }
    }
    var spansDays: Bool { self == .days7 || self == .days30 }
}

enum AxisTicks {
    // Round tick values (1, 2 or 5 × 10ⁿ apart, so labels never round unevenly) covering [low, high].
    static func ticks(_ low: Double, _ high: Double, count: Int = 4) -> [Double] {
        guard low.isFinite, high.isFinite, count > 1 else { return [] }
        var low = low, high = high
        if high - low < 1e-9 { low -= 1; high += 1 }
        let raw = (high - low) / Double(count - 1)
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? 10 * magnitude
        let first = floor(low / step) * step, last = ceil(high / step) * step
        // Counted, not accumulated, so no floating drift creeps into the labels.
        return (0...Int(((last - first) / step).rounded())).map { i in
            let value = ((first + Double(i) * step) / step).rounded() * step
            return abs(value) < step / 1e6 ? 0 : value
        }
    }

    // Tick positions aligned to the local clock: every `step` from midnight.
    static func timeTicks(from: Date, to: Date, step: TimeInterval, calendar: Calendar = .current) -> [Date] {
        guard step > 0, to > from else { return [] }
        let midnight = calendar.startOfDay(for: from)
        var t: Date
        if step >= 86400 {
            // Every day, or days 1, 6, 11 … 26 of each month for five-day steps,
            // so labels keep their place across month boundaries.
            let days = max(1, Int(step / 86400))
            t = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: from) ?? from)
            var result: [Date] = []
            while t <= to {
                let day = calendar.component(.day, from: t)
                if days == 1 || ((day - 1) % days == 0 && day + days <= 31) { result.append(t) }
                t = calendar.date(byAdding: .day, value: 1, to: t) ?? to.addingTimeInterval(1)
            }
            return result
        }
        let offset = from.timeIntervalSince(midnight)
        t = midnight.addingTimeInterval((offset / step).rounded(.up) * step)
        var result: [Date] = []
        while t <= to { result.append(t); t = t.addingTimeInterval(step) }
        return result
    }
}

struct ChartSeries: Identifiable {
    let id: String
    let name: String
    let color: Color
    let runs: [[BatteryHistoryBucket]]

    var latest: BatteryHistoryBucket? { runs.last?.last }
    // The bucket at `time`, if a sample covers it (within half a slot).
    func value(at time: Date, slot: TimeInterval) -> Double? {
        for run in runs {
            guard let first = run.first, let last = run.last,
                  time.timeIntervalSince(first.start) >= -slot / 2, time.timeIntervalSince(last.end) <= slot / 2 else { continue }
            return run.min { abs(mid($0).timeIntervalSince(time)) < abs(mid($1).timeIntervalSince(time)) }?.mean
        }
        return nil
    }
}

func mid(_ bucket: BatteryHistoryBucket) -> Date {
    Date(timeIntervalSince1970: (bucket.start.timeIntervalSince1970 + bucket.end.timeIntervalSince1970) / 2)
}

// A threshold drawn across the plot (the charge limit, the heat limit), labelled.
struct ChartReference {
    let value: Double
    let label: String
    let color: Color
}

struct TimeSeriesChart: View {
    let series: [ChartSeries]
    let from: Date, to: Date
    let domain: ClosedRange<Double>
    let ticks: [Double]
    var timeTicks: [Date] = []
    var references: [ChartReference] = []
    var area = false              // a light wash under a single series
    var zeroLine = false
    var compact = false           // the panel's sparkline: no axes, no hover
    var slot: TimeInterval = 60   // seconds per point, for matching the pointer to a sample
    let format: (Double) -> String
    var timeFormat: (Date) -> String = { _ in "" }
    var hoverFormat: (Date) -> String = { _ in "" }
    @Binding var hover: Date?

    private let axisWidth: CGFloat = 40
    private let timeBand: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let plot = plotRect(geometry.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(&context, plot) }
                if !compact, let hover, hover >= from, hover <= to { tooltip(at: hover, plot: plot, size: geometry.size) }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard !compact else { return }
                switch phase {
                case .active(let point) where plot.contains(CGPoint(x: point.x, y: plot.midY)):
                    let fraction = (point.x - plot.minX) / max(1, plot.width)
                    hover = from.addingTimeInterval(Double(fraction) * to.timeIntervalSince(from))
                default:
                    hover = nil
                }
            }
        }
    }

    private func plotRect(_ size: CGSize) -> CGRect {
        compact ? CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: 1.5)
                : CGRect(x: axisWidth, y: 6, width: max(1, size.width - axisWidth - 4), height: max(1, size.height - 6 - timeBand))
    }
    private func x(_ date: Date, _ plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(date.timeIntervalSince(from) / max(1, to.timeIntervalSince(from))) * plot.width
    }
    private func y(_ value: Double, _ plot: CGRect) -> CGFloat {
        let span = max(1e-9, domain.upperBound - domain.lowerBound)
        let f = (min(domain.upperBound, max(domain.lowerBound, value)) - domain.lowerBound) / span
        return plot.maxY - CGFloat(f) * plot.height
    }

    private func draw(_ context: inout GraphicsContext, _ plot: CGRect) {
        let hairline = StrokeStyle(lineWidth: 1)
        if !compact {
            for tick in ticks {
                var grid = Path(); grid.move(to: CGPoint(x: plot.minX, y: y(tick, plot))); grid.addLine(to: CGPoint(x: plot.maxX, y: y(tick, plot)))
                context.stroke(grid, with: .color(Theme.line.opacity(zeroLine && tick == 0 ? 1 : 0.7)), style: hairline)
                context.draw(Text(format(tick)).font(Theme.Typo.micro.monospacedDigit()).foregroundColor(Theme.ink3),
                             at: CGPoint(x: plot.minX - 6, y: y(tick, plot)), anchor: .trailing)
            }
            for tick in timeTicks where tick >= from && tick <= to {
                context.draw(Text(timeFormat(tick)).font(Theme.Typo.micro.monospacedDigit()).foregroundColor(Theme.ink3),
                             at: CGPoint(x: x(tick, plot), y: plot.maxY + 4), anchor: .top)
            }
            for reference in references where domain.contains(reference.value) {
                var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y(reference.value, plot)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(reference.value, plot)))
                // A real threshold, so dashed (unlike the grid), and named.
                context.stroke(line, with: .color(reference.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                context.draw(Text(reference.label).font(Theme.Typo.micro).foregroundColor(Theme.ink2),
                             at: CGPoint(x: plot.maxX - 2, y: y(reference.value, plot) - 2), anchor: .bottomTrailing)
            }
        }
        for item in series {
            for run in item.runs {
                let points = run.map { CGPoint(x: x(mid($0), plot), y: y($0.mean, plot)) }
                guard let first = points.first else { continue }
                // Peaks survive downsampling as a faint band from each slot's low to high.
                if run.contains(where: { $0.high - $0.low > 1e-9 }) {
                    var band = Path()
                    band.move(to: CGPoint(x: first.x, y: y(run[0].high, plot)))
                    for (bucket, point) in zip(run, points).dropFirst() { band.addLine(to: CGPoint(x: point.x, y: y(bucket.high, plot))) }
                    for (bucket, point) in zip(run, points).reversed() { band.addLine(to: CGPoint(x: point.x, y: y(bucket.low, plot))) }
                    band.closeSubpath()
                    context.fill(band, with: .color(item.color.opacity(0.14)))
                }
                if points.count == 1 {
                    context.fill(Path(ellipseIn: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)), with: .color(item.color))
                    continue
                }
                var line = Path(); line.addLines(points)
                if area {
                    var wash = line
                    wash.addLine(to: CGPoint(x: points[points.count - 1].x, y: plot.maxY))
                    wash.addLine(to: CGPoint(x: first.x, y: plot.maxY)); wash.closeSubpath()
                    context.fill(wash, with: .color(item.color.opacity(0.10)))
                }
                context.stroke(line, with: .color(item.color), style: StrokeStyle(lineWidth: compact ? 1.5 : 2, lineCap: .round, lineJoin: .round))
            }
        }
        if !compact, let hover, hover >= from, hover <= to {
            var crosshair = Path(); crosshair.move(to: CGPoint(x: x(hover, plot), y: plot.minY))
            crosshair.addLine(to: CGPoint(x: x(hover, plot), y: plot.maxY))
            context.stroke(crosshair, with: .color(Theme.ink3), style: hairline)
            for item in series {
                guard let value = item.value(at: hover, slot: slot) else { continue }
                let center = CGPoint(x: x(hover, plot), y: y(value, plot))
                // An end dot with a surface ring, so it reads where it crosses the line.
                context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(Theme.card))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)), with: .color(item.color))
            }
        }
    }

    // Values lead, names follow; a short line keys each series.
    private func tooltip(at time: Date, plot: CGRect, size: CGSize) -> some View {
        let rows = series.map { ($0, $0.value(at: time, slot: slot)) }
        let width: CGFloat = 132
        let px = x(time, plot)
        let left = px + 10 + width > size.width ? px - 10 - width : px + 10
        return VStack(alignment: .leading, spacing: 3) {
            Text(hoverFormat(time)).font(Theme.Typo.micro.monospacedDigit()).foregroundStyle(Theme.ink3)
            ForEach(rows, id: \.0.id) { item, value in
                HStack(spacing: 5) {
                    Capsule().fill(item.color).frame(width: 10, height: 2.5)
                    Text(value.map(format) ?? "—").font(Theme.telemetry(11)).foregroundStyle(Theme.ink)
                    if series.count > 1 { Text(item.name).font(Theme.Typo.micro).foregroundStyle(Theme.ink3).lineLimit(1) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: width, alignment: .leading)
        .background(Theme.card.opacity(0.96), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .offset(x: left, y: plot.minY)
        .allowsHitTesting(false)
    }
}

// Charging, plugged in without charging, or on battery, under the charge chart.
struct StateStrip: View {
    let segments: [BatteryStateSegment]
    let from: Date, to: Date
    let leading: CGFloat

    static func color(_ state: BatteryPowerState) -> Color {
        switch state {
        case .charging: return ChartPalette.aqua
        case .pluggedIdle: return Theme.ink3.opacity(0.45)
        case .onBattery: return ChartPalette.orange
        }
    }

    var body: some View {
        Canvas { context, size in
            let width = size.width - leading - 4
            let span = max(1, to.timeIntervalSince(from))
            for segment in segments {
                let x0 = leading + CGFloat(segment.start.timeIntervalSince(from) / span) * width
                let x1 = leading + CGFloat(segment.end.timeIntervalSince(from) / span) * width
                // A one-point surface gap keeps neighbouring segments apart.
                let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0 - 1), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Self.color(segment.state)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

// Categorical slots validated (dataviz validator, all pairs) on Theme.card in both
// modes: CVD ΔE ≥ 9.2, normal vision ≥ 20.6, contrast ≥ 3:1.
enum ChartPalette {
    static var blue: Color { Theme.pick(0x3987E5, 0x2A78D6) }
    static var orange: Color { Color(hex: 0xD95926) }
    static var aqua: Color { Color(hex: 0x199E70) }
}
