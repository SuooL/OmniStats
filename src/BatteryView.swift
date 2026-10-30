import SwiftUI

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

    var body: some View {
        let battery = sampler.snapshot
        let color = battery?.chargeColor ?? Theme.ink3
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: battery?.icon ?? "battery.0percent").font(.system(size: 12)).foregroundStyle(color)
                Text(L.t("m.batteryCharge")).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                if let battery {
                    Text(battery.state.title).font(.system(size: 10)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Spacer(minLength: 4)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L.t("b.title")).font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.ink)
                Text(L.t("b.subtitle")).font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
            if let battery = sampler.snapshot {
                status(battery)
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
