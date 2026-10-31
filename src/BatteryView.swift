import SwiftUI
import AppKit

extension BatterySnapshot.State {
    var title: String {
        switch self {
        case .charging:    return L.t("b.state.charging")
        case .notCharging: return L.t("b.state.notCharging")
        case .charged:     return L.t("b.state.charged")
        case .discharging: return L.t("b.state.discharging")
        }
    }
}

extension BatterySnapshot {
    var icon: String {
        if state == .charging { return "battery.100percent.bolt" }
        switch percent ?? 0 {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default:    return "battery.0percent"
        }
    }
    var chargeColor: Color { percent.map { Theme.charge(Double($0)) } ?? Theme.ink3 }
}

private struct ChargeBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Theme.line)
            Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction)))
        }
    }
}

// Menu-panel section: charge, state and where the power is going. Rows keep
// their height before the first reading so the panel never jumps on open.
struct BatteryPanelSection: View {
    @ObservedObject var sampler: BatterySampler
    @ObservedObject var charge: ChargeController
    var history: BatteryHistory?

    var body: some View {
        let battery = sampler.snapshot
        let color = battery?.chargeColor ?? Theme.ink3
        let limit = charge.status.flatMap { $0.settings.enabled && $0.conflict == nil && $0.backend != .none ? $0 : nil }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: battery?.icon ?? "battery.0percent").font(.system(size: 12)).foregroundStyle(color)
                Text(L.t("m.batteryCharge")).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                if let battery {
                    let held = limit?.inhibited == true && battery.externalPower
                    let hot = limit?.heatHeld == true && battery.externalPower
                    let discharging = charge.status?.adapterCut == true
                    Text(discharging ? L.t("b.state.adapterPaused") : hot ? L.t("b.state.heat")
                         : held ? L.t("b.state.held") : battery.state.title)
                        .font(.system(size: 10)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let limit {
                    Text(L.f("m.limitChip", limit.topUp ? 100 : limit.settings.limit))
                        .font(Theme.telemetry(9)).foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                }
                Text(battery?.percent.map { "\($0)%" } ?? "—").font(Theme.telemetry(12)).foregroundStyle(color)
            }
            ChargeBar(fraction: Double(battery?.percent ?? 0) / 100, color: color).frame(height: 3)
            flow(battery)
            if let history { trend(history) }
        }
        .accessibilityElement(children: .combine)
    }

    // The last two hours of charge. Its row is always there when history is, so
    // the panel's height doesn't change as samples arrive.
    private func trend(_ history: BatteryHistory) -> some View {
        let now = Date(), from = now.addingTimeInterval(-7200)
        let runs = history.series(.percent, from: from, to: now, maxPoints: 120)
        return HStack(spacing: 6) {
            Text(L.t("m.batteryTrend")).font(Theme.Typo.micro).foregroundStyle(Theme.ink3)
            TimeSeriesChart(series: [ChartSeries(id: "level", name: "", color: Theme.accent, runs: runs)],
                            from: from, to: now, domain: 0...100, ticks: [], area: true, compact: true,
                            format: { "\(Int($0))%" }, hover: .constant(nil))
        }
        .frame(height: 18)
    }

    private func flow(_ battery: BatterySnapshot?) -> some View {
        HStack(spacing: 10) {
            if let battery {
                if battery.externalPower, let input = battery.systemPowerIn { stat("bolt.fill", watts(input)) }
                if let load = battery.systemLoad { stat("cpu", watts(load)) }
                if let power = battery.batteryPower { stat("battery.50percent", signedWatts(power)) }
            }
            Spacer(minLength: 0)
            if let minutes = battery?.timeToFullMinutes ?? battery?.timeToEmptyMinutes {
                Text(formatBatteryMinutes(minutes)).font(Theme.telemetry(10)).foregroundStyle(Theme.ink3)
            }
        }
        .frame(height: 14)
        .help(L.t("m.flowHelp"))
    }
    private func stat(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(Theme.ink3)
            Text(value).font(Theme.telemetry(10)).foregroundStyle(Theme.ink2)
        }
    }
}

// Settings pane: status and history first, controls below in two columns.
struct BatteryPane: View {
    @ObservedObject var sampler: BatterySampler
    @ObservedObject var store: ConfigStore
    let mon: Monitor
    @ObservedObject var charge: ChargeController
    var history: BatteryHistory?
    @StateObject private var model = BatteryHistoryModel()
    @State private var range = BatteryPane.initialRange
    static var initialRange = HistoryRange.hours24   // screenshots may pick another

    private var limit: ChargeLimitSettings? {
        guard let status = charge.status, status.settings.enabled, status.conflict == nil, status.backend != .none else { return nil }
        return status.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            PageHeader(title: L.t("b.title"), subtitle: L.t("b.subtitle"))
            if let battery = sampler.snapshot {
                BatteryStatusCard(battery: battery, status: charge.status, history: history, fahrenheit: store.config.fahrenheit)
                if history != nil {
                    BatteryHistoryCard(model: model, range: $range,
                                       limit: limit.flatMap { $0.limit < 100 ? $0.limit : nil },
                                       heatLimit: limit.flatMap { $0.heatProtect ? $0.heatLimit : nil },
                                       fahrenheit: store.config.fahrenheit)
                }
                Columns {
                    ChargeControlCard(control: charge, mon: mon, external: battery.externalPower,
                                      fahrenheit: store.config.fahrenheit)
                    DischargeCard(control: charge)
                } right: {
                    BatteryHealthCard(battery: battery, snapshots: model.snapshots)
                    if history != nil { BatteryTodayCard(today: model.today) }
                    ChargeScheduleCard(store: store)
                }
            } else {
                Card {
                    EmptyState(icon: "battery.0percent", text: L.t(sampler.hasSample ? "b.unavailable" : "b.loading"))
                        .frame(height: 120)
                }
            }
        }
        .onAppear(perform: show)
        .onChange(of: range) { _ in show() }
        .onChange(of: store.config.fahrenheit) { _ in show() }
        .onChange(of: limit?.limit) { _ in show() }
    }

    private func show() {
        guard let history else { return }
        model.show(history, range: range, limit: limit?.limit ?? 100, fahrenheit: store.config.fahrenheit)
    }
}

// Settings card for the helper's charge limit. Edits go straight to the helper;
// the slider sends its value on release rather than on every step.
struct ChargeControlCard: View {
    @ObservedObject var control: ChargeController
    @ObservedObject var mon: Monitor
    let external: Bool
    let fahrenheit: Bool
    @State private var draggedLimit: Double?

    var body: some View {
        Card(L.t("cc.title"), icon: "bolt.fill") {
            if !mon.helperSupportsBattery {
                HelperCallout(mon: mon, title: L.t(mon.helperNeedsUpdate ? "control.update" : "cc.title"),
                              message: L.t(mon.helperNeedsUpdate ? "control.updateBody" : "cc.needsHelper"), action: "cc.install")
            } else if let status = control.status {
                controls(status)
            } else {
                Note(L.t("b.loading"))
            }
            if let error = control.lastError { Callout(.error, message: L.f("cc.error", error)) }
        }
        .onChange(of: control.status?.settings.limit) { _ in draggedLimit = nil }
    }

    @ViewBuilder private func controls(_ status: ChargeControlStatus) -> some View {
        let settings = status.settings
        let usable = status.backend != .none && status.conflict == nil
        toggle(L.t("cc.enable"), settings.enabled) { var s = settings; s.enabled = $0; control.apply(s) }
            .disabled(!usable && !settings.enabled)
        if status.backend == .none {
            Callout(.warning, message: L.t("cc.unsupported")) { openBatterySettings }
        }
        if let conflict = status.conflict { Callout(.warning, message: L.f("cc.conflict", conflict)) }
        if settings.enabled && usable {
            let shown = Int(draggedLimit ?? Double(settings.limit))
            VStack(alignment: .leading, spacing: 4) {
                Text(L.f("cc.stopAt", shown)).font(Theme.Typo.body).foregroundStyle(Theme.ink)
                Slider(value: Binding(get: { draggedLimit ?? Double(settings.limit) }, set: { draggedLimit = $0 }),
                       in: Double(ChargeLimitSettings.limitRange.lowerBound)...Double(ChargeLimitSettings.limitRange.upperBound),
                       step: 5, onEditingChanged: { editing in
                    guard !editing, let value = draggedLimit, Int(value) != settings.limit else { return }
                    var s = settings; s.limit = Int(value); control.apply(s)
                })
                .tint(Theme.accent)
            }
            Stepper(value: Binding(get: { settings.sailing }, set: { var s = settings; s.sailing = $0; control.apply(s) }),
                    in: ChargeLimitSettings.sailingRange) {
                Text(L.f("cc.resumeAt", settings.resumeAt)).font(Theme.Typo.body).foregroundStyle(Theme.ink)
            }
            .help(L.t("cc.resumeHelp"))
            nativeLimitNote(settings.limit)
            Text(stateText(status)).font(Theme.Typo.caption).foregroundStyle(Theme.ink2)
            if external { topUpRow(status) }
            RowDivider()
            toggle(L.t("cc.sleepStop"), settings.sleepStop) { var s = settings; s.sleepStop = $0; control.apply(s) }
                .help(L.t("cc.sleepStopHelp"))
            toggle(L.t("cc.stayAwake"), settings.stayAwake) { var s = settings; s.stayAwake = $0; control.apply(s) }
            heatRows(status)
        }
        // The LED works without the limit, and even where charging can't be controlled.
        if status.ledSupported && status.conflict == nil {
            RowDivider()
            ledRow(status)
        }
        if status.writeFailed { Callout(.error, message: L.t("cc.writeFailed")) }
    }

    @ViewBuilder private func heatRows(_ status: ChargeControlStatus) -> some View {
        let settings = status.settings
        toggle(L.t("cc.heat"), settings.heatProtect) { var s = settings; s.heatProtect = $0; control.apply(s) }
            .help(L.t("cc.heatHelp"))
        if settings.heatProtect {
            Stepper(value: Binding(get: { settings.heatLimit }, set: { var s = settings; s.heatLimit = $0; control.apply(s) }),
                    in: ChargeLimitSettings.heatRange) {
                Text(L.f("cc.heatAbove", temperature(Double(settings.heatLimit))))
                    .font(Theme.Typo.body).foregroundStyle(Theme.ink)
            }
            if let current = status.temperature { Note(L.f("cc.heatNow", temperature(current))) }
        }
    }

    private func ledRow(_ status: ChargeControlStatus) -> some View {
        let settings = status.settings
        return SettingRow(L.t("cc.led")) {
            Picker("", selection: Binding(get: { settings.ledMode }, set: { var s = settings; s.ledMode = $0; control.apply(s) })) {
                ForEach(ChargeLimitSettings.LedMode.allCases) { mode in Text(L.t("cc.led.\(mode)")).tag(mode) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Theme.accent)
        }
        .help(L.t("cc.ledHelp"))
    }

    private func temperature(_ celsius: Double) -> String { fmtTemp(Float(celsius), fahrenheit: fahrenheit) }

    @ViewBuilder private func nativeLimitNote(_ limit: Int) -> some View {
        if let native = control.nativeLimit, native < limit {
            Callout(.warning, message: L.f("cc.nativeBelow", native, limit)) { openBatterySettings }
        } else if let native = control.nativeLimit, native < 100 {
            Note(L.f("cc.nativeSafety", native))
        }
    }

    private func stateText(_ status: ChargeControlStatus) -> String {
        if status.heatHeld, let current = status.temperature { return L.f("cc.heatPaused", temperature(current)) }
        if status.topUp { return L.t("cc.toppingUp") }
        if status.inhibited { return L.f("cc.paused", status.settings.limit) }
        return external ? L.f("cc.chargingTo", status.settings.limit) : L.t("cc.onBattery")
    }

    @ViewBuilder private func topUpRow(_ status: ChargeControlStatus) -> some View {
        HStack(spacing: 10) {
            Button(L.t(status.topUp ? "cc.cancelTopUp" : "cc.topUp")) { control.setTopUp(!status.topUp) }.secondaryButton()
            if status.topUp, let native = control.nativeLimit, native < 100 { Note(L.f("cc.topUpNative", native)) }
        }
    }

    private var openBatterySettings: some View {
        Button(L.t("cc.openBattery")) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        .secondaryButton()
    }
    private func toggle(_ label: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        ToggleRow(label, isOn: Binding(get: { value }, set: set))
    }
}

// Repeating charge actions; the app runs them (see ChargeScheduleRunner).
struct ChargeScheduleCard: View {
    @ObservedObject var store: ConfigStore
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: L.lang.resolved.localeIdentifier)
        return calendar
    }

    var body: some View {
        Card(L.t("sched.title"), icon: "calendar.badge.clock", accessory: {
            Button(L.t("sched.add")) { store.config.chargeSchedules.append(ChargeSchedule()) }
                .secondaryButton()
                .disabled(store.config.chargeSchedules.count >= 16)
        }) {
            if store.config.chargeSchedules.isEmpty {
                Note(L.t("sched.empty"))
            }
            ForEach(store.config.chargeSchedules) { schedule in
                row(schedule)
                RowDivider()
            }
            Note(L.t("sched.note"))
            Note(L.t("sched.shortcuts")).textSelection(.enabled)
        }
    }

    private func row(_ schedule: ChargeSchedule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DatePicker("", selection: time(schedule), displayedComponents: .hourAndMinute)
                    .labelsHidden().frame(width: 110)
                Picker("", selection: binding(schedule, \.action)) {
                    ForEach(ChargeSchedule.Action.allCases) { action in
                        Text(L.t("sched.action.\(action.rawValue)")).tag(action)
                    }
                }
                .labelsHidden().frame(width: 140)
                if schedule.action == .setLimit {
                    Stepper(value: binding(schedule, \.limit), in: ChargeLimitSettings.limitRange, step: 5) {
                        Text("\(schedule.limit)%").font(Theme.telemetry(12)).foregroundStyle(Theme.ink)
                    }
                }
                Spacer()
                Button { store.config.chargeSchedules.removeAll { $0.id == schedule.id } } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.ink3).help(L.t("sched.delete"))
                Toggle(isOn: binding(schedule, \.enabled)) { EmptyView() }.toggleStyle(.themed).fixedSize()
            }
            weekdays(schedule)
        }
        .opacity(schedule.enabled ? 1 : 0.55)
    }

    // Seven chips starting at the locale's first weekday.
    private func weekdays(_ schedule: ChargeSchedule) -> some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return HStack(spacing: 6) {
            ForEach(order, id: \.self) { day in
                let on = schedule.weekdays.contains(day)
                Button {
                    var days = schedule.weekdays
                    if on { days.remove(day) } else { days.insert(day) }
                    if !days.isEmpty { update(schedule) { $0.weekdays = days } }
                } label: {
                    Text(symbols[day - 1]).font(Theme.Typo.caption.weight(.medium))
                        .frame(width: 26, height: 22)
                        .background(on ? Theme.accent.opacity(0.22) : Theme.line.opacity(0.5))
                        .foregroundStyle(on ? Theme.accent : Theme.ink3)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }

    private func update(_ schedule: ChargeSchedule, _ change: (inout ChargeSchedule) -> Void) {
        guard let index = store.config.chargeSchedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        change(&store.config.chargeSchedules[index])
    }
    private func binding<T>(_ schedule: ChargeSchedule, _ keyPath: WritableKeyPath<ChargeSchedule, T>) -> Binding<T> {
        Binding(get: { store.config.chargeSchedules.first { $0.id == schedule.id }?[keyPath: keyPath] ?? schedule[keyPath: keyPath] },
                set: { value in update(schedule) { $0[keyPath: keyPath] = value } })
    }
    private func time(_ schedule: ChargeSchedule) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            update(schedule) { $0.hour = parts.hour ?? $0.hour; $0.minute = parts.minute ?? $0.minute }
        })
    }
}

// Discharging and calibration pause the power adapter, so they live in their own
// card with the safety note up front. Hidden on Macs without the adapter key.
struct DischargeCard: View {
    @ObservedObject var control: ChargeController
    @State private var target = 80
    @State private var confirmCalibration = false

    var body: some View {
        if let status = control.status, status.adapterSupported {
            Card(L.t("dc.title"), icon: "battery.25percent") {
                Note(L.t("dc.note"))
                if let conflict = status.conflict {
                    Callout(.warning, message: L.f("cc.conflict", conflict))
                } else {
                    content(status)
                }
            }
            .alert(L.t("dc.calibrateTitle"), isPresented: $confirmCalibration) {
                Button(L.t("dc.calibrateStart")) { control.calibrate(true) }
                Button(L.t("dc.cancel"), role: .cancel) {}
            } message: {
                Text(L.t("dc.calibrateBody"))
            }
        }
    }

    @ViewBuilder private func content(_ status: ChargeControlStatus) -> some View {
        let settings = status.settings
        if settings.enabled && settings.limit < 100 {
            ToggleRow(L.t("dc.auto"), isOn: Binding(get: { settings.autoDischarge },
                                                    set: { var s = settings; s.autoDischarge = $0; control.apply(s) }))
        }
        if !status.plugged { Note(L.t("dc.needsPlug")) }
        RowDivider()
        if status.calibration != .idle {
            calibrationRow(status)
        } else if let manual = status.dischargeTarget {
            activeRow(L.f("dc.active", manual) + (status.percent.map { " · " + L.f("dc.progress.now", $0) } ?? "")) {
                control.discharge(to: nil)
            }
        } else if status.adapterCut {
            Note(L.f("dc.activeAuto", settings.limit))
        } else {
            HStack(spacing: 10) {
                Stepper(value: $target, in: 10...95, step: 5) {
                    Text(L.f("dc.target", target)).font(Theme.Typo.body).foregroundStyle(Theme.ink)
                }
                Spacer()
                Button(L.t("dc.start")) { control.discharge(to: target) }
                    .secondaryButton()
                    .disabled(!status.plugged)
            }
            calibrationStart(status)
        }
    }

    @ViewBuilder private func calibrationRow(_ status: ChargeControlStatus) -> some View {
        activeRow(Self.calibrationText(status)) { control.calibrate(false) }
        Note(L.t("dc.calibrateAuto"))
    }

    // "Calibrating · Step 1/5: charging to 100% · now 99%, 61 min so far"
    static func calibrationText(_ status: ChargeControlStatus) -> String {
        let holdLeft = max(0, Int((3600 - status.calibrationElapsed) / 60))
        let minutes = Int(status.calibrationElapsed / 60)
        var progress: String?
        let text: String
        switch status.calibration {
        case .charge1: text = L.t("dc.phase.charge1")
        case .hold1: text = L.f("dc.phase.hold1", holdLeft)
        case .discharge: text = L.t("dc.phase.discharge")
        case .charge2: text = L.t("dc.phase.charge2")
        case .hold2: text = L.f("dc.phase.hold2", holdLeft)
        case .toLimit: text = L.t("dc.phase.toLimit")
        case .idle: text = ""
        }
        switch status.calibration {
        case .charge1, .charge2: progress = status.percent.map { L.f("dc.progress.charge", $0, minutes) }
        case .discharge, .toLimit: progress = status.percent.map { L.f("dc.progress.now", $0) }
        default: break
        }
        return [L.t("dc.calibrating"), text, progress].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func calibrationStart(_ status: ChargeControlStatus) -> some View {
        let native = control.nativeLimit ?? 100
        HStack(spacing: 10) {
            Button(L.t("dc.calibrate")) { confirmCalibration = true }
                .secondaryButton()
                .disabled(!status.plugged || native < 100)
            if status.calibrationResult == 1 { Label(L.t("dc.resultDone"), systemImage: "checkmark.circle.fill").font(Theme.Typo.caption).foregroundStyle(Theme.success) }
            if status.calibrationResult == 2 { Label(L.t("dc.resultStopped"), systemImage: "exclamationmark.triangle.fill").font(Theme.Typo.caption).foregroundStyle(Theme.warning) }
        }
        if native < 100 { Callout(.warning, message: L.f("dc.needsNative100", native)) }
    }

    private func activeRow(_ text: String, stop: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(Theme.Typo.secondary).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L.t("dc.stop"), action: stop).secondaryButton()
        }
    }
}
