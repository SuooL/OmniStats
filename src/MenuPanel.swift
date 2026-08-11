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
    @ObservedObject var net: NetSampler
    @ObservedObject var proc: ProcSampler
    @Environment(\.openWindow) private var openWindow

    private var f: Bool { store.config.fahrenheit }
    private func tempFrac(_ c: Float) -> Double { c.isNaN ? 0 : Double(max(0, min(100, c)) / 100) }
    private func fanPct(_ i: Int) -> Double? {
        guard i < mon.fanRPM.count, i < mon.fanMax.count, !mon.fanRPM[i].isNaN, mon.fanMax[i] > 0 else { return nil }
        return Double(mon.fanRPM[i] / mon.fanMax[i]) * 100
    }
    private func fanName(_ i: Int) -> String {
        i == 0 ? L.t("m.fanLeft") : i == 1 ? L.t("m.fanRight") : L.f("m.fanN", i + 1)
    }
    private var fanFrac: Double {
        guard mon.fanCount > 0 else { return 0 }
        let fr = (0..<mon.fanCount).map { (fanPct($0) ?? 0) / 100 }
        return fr.reduce(0,+) / Double(mon.fanCount)
    }

    var body: some View {
        syncPresentation(store.config)
        proc.enabled = store.config.showProcesses
        proc.windowSeconds = store.config.cpuWindow.seconds
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
            telem(L.t("m.socAvg"), fmtTemp(mon.socAvg, fahrenheit: f), Theme.temp(Double(mon.socAvg)))
            telem(L.t("m.battery"), fmtTemp(mon.battery, fahrenheit: f), Theme.temp(Double(mon.battery)))
            if !mon.power.isNaN { telem(L.t("m.power"), String(format: "%.1f W", mon.power), Theme.ink) }
            if !mon.volt.isNaN { telem(L.t("m.voltage"), String(format: "%.2f V", mon.volt), Theme.ink) }

            if store.config.showNetworkPanel { networkSection }

            if mon.fanCount > 0 {
                divider
                ForEach(0..<mon.fanCount, id: \.self) { i in
                    let rpm = i < mon.fanRPM.count && !mon.fanRPM[i].isNaN ? "\(Int(mon.fanRPM[i])) rpm" : "—"
                    let pct = fanPct(i).map { String(format: " · %.0f%%", $0) } ?? ""
                    telem(fanName(i), rpm + pct, Theme.ink)
                }
            }

            if store.config.showProcesses { processSection }

            if !mon.helperAvailable && mon.fanCount > 0 {
                Button { mon.enableControl() } label: {
                    HStack { if mon.busy { ProgressView().controlSize(.small) }; Text(mon.busy ? L.t("m.enabling") : L.t("m.enableControl")) }
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small).disabled(mon.busy)
            }

            divider
            HStack {
                Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "settings") } label: {
                    Label(L.t("m.settings"), systemImage: "slider.horizontal.3")
                }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                if mon.fanCount > 0 {
                    Text("· \(L.t("m.mode")) \(store.config.mode.title)").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
                Spacer()
                Button { mon.revertAll(); NSApplication.shared.terminate(nil) } label: {
                    Text(L.t("m.quit")).foregroundStyle(Theme.ink2)
                }.buttonStyle(.plain)
            }.font(.system(size: 12))
        }
        .padding(14).frame(width: 300)
        .background(Theme.surface)
        .environment(\.colorScheme, store.config.appearance.colorScheme)
    }

    // Live network: upload/download for the most active interface.
    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            divider
            HStack(spacing: 6) {
                Text(L.t("m.network")).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                if !net.iface.isEmpty {
                    Text(net.iface).font(.system(size: 10)).foregroundStyle(Theme.ink3)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                netStat("arrow.up", net.txBps)
                netStat("arrow.down", net.rxBps)
                Spacer()
            }
        }
    }
    private func netStat(_ icon: String, _ rate: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
            Text(humanRate(rate)).font(Theme.telemetry(12)).foregroundStyle(Theme.ink)
        }
    }

    // Top CPU processes, merged per program.
    private var processSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            divider
            Text(L.t("m.procHeader")).font(.system(size: 12)).foregroundStyle(Theme.ink2)
            if proc.top.isEmpty {
                Text(L.t("m.idle")).font(.system(size: 11)).foregroundStyle(Theme.ink3)
            } else {
                ForEach(proc.top) { p in
                    HStack {
                        Text(p.name).font(.system(size: 11)).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.0f%%", p.cpu)).font(Theme.telemetry(11)).foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }

    private var divider: some View { Rectangle().fill(Theme.line).frame(height: 1) }
    private func telem(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack { Text(k).font(.system(size: 12)).foregroundStyle(Theme.ink2); Spacer()
            Text(v).font(Theme.telemetry(12)).foregroundStyle(c) }
    }
}

extension Notification.Name { static let openOmniSettings = Notification.Name("openOmniSettings") }

// The menu-bar label.
//
// SwiftUI's MenuBarExtra clips a multi-subview / stacked label (it shows only the
// first row and drops trailing views), so we rasterize the whole readout into one
// NSImage via ImageRenderer — the menu bar draws an image at its natural size with
// no clipping. This is how pro menu-bar apps stack upload/download on two rows.
struct MenuLabel: View {
    @ObservedObject var mon: Monitor
    @ObservedObject var store: ConfigStore
    @ObservedObject var net: NetSampler
    @Environment(\.openWindow) private var openWindow

    private var arrowColor: Color {
        switch store.config.menuNumberColor {
        case .accent, .tempGradient: return Theme.accent   // arrows accent-tinted, distinct from the numbers
        case .mono:                  return .primary
        }
    }
    private var numberColor: Color {
        switch store.config.menuNumberColor {
        case .accent:       return Theme.accent
        case .tempGradient: return Theme.ink
        case .mono:         return .primary
        }
    }
    private var tempColor: Color {
        switch store.config.menuNumberColor {
        case .tempGradient: return Theme.temp(Double(mon.socMax))
        case .accent:       return Theme.accent
        case .mono:         return .primary
        }
    }

    var body: some View {
        Theme.accentPreset = store.config.accent
        L.lang = store.config.language
        return Image(nsImage: rendered())
            .onReceive(NotificationCenter.default.publisher(for: .openOmniSettings)) { _ in
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
    }

    private func rendered() -> NSImage {
        let cfg = store.config
        let mono = cfg.menuNumberColor == .mono
        let content = MenuBarContent(
            showNet: cfg.showNetworkInMenuBar,
            showTemp: cfg.showTempInMenuBar,
            txText: menuBarRate(net.txBps),
            rxText: menuBarRate(net.rxBps),
            tempText: mon.socMax.isNaN ? "—" : String(format: "%.0f°", mon.socMax),
            arrowColor: arrowColor, numberColor: numberColor, tempColor: tempColor)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = renderer.nsImage else { return NSImage() }
        img.isTemplate = mono   // mono → adaptive template (legible on any menu-bar tint); colored → fixed colors
        return img
    }
}

// The rasterized menu-bar readout: stacked upload/download on the left, temperature
// on the right. Rendered off-screen by ImageRenderer, so colors are passed in
// explicitly rather than read from the environment.
private struct MenuBarContent: View {
    let showNet: Bool
    let showTemp: Bool
    let txText: String
    let rxText: String
    let tempText: String
    let arrowColor: Color
    let numberColor: Color
    let tempColor: Color

    var body: some View {
        HStack(spacing: 6) {
            if showNet {
                VStack(alignment: .leading, spacing: 1) {
                    netRow("arrow.up", txText)     // upload on top
                    netRow("arrow.down", rxText)   // download below
                }
            }
            if showTemp {
                HStack(spacing: 2) {
                    Image(systemName: "thermometer.medium").font(.system(size: 11))
                    Text(tempText).font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                .foregroundStyle(tempColor)
            }
            if !showNet && !showTemp {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent").font(.system(size: 13))
                    .foregroundStyle(tempColor)
            }
        }
        .padding(.horizontal, 1)
    }

    private func netRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 7, weight: .bold)).foregroundStyle(arrowColor)
            Text(text).font(.system(size: 8.5, weight: .regular, design: .monospaced)).foregroundStyle(numberColor)
        }
    }
}
