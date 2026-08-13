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
    @ObservedObject var netProc: NetProcSampler
    @Environment(\.openWindow) private var openWindow
    @State private var netExpanded = false

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
        netProc.enabled = store.config.showNetworkPanel && netExpanded
        return VStack(alignment: .leading, spacing: 13) {
            topCluster

            divider
            telem(L.t("m.socAvg"), fmtTemp(mon.socAvg, fahrenheit: f), Theme.temp(Double(mon.socAvg)))
            telem(L.t("m.battery"), fmtTemp(mon.battery, fahrenheit: f), Theme.temp(Double(mon.battery)))
            if !mon.power.isNaN { telem(L.t("m.power"), String(format: "%.1f W", mon.power), Theme.accent) }
            if !mon.volt.isNaN { telem(L.t("m.voltage"), String(format: "%.2f V", mon.volt), Theme.accent) }

            if mon.fanCount > 0 {
                divider
                ForEach(0..<mon.fanCount, id: \.self) { i in
                    let rpm = i < mon.fanRPM.count && !mon.fanRPM[i].isNaN ? "\(Int(mon.fanRPM[i])) rpm" : "—"
                    let pct = fanPct(i).map { String(format: " · %.0f%%", $0) } ?? ""
                    telem(fanName(i), rpm + pct, Theme.accent)
                }
            }

            if store.config.showProcesses { processSection }

            // Network sits below the CPU/process section; the row expands in place.
            if store.config.showNetworkPanel { networkSection }

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
        // Report an exact vertical size so MenuBarExtra(.window) resizes its host
        // window to fit; without this, in-place expansion leaves the window sized
        // to a stale height and the transparent menu material shows through.
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface)
        .environment(\.colorScheme, store.config.appearance.colorScheme)
        // Collapse (and stop the nettop child) when the popover closes; `body`
        // isn't guaranteed to re-run on dismissal, so tear down directly here.
        .onDisappear { netExpanded = false; netProc.enabled = false }
    }

    // Top SoC/SSD/Fans cluster: ring gauges (per-metric) or, for the chart styles,
    // one shared-coordinate time-series with a colored series per metric.
    @ViewBuilder private var topCluster: some View {
        if store.config.topWidgetStyle == .ring {
            HStack(spacing: 14) {
                Ring(value: tempFrac(mon.socMax), title: "SoC", label: fmtTemp(mon.socMax, fahrenheit: f),
                     color: Theme.temp(Double(mon.socMax)))
                Ring(value: tempFrac(mon.ssd), title: "SSD", label: fmtTemp(mon.ssd, fahrenheit: f),
                     color: Theme.temp(Double(mon.ssd)))
                if mon.fanCount > 0 {
                    Ring(value: fanFrac, title: "FANS", label: String(format: "%.0f%%", fanFrac*100),
                         color: Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            combinedChart
        }
    }

    // The unified line/bars chart: SoC/SSD/FANS overlaid on a single 0–100 scale,
    // each in a fixed series color, with a legend carrying the live values.
    private var combinedChart: some View {
        let now = CFAbsoluteTimeGetCurrent()
        let win = store.config.topWidgetWindow.seconds
        let kind: ChartKind = store.config.topWidgetStyle == .bars ? .bars : .line
        var series: [MultiSparkline.Series] = [
            .init(id: 0, samples: mon.socHistory.samples, color: Theme.series(0)),
            .init(id: 1, samples: mon.ssdHistory.samples, color: Theme.series(1)),
        ]
        if mon.fanCount > 0 {
            series.append(.init(id: 2, samples: mon.fanHistory.samples, color: Theme.series(2)))
        }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                legendItem("SoC", fmtTemp(mon.socMax, fahrenheit: f), Theme.series(0))
                legendItem("SSD", fmtTemp(mon.ssd, fahrenheit: f), Theme.series(1))
                if mon.fanCount > 0 {
                    legendItem("FANS", String(format: "%.0f%%", fanFrac*100), Theme.series(2))
                }
                Spacer()
            }
            MultiSparkline(series: series, windowSeconds: win, now: now, yRange: 0...100, kind: kind)
                .frame(height: 66)
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
    }
    private func legendItem(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
            Text(value).font(Theme.telemetry(11, .bold)).foregroundStyle(color)
        }
    }

    // Network: a tappable row (upload/download for the most active interface).
    // Tapping expands, in place, a 1h up/down history chart + the top network
    // apps; tapping again collapses. No separate window.
    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            divider
            // No withAnimation: MenuBarExtra(.window) can't resize its host window
            // in step with an interpolating height, which desyncs the window frame
            // from the content (misposition + transparent bands). Toggle instantly.
            Button { netExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text(L.t("m.network")).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    if !net.iface.isEmpty {
                        Text(net.iface).font(.system(size: 10)).foregroundStyle(Theme.ink3)
                    }
                    Spacer()
                    netStat("arrow.up", net.txBps)
                    netStat("arrow.down", net.rxBps)
                    Image(systemName: netExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9)).foregroundStyle(Theme.ink3)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            if netExpanded {
                DualSparkline(up: net.txHistory.samples, down: net.rxHistory.samples,
                              windowSeconds: 3600, now: CFAbsoluteTimeGetCurrent(),
                              kind: store.config.netChartKind)
                netProcList
            }
        }
    }
    private func netStat(_ icon: String, _ rate: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.speed(rate))
            Text(humanRate(rate)).font(Theme.telemetry(12)).foregroundStyle(Theme.speed(rate))
        }
    }

    // Top processes by network throughput, merged per app (nettop-backed).
    private var netProcList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L.t("m.netProcHeader")).font(.system(size: 11)).foregroundStyle(Theme.ink2)
            if netProc.top.isEmpty {
                Text(L.t("m.netIdle")).font(.system(size: 11)).foregroundStyle(Theme.ink3)
            } else {
                ForEach(netProc.top) { p in
                    HStack(spacing: 6) {
                        Text(p.name).font(.system(size: 11)).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        netMini("arrow.up", p.txBps)
                        netMini("arrow.down", p.rxBps)
                    }
                }
            }
        }
    }
    private func netMini(_ icon: String, _ rate: Double) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.speed(rate))
            Text(humanRate(rate)).font(Theme.telemetry(10)).foregroundStyle(Theme.speed(rate))
        }.frame(width: 74, alignment: .trailing)
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

    // Per-direction network color. In tempGradient mode the up/down figures are
    // tinted by their live rate (same thermal language as the panel), not left
    // white — so "follow temperature" colors every number, not just the temp.
    private func netColor(_ rate: Double) -> Color {
        switch store.config.menuNumberColor {
        case .tempGradient: return Theme.speed(rate)
        case .accent:       return Theme.accent
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
            txColor: netColor(net.txBps), rxColor: netColor(net.rxBps), tempColor: tempColor)
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
    let txColor: Color
    let rxColor: Color
    let tempColor: Color

    var body: some View {
        HStack(spacing: 6) {
            if showNet {
                VStack(alignment: .leading, spacing: 1) {
                    netRow("arrow.up", txText, txColor)     // upload on top
                    netRow("arrow.down", rxText, rxColor)   // download below
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

    private func netRow(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 7, weight: .bold)).foregroundStyle(color)
            Text(text).font(.system(size: 8.5, weight: .regular, design: .monospaced)).foregroundStyle(color)
        }
    }
}
