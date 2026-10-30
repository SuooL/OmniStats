import SwiftUI
import AppKit

private func watts(_ value: Double) -> String { String(format: "%.1f W", value) }
private func signedWatts(_ value: Double) -> String {
    abs(value) < 0.05 ? "0.0 W" : String(format: "%+.1f W", value)
}

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
                    Text(hot ? L.t("b.state.heat") : held ? L.t("b.state.held") : battery.state.title)
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
        }
        .accessibilityElement(children: .combine)
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

// Settings pane: the same readings in full, plus capacity and cycle health.
struct BatteryPane: View {
    @ObservedObject var sampler: BatterySampler
    @ObservedObject var store: ConfigStore
    let mon: Monitor
    let charge: ChargeController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L.t("b.title")).font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.ink)
                Text(L.t("b.subtitle")).font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
            if let battery = sampler.snapshot {
                status(battery)
                ChargeControlCard(control: charge, mon: mon, external: battery.externalPower,
                                  fahrenheit: store.config.fahrenheit)
                ChargeScheduleCard(store: store)
                HStack(alignment: .top, spacing: 18) {
                    flow(battery)
                    health(battery)
                }
                .frame(maxWidth: 640)
            } else {
                card(nil) {
                    Text(L.t(sampler.hasSample ? "b.unavailable" : "b.loading"))
                        .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func status(_ battery: BatterySnapshot) -> some View {
        card(L.t("b.status")) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: battery.icon).font(.system(size: 26)).foregroundStyle(battery.chargeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(battery.percent.map { "\($0)%" } ?? "—")
                        .font(Theme.telemetry(28, .bold)).foregroundStyle(Theme.ink)
                    Text(battery.state.title).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
                Spacer()
            }
            ChargeBar(fraction: Double(battery.percent ?? 0) / 100, color: battery.chargeColor).frame(height: 5)
            if let hardware = battery.hardwarePercent {
                row(L.t("b.hardwarePercent"), String(format: "%.1f%%", hardware), help: L.t("b.hardwareHelp"))
            }
            if let minutes = battery.timeToFullMinutes {
                row(L.t("b.timeToFull"), formatBatteryMinutes(minutes))
            } else if let minutes = battery.timeToEmptyMinutes {
                row(L.t("b.timeToEmpty"), formatBatteryMinutes(minutes))
            }
            row(L.t("b.powerSource"), adapterText(battery))
        }
        .frame(maxWidth: 640)
    }

    private func flow(_ battery: BatterySnapshot) -> some View {
        card(L.t("b.powerFlow")) {
            if battery.externalPower, let input = battery.systemPowerIn { row(L.t("b.fromAdapter"), watts(input)) }
            if let load = battery.systemLoad { row(L.t("b.systemLoad"), watts(load)) }
            if let power = battery.batteryPower {
                row(L.t("b.batteryFlow"), signedWatts(power), help: L.t("b.batteryFlowHelp"))
            }
            if battery.externalPower, let loss = battery.adapterLoss { row(L.t("b.adapterLoss"), watts(loss)) }
            if let voltage = battery.voltage, let amperage = battery.amperage {
                let current = abs(amperage) < 0.005 ? "0.00 A" : String(format: "%+.2f A", amperage)
                row(L.t("b.voltageCurrent"), String(format: "%.2f V · ", voltage) + current)
            }
        }
    }

    private func health(_ battery: BatterySnapshot) -> some View {
        card(L.t("b.health")) {
            if let health = battery.health {
                row(L.t("b.maxCapacity"), String(format: "%.0f%%", health), help: L.t("b.capacityHelp"))
            }
            if let full = battery.fullChargeCapacity { row(L.t("b.fullCharge"), "\(full) mAh") }
            if let design = battery.designCapacity { row(L.t("b.design"), "\(design) mAh") }
            if let cycles = battery.cycleCount {
                row(L.t("b.cycles"), battery.designCycleCount.map { "\(cycles) / \($0)" } ?? "\(cycles)")
            }
            if let temperature = battery.temperature {
                row(L.t("b.temperature"), fmtTemp(Float(temperature), fahrenheit: store.config.fahrenheit))
            }
        }
    }

    private func adapterText(_ battery: BatterySnapshot) -> String {
        guard battery.externalPower else { return L.t("b.noAdapter") }
        switch (battery.adapterName, battery.adapterWatts) {
        case let (name?, watts?) where !name.contains("\(watts)W"): return "\(name) · \(watts) W"
        case let (name?, _): return name
        case let (nil, watts?): return "\(watts) W"
        default: return L.t("b.adapterConnected")
        }
    }

    private func row(_ label: String, _ value: String, help: String? = nil) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.ink2)
            Spacer(minLength: 8)
            Text(value).font(Theme.telemetry(12)).foregroundStyle(Theme.ink).lineLimit(1)
        }
        .help(help ?? "")
    }
    @ViewBuilder private func card<C: View>(_ title: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 7, y: 2)
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
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("cc.title")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            if !mon.helperSupportsBattery {
                helperRow
            } else if let status = control.status {
                controls(status)
            } else {
                note(L.t("b.loading"))
            }
            if let error = control.lastError { alert(L.f("cc.error", error), .red) }
        }
        .padding(16).frame(maxWidth: 640, alignment: .leading)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 7, y: 2)
        .onChange(of: control.status?.settings.limit) { _ in draggedLimit = nil }
    }

    private var helperRow: some View {
        HStack(spacing: 10) {
            note(L.t("cc.needsHelper"))
            Spacer()
            Button { mon.enableControl() } label: {
                HStack {
                    if mon.busy { ProgressView().controlSize(.small) }
                    Text(L.t(mon.helperNeedsUpdate ? "control.updateShort" : "cc.install"))
                }
            }.buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small).disabled(mon.busy)
        }
    }

    @ViewBuilder private func controls(_ status: ChargeControlStatus) -> some View {
        let settings = status.settings
        let usable = status.backend != .none && status.conflict == nil
        toggle(L.t("cc.enable"), settings.enabled) { var s = settings; s.enabled = $0; control.apply(s) }
            .disabled(!usable && !settings.enabled)
        if status.backend == .none {
            HStack(alignment: .top, spacing: 10) {
                alert(L.t("cc.unsupported"), .orange)
                Spacer()
                openBatterySettings
            }
        }
        if let conflict = status.conflict { alert(L.f("cc.conflict", conflict), .orange) }
        if settings.enabled && usable {
            let shown = Int(draggedLimit ?? Double(settings.limit))
            VStack(alignment: .leading, spacing: 4) {
                Text(L.f("cc.stopAt", shown)).font(.system(size: 12)).foregroundStyle(Theme.ink)
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
                Text(L.f("cc.resumeAt", settings.resumeAt)).font(.system(size: 12)).foregroundStyle(Theme.ink)
            }
            .help(L.t("cc.resumeHelp"))
            nativeLimitNote(settings.limit)
            Text(stateText(status)).font(.system(size: 11)).foregroundStyle(Theme.ink2)
            if external { topUpRow(status) }
            Divider().overlay(Theme.line)
            toggle(L.t("cc.sleepStop"), settings.sleepStop) { var s = settings; s.sleepStop = $0; control.apply(s) }
                .help(L.t("cc.sleepStopHelp"))
            toggle(L.t("cc.stayAwake"), settings.stayAwake) { var s = settings; s.stayAwake = $0; control.apply(s) }
            heatRows(status)
        }
        // The LED works without the limit, and even where charging can't be controlled.
        if status.ledSupported && status.conflict == nil {
            Divider().overlay(Theme.line)
            ledRow(status)
        }
        if status.writeFailed { alert(L.t("cc.writeFailed"), .red) }
    }

    @ViewBuilder private func heatRows(_ status: ChargeControlStatus) -> some View {
        let settings = status.settings
        toggle(L.t("cc.heat"), settings.heatProtect) { var s = settings; s.heatProtect = $0; control.apply(s) }
            .help(L.t("cc.heatHelp"))
        if settings.heatProtect {
            Stepper(value: Binding(get: { settings.heatLimit }, set: { var s = settings; s.heatLimit = $0; control.apply(s) }),
                    in: ChargeLimitSettings.heatRange) {
                Text(L.f("cc.heatAbove", temperature(Double(settings.heatLimit))))
                    .font(.system(size: 12)).foregroundStyle(Theme.ink)
            }
            if let current = status.temperature { note(L.f("cc.heatNow", temperature(current))) }
        }
    }

    private func ledRow(_ status: ChargeControlStatus) -> some View {
        let settings = status.settings
        return HStack {
            Text(L.t("cc.led")).font(.system(size: 12)).foregroundStyle(Theme.ink)
            Spacer()
            Picker("", selection: Binding(get: { settings.ledMode }, set: { var s = settings; s.ledMode = $0; control.apply(s) })) {
                ForEach(ChargeLimitSettings.LedMode.allCases) { mode in Text(L.t("cc.led.\(mode)")).tag(mode) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 250)
        }
        .help(L.t("cc.ledHelp"))
    }

    private func temperature(_ celsius: Double) -> String { fmtTemp(Float(celsius), fahrenheit: fahrenheit) }

    @ViewBuilder private func nativeLimitNote(_ limit: Int) -> some View {
        if let native = control.nativeLimit, native < limit {
            HStack(alignment: .top, spacing: 10) {
                alert(L.f("cc.nativeBelow", native, limit), .orange)
                Spacer()
                openBatterySettings
            }
        } else if let native = control.nativeLimit, native < 100 {
            note(L.f("cc.nativeSafety", native))
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
            Button(L.t(status.topUp ? "cc.cancelTopUp" : "cc.topUp")) { control.setTopUp(!status.topUp) }
                .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
            if status.topUp, let native = control.nativeLimit, native < 100 { note(L.f("cc.topUpNative", native)) }
        }
    }

    private var openBatterySettings: some View {
        Button(L.t("cc.openBattery")) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
    }
    private func toggle(_ label: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: set)) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.ink)
        }
        .toggleStyle(.themed)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
    }
    private func alert(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.t("sched.title")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button(L.t("sched.add")) { store.config.chargeSchedules.append(ChargeSchedule()) }
                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                    .disabled(store.config.chargeSchedules.count >= 16)
            }
            if store.config.chargeSchedules.isEmpty {
                note(L.t("sched.empty"))
            }
            ForEach(store.config.chargeSchedules) { schedule in
                row(schedule)
                Divider().overlay(Theme.line)
            }
            note(L.t("sched.note"))
            Text(L.t("sched.shortcuts")).font(.system(size: 11)).foregroundStyle(Theme.ink3)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: 640, alignment: .leading)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 7, y: 2)
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
                Toggle("", isOn: binding(schedule, \.enabled)).toggleStyle(.switch).labelsHidden().controlSize(.small)
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
                    Text(symbols[day - 1]).font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 22)
                        .background(on ? Theme.accent.opacity(0.22) : Theme.line.opacity(0.5))
                        .foregroundStyle(on ? Theme.accent : Theme.ink3)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
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
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
    }
}
