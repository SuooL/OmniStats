import SwiftUI

struct Ring: View {
    var value: Double
    var title: String
    var label: String
    var color: Color
    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: 7)
            Circle().trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: value)
            VStack(spacing: 0) {
                Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
                Text(label).font(Theme.telemetry(15, .bold)).foregroundStyle(Theme.ink)
            }
        }
        .frame(width: 68, height: 68)
    }
}

struct MenuPanel: View {
    @ObservedObject var mon: Monitor
    @ObservedObject var store: ConfigStore
    let engine: Engine
    @Environment(\.openWindow) private var openWindow

    private var f: Bool { store.config.fahrenheit }
    private func tempFrac(_ c: Float) -> Double { c.isNaN ? 0 : Double(max(0, min(100, c)) / 100) }
    private var fanFrac: Double {
        guard mon.fanCount > 0 else { return 0 }
        let fr = (0..<mon.fanCount).map { i -> Double in
            guard i < mon.fanRPM.count, i < mon.fanMax.count, !mon.fanRPM[i].isNaN, mon.fanMax[i] > 0 else { return 0 }
            return Double(mon.fanRPM[i] / mon.fanMax[i])
        }
        return fr.reduce(0,+) / Double(mon.fanCount)
    }

    var body: some View {
        Theme.mode = store.config.appearance
        applyAppChrome(store.config.appearance)
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 14) {
                Ring(value: tempFrac(mon.socMax), title: "SoC", label: fmtTemp(mon.socMax, fahrenheit: f), color: Theme.temp(Double(mon.socMax)))
                Ring(value: tempFrac(mon.ssd), title: "SSD", label: fmtTemp(mon.ssd, fahrenheit: f), color: Theme.temp(Double(mon.ssd)))
                if mon.fanCount > 0 {
                    Ring(value: fanFrac, title: "FANS", label: String(format: "%.0f%%", fanFrac*100), color: Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            divider
            telem("SoC 平均", fmtTemp(mon.socAvg, fahrenheit: f), Theme.temp(Double(mon.socAvg)))
            telem("电池", fmtTemp(mon.battery, fahrenheit: f), Theme.temp(Double(mon.battery)))
            if !mon.power.isNaN { telem("总功耗", String(format: "%.1f W", mon.power), Theme.ink) }
            if !mon.volt.isNaN { telem("电压", String(format: "%.2f V", mon.volt), Theme.ink) }

            if mon.fanCount > 0 {
                divider
                ForEach(0..<mon.fanCount, id: \.self) { i in
                    telem(i == 0 ? "左风扇" : i == 1 ? "右风扇" : "风扇\(i+1)",
                          i < mon.fanRPM.count && !mon.fanRPM[i].isNaN ? "\(Int(mon.fanRPM[i])) rpm" : "—", Theme.ink)
                }
            }

            if !mon.helperAvailable && mon.fanCount > 0 {
                Button { mon.enableControl() } label: {
                    HStack { if mon.busy { ProgressView().controlSize(.small) }; Text(mon.busy ? "正在启用…" : "启用风扇控制…") }
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small).disabled(mon.busy)
            }

            divider
            HStack {
                Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "settings") } label: {
                    Label("设置…", systemImage: "slider.horizontal.3")
                }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                if mon.fanCount > 0 {
                    Text("· 模式 \(store.config.mode.title)").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
                Spacer()
                Button { mon.revertAll(); NSApplication.shared.terminate(nil) } label: {
                    Text("退出").foregroundStyle(Theme.ink2)
                }.buttonStyle(.plain)
            }.font(.system(size: 12))
        }
        .padding(14).frame(width: 300)
        .background(Theme.surface)
        .environment(\.colorScheme, store.config.appearance.colorScheme)
    }

    private var divider: some View { Rectangle().fill(Theme.line).frame(height: 1) }
    private func telem(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack { Text(k).font(.system(size: 12)).foregroundStyle(Theme.ink2); Spacer()
            Text(v).font(Theme.telemetry(12)).foregroundStyle(c) }
    }
}

extension Notification.Name { static let openOmniSettings = Notification.Name("openOmniSettings") }

struct MenuLabel: View {
    @ObservedObject var mon: Monitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "thermometer.medium")
            Text(mon.socMax.isNaN ? "—" : String(format: "%.0f°", mon.socMax)).monospacedDigit()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openOmniSettings)) { _ in
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
    }
}
