import SwiftUI
import Combine

// The Battery page's readings: status and figures, the history charts, health
// and today's totals. Controls (limit, discharge, schedules) live in BatteryView.

func watts(_ value: Double) -> String { String(format: "%.1f W", value) }
func signedWatts(_ value: Double) -> String { abs(value) < 0.05 ? "0.0 W" : String(format: "%+.1f W", value) }
func signedAmps(_ value: Double) -> String { abs(value) < 0.005 ? "0.00 A" : String(format: "%+.2f A", value) }
private func duration(_ seconds: TimeInterval) -> String { formatBatteryMinutes(max(0, Int((seconds / 60).rounded()))) }

// What the history cards draw, recomputed only when the range, the unit or the
// data change; hovering just redraws.
final class BatteryHistoryModel: ObservableObject {
    struct Charts {
        var from = Date(), to = Date()
        var level: [[BatteryHistoryBucket]] = []
        var current: [[BatteryHistoryBucket]] = []
        var load: [[BatteryHistoryBucket]] = []
        var battery: [[BatteryHistoryBucket]] = []
        var temperature: [[BatteryHistoryBucket]] = []
        var states: [BatteryStateSegment] = []
        var samples: Int { level.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } } }
    }
    @Published private(set) var charts = Charts()
    @Published private(set) var snapshots: [BatteryHealthSnapshot] = []
    @Published private(set) var today = BatteryDayStats()
    private var source: BatteryHistory?
    private var settings: (range: HistoryRange, limit: Int, fahrenheit: Bool)?
    private var newSamples: AnyCancellable?

    // Called by the page when what it shows changes. The model follows new
    // samples itself: one subscription, held here, so view updates can never
    // re-subscribe (a publisher created in `body` would, and replay its value).
    func show(_ history: BatteryHistory, range: HistoryRange, limit: Int, fahrenheit: Bool) {
        if source !== history {
            source = history
            newSamples = history.$latest.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
        }
        guard settings.map({ $0.range != range || $0.limit != limit || $0.fahrenheit != fahrenheit }) ?? true else { return }
        settings = (range, limit, fahrenheit)
        refresh()
    }

    private func refresh() {
        guard let source, let settings else { return }
        reload(source, range: settings.range, limit: settings.limit, fahrenheit: settings.fahrenheit)
    }

    func reload(_ history: BatteryHistory, range: HistoryRange, limit: Int, fahrenheit: Bool, now: Date = Date()) {
        let from = now.addingTimeInterval(-range.seconds)
        func series(_ field: BatteryHistoryRecord.Field) -> [[BatteryHistoryBucket]] {
            history.series(field, from: from, to: now, maxPoints: range.maxPoints)
        }
        var next = Charts(from: from, to: now, level: series(.percent), current: series(.current),
                          load: series(.systemLoad), battery: series(.batteryPower), temperature: series(.temperature),
                          states: history.states(from: from, to: now))
        if fahrenheit {
            func f(_ c: Double) -> Double { c * 9 / 5 + 32 }
            next.temperature = next.temperature.map { $0.map { var b = $0; b.low = f(b.low); b.high = f(b.high); b.mean = f(b.mean); return b } }
        }
        charts = next
        snapshots = history.snapshots
        today = history.todayStats(limit: limit)
    }
}

// MARK: - Status

struct BatteryStatusCard: View {
    let battery: BatterySnapshot
    let status: ChargeControlStatus?
    let history: BatteryHistory?
    let fahrenheit: Bool

    private var limit: ChargeLimitSettings? {
        guard let status, status.settings.enabled, status.conflict == nil, status.backend != .none else { return nil }
        return status.settings
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                hero.frame(width: 230, alignment: .leading)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Theme.Space.s)], spacing: Theme.Space.s) {
                    StatTile(label: L.t("bs.adapter"), value: battery.externalPower ? battery.systemPowerIn.map(watts) ?? "—" : "—",
                             detail: adapterDetail, icon: "bolt.fill")
                    StatTile(label: L.t("bs.system"), value: battery.systemLoad.map(watts) ?? "—", icon: "laptopcomputer")
                    StatTile(label: L.t("bs.battery"), value: battery.batteryPower.map(signedWatts) ?? "—",
                             detail: flowDetail, icon: "battery.75percent")
                    StatTile(label: L.t("bs.temperature"), value: battery.temperature.map { fmtTemp(Float($0), fahrenheit: fahrenheit) } ?? "—",
                             detail: limit.flatMap { $0.heatProtect ? L.f("bs.heatAt", fmtTemp(Float($0.heatLimit), fahrenheit: fahrenheit)) : nil },
                             icon: "thermometer.medium")
                    let estimate = self.estimate
                    StatTile(label: L.t("bs.estimate"), value: estimate.value, detail: estimate.detail, icon: "clock")
                    StatTile(label: L.t("bs.voltage"), value: battery.voltage.map { String(format: "%.2f V", $0) } ?? "—",
                             detail: battery.amperage.map { L.f("bs.currentDetail", signedAmps($0)) }, icon: "waveform.path.ecg")
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(battery.percent.map { "\($0)%" } ?? "—")
                    .font(.system(size: 48, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                Image(systemName: battery.icon).font(.system(size: 22)).foregroundStyle(battery.chargeColor)
            }
            Text(stateText).font(Theme.Typo.secondary).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            Meter(fraction: Double(battery.percent ?? 0) / 100, tint: battery.chargeColor,
                  markers: limit.map { [Double($0.limit) / 100, Double($0.resumeAt) / 100] } ?? [])
            if let limit {
                Note(L.f("bs.limitCaption", limit.limit, limit.resumeAt))
            }
            if let hardware = battery.hardwarePercent {
                Note("\(L.t("b.hardwarePercent")) \(String(format: "%.1f%%", hardware))")
            }
        }
    }

    private var stateText: String {
        if status?.adapterCut == true { return L.t("b.state.adapterPaused") }
        if status?.heatHeld == true && battery.externalPower { return L.t("b.state.heat") }
        if status?.inhibited == true && battery.externalPower { return L.f("cc.paused", status?.settings.limit ?? 100) }
        return battery.state.title
    }

    private var adapterDetail: String {
        guard battery.externalPower else { return L.t("b.noAdapter") }
        return battery.adapterWatts.map { L.f("bs.rated", $0) } ?? L.t("b.adapterConnected")
    }

    private var flowDetail: String {
        guard let power = battery.batteryPower else { return " " }
        return L.t(power > 0.05 ? "bs.batteryCharging" : power < -0.05 ? "bs.batteryDischarging" : "bs.batteryIdle")
    }

    // Our own estimate first where macOS can't help: it only times a charge to 100 %.
    private var estimate: (value: String, detail: String) {
        if status?.adapterCut == true, let target = status?.dischargeTarget { return (L.t("bs.batteryDischarging"), L.f("bs.toTarget", target)) }
        switch battery.state {
        case .charging:
            if let limit, limit.limit < 100, status?.topUp != true {
                if let seconds = history?.timeToReach(limit.limit) { return (duration(seconds), L.f("bs.toLimit", limit.limit)) }
                return ("—", L.t("bs.estimating"))
            }
            if let minutes = battery.timeToFullMinutes { return (formatBatteryMinutes(minutes), L.t("bs.toFull")) }
            return ("—", L.t("bs.estimating"))
        case .discharging:
            if let minutes = battery.timeToEmptyMinutes { return (formatBatteryMinutes(minutes), L.t("bs.untilEmpty")) }
            if let seconds = history?.timeToEmpty() { return (duration(seconds), L.t("bs.untilEmpty")) }
            return ("—", L.t("bs.estimating"))
        case .charged:
            return ("—", L.t("bs.fullNow"))
        case .notCharging:
            return ("—", status?.inhibited == true ? L.t("bs.heldNow") : battery.state.title)
        }
    }
}

// MARK: - History

struct BatteryHistoryCard: View {
    @ObservedObject var model: BatteryHistoryModel
    @Binding var range: HistoryRange
    let limit: Int?
    let heatLimit: Int?
    let fahrenheit: Bool
    @State private var hover: Date?

    var body: some View {
        let charts = model.charts
        Card(L.t("hist.title"), icon: "chart.xyaxis.line", accessory: {
            Picker("", selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Theme.accent)
        }) {
            if charts.samples < 2 {
                EmptyState(icon: "clock.arrow.circlepath", text: L.t("hist.empty")).frame(height: 180)
            } else {
                Columns(minWidth: 300) {
                    levelChart(charts)
                    chart(title: L.t("hist.current"), unit: "A", series: [ChartSeries(id: "current", name: L.t("hist.current"),
                          color: Theme.accent, runs: charts.current)], charts: charts, zero: true) { String(format: "%.1f A", $0) }
                } right: {
                    chart(title: L.t("hist.power"), unit: "W", series: [
                        ChartSeries(id: "load", name: L.t("hist.systemLoad"), color: ChartPalette.blue, runs: charts.load),
                        ChartSeries(id: "battery", name: L.t("hist.battery"), color: ChartPalette.orange, runs: charts.battery),
                    ], charts: charts, zero: true) { String(format: "%.0f W", $0) }
                    temperatureChart(charts)
                }
            }
            Note(L.t("hist.note"))
        }
    }

    private var slot: TimeInterval { max(60, range.seconds / Double(range.maxPoints)) }

    private func levelChart(_ charts: BatteryHistoryModel.Charts) -> some View {
        let series = ChartSeries(id: "level", name: L.t("hist.level"), color: Theme.accent, runs: charts.level)
        return VStack(alignment: .leading, spacing: 6) {
            header(L.t("hist.level"), value: series.latest.map { "\(Int($0.mean.rounded()))%" }, legend: [])
            TimeSeriesChart(series: [series], from: charts.from, to: charts.to, domain: 0...100, ticks: [0, 50, 100],
                            timeTicks: timeTicks(charts), references: limit.map { [ChartReference(value: Double($0), label: L.f("hist.limit", $0), color: Theme.ink2)] } ?? [],
                            // Over days, nightly gaps would stripe a wash; the line alone reads better.
                            area: !range.spansDays, slot: slot, format: { "\(Int($0))%" }, timeFormat: tickLabel, hoverFormat: hoverLabel, hover: $hover)
                .frame(height: 130)
            StateStrip(segments: charts.states, from: charts.from, to: charts.to, leading: 40)
            HStack(spacing: Theme.Space.m) {
                legendKey(L.t("hist.state.charging"), StateStrip.color(.charging), bar: true)
                legendKey(L.t("hist.state.pluggedIdle"), StateStrip.color(.pluggedIdle), bar: true)
                legendKey(L.t("hist.state.onBattery"), StateStrip.color(.onBattery), bar: true)
            }
            .padding(.leading, 40)
        }
    }

    private func temperatureChart(_ charts: BatteryHistoryModel.Charts) -> some View {
        let unit = fahrenheit ? "°F" : "°C"
        let heat = heatLimit.map { fahrenheit ? Double($0) * 9 / 5 + 32 : Double($0) }
        return chart(title: L.t("hist.temperature"), unit: unit,
                     series: [ChartSeries(id: "temperature", name: L.t("hist.temperature"), color: Theme.accent, runs: charts.temperature)],
                     charts: charts, zero: false, include: heat,
                     references: heat.map { [ChartReference(value: $0, label: L.f("hist.heatLimit", "\(Int($0))\(unit)"), color: Theme.warning)] } ?? []) {
            "\(Int($0.rounded()))\(unit)"
        }
    }

    // A small multiple: title with the latest value or a legend, then the plot.
    private func chart(title: String, unit: String, series: [ChartSeries], charts: BatteryHistoryModel.Charts,
                       zero: Bool, include: Double? = nil, references: [ChartReference] = [],
                       format: @escaping (Double) -> String) -> some View {
        let values = series.flatMap { $0.runs.joined() }
        var low = values.map(\.low).min() ?? 0, high = values.map(\.high).max() ?? 1
        if zero { low = min(low, 0); high = max(high, 0) }
        if let include { low = min(low, include); high = max(high, include) }
        let ticks = AxisTicks.ticks(low, high, count: 4)
        let domain = (ticks.first ?? low)...(ticks.last ?? high)
        return VStack(alignment: .leading, spacing: 6) {
            header(title, value: series.count == 1 ? series[0].latest.map { format($0.mean) } : nil,
                   legend: series.count > 1 ? series.map { ($0.name, $0.color, $0.latest.map { format($0.mean) }) } : [])
            TimeSeriesChart(series: series, from: charts.from, to: charts.to, domain: domain, ticks: ticks,
                            timeTicks: timeTicks(charts), references: references, zeroLine: zero, slot: slot,
                            format: format, timeFormat: tickLabel, hoverFormat: hoverLabel, hover: $hover)
                .frame(height: 130)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(series.compactMap { s in s.latest.map { "\(s.name) \(format($0.mean))" } }.joined(separator: ", "))
    }

    private func header(_ title: String, value: String?, legend: [(String, Color, String?)]) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(title).font(Theme.Typo.secondary.weight(.semibold)).foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.Space.s)
            ForEach(legend.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    Capsule().fill(legend[i].1).frame(width: 10, height: 2.5)
                    Text(legend[i].0).font(Theme.Typo.micro).foregroundStyle(Theme.ink3)
                    if let value = legend[i].2 { Text(value).font(Theme.telemetry(11)).foregroundStyle(Theme.ink) }
                }
            }
            if let value { Text(value).font(Theme.telemetry(13)).foregroundStyle(Theme.ink) }
        }
    }

    private func legendKey(_ title: String, _ color: Color, bar: Bool) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 10, height: 5)
            Text(title).font(Theme.Typo.micro).foregroundStyle(Theme.ink3)
        }
    }

    private func timeTicks(_ charts: BatteryHistoryModel.Charts) -> [Date] {
        AxisTicks.timeTicks(from: charts.from, to: charts.to, step: range.tickStep)
    }
    private func tickLabel(_ date: Date) -> String {
        Self.formatter(range.spansDays ? "Md" : "Hm").string(from: date)
    }
    private func hoverLabel(_ date: Date) -> String {
        Self.formatter(range.spansDays ? "MdHm" : "Hm").string(from: date)
    }
    private static var formatters: [String: DateFormatter] = [:]
    private static func formatter(_ template: String) -> DateFormatter {
        let locale = Locale(identifier: L.lang.resolved.localeIdentifier)
        let key = template + locale.identifier
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter(); formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = formatter
        return formatter
    }
}

// MARK: - Health and today

struct BatteryHealthCard: View {
    let battery: BatterySnapshot
    let snapshots: [BatteryHealthSnapshot]
    @State private var hover: Date?

    var body: some View {
        Card(L.t("b.health"), icon: "heart.text.square.fill") {
            if let health = battery.health {
                figure(L.t("bh.capacity"), String(format: "%.1f%%", health), fraction: health / 100,
                       detail: battery.nominalCapacity.flatMap { nominal in battery.designCapacity.map { L.f("bh.capacityDetail", nominal, $0) } })
            }
            if let cycles = battery.cycleCount {
                RowDivider()
                let design = battery.designCycleCount
                figure(L.t("b.cycles"), "\(cycles)", fraction: design.map { Double(cycles) / Double($0) },
                       detail: design.map { L.f("bh.cyclesDetail", $0) })
            }
            RowDivider()
            trend
            Note(L.t("b.capacityHelp"))
        }
    }

    private func figure(_ label: String, _ value: String, fraction: Double?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Theme.Typo.body).foregroundStyle(Theme.ink)
                Spacer()
                Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Theme.ink)
            }
            if let fraction { Meter(fraction: fraction, height: 5) }
            if let detail { Note(detail) }
        }
    }

    // Nominal capacity, one point a day.
    @ViewBuilder private var trend: some View {
        let points = snapshots.compactMap { snapshot -> BatteryHistoryBucket? in
            guard let date = snapshot.date, let health = snapshot.health else { return nil }
            return BatteryHistoryBucket(start: date, end: date, low: health, high: health, mean: health, count: 1)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t("bh.trend")).font(Theme.Typo.secondary.weight(.semibold)).foregroundStyle(Theme.ink)
            if points.count < 2 {
                Note(L.t("bh.trendEmpty"))
            } else {
                let ticks = AxisTicks.ticks(points.map(\.mean).min() ?? 90, points.map(\.mean).max() ?? 100, count: 3)
                // Daily points are a day apart, so each is its own run only if a day is missing.
                let runs = points.reduce(into: [[BatteryHistoryBucket]]()) { runs, point in
                    if let last = runs.last?.last, point.start.timeIntervalSince(last.start) <= 1.5 * 86400 { runs[runs.count - 1].append(point) }
                    else { runs.append([point]) }
                }
                let step = ticks.count > 1 ? ticks[1] - ticks[0] : 1
                TimeSeriesChart(series: [ChartSeries(id: "health", name: L.t("bh.capacity"), color: Theme.accent, runs: runs)],
                                from: points[0].start, to: points[points.count - 1].start, domain: (ticks.first ?? 90)...(ticks.last ?? 100),
                                ticks: ticks, slot: 86400, format: { String(format: step < 1 ? "%.1f%%" : "%.0f%%", $0) },
                                hoverFormat: { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) }, hover: $hover)
                    .frame(height: 90)
            }
        }
    }
}

struct BatteryTodayCard: View {
    let today: BatteryDayStats

    var body: some View {
        Card(L.t("bt.title"), icon: "calendar") {
            if today.covered < 60 {
                Note(L.t("hist.empty"))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.s), GridItem(.flexible())], spacing: Theme.Space.s) {
                    StatTile(label: L.t("bt.energy"), value: String(format: "%.1f Wh", today.wallEnergy), icon: "bolt.fill")
                    StatTile(label: L.t("bt.held"), value: duration(today.heldAtLimit), icon: "pause.circle")
                    StatTile(label: L.t("bt.full"), value: duration(today.full), icon: "battery.100percent")
                    StatTile(label: L.t("bt.onBattery"), value: duration(today.onBattery), icon: "powerplug")
                }
                Note(L.f("bt.covered", duration(today.covered)))
            }
        }
    }
}
