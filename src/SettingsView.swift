import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case fans, battery, menuBar, apps, general, about
    var id: String { rawValue }
    var title: String { L.t("section.\(rawValue)") }
    var icon: String {
        switch self {
        case .fans:    return "fanblades.fill"
        case .battery: return "battery.100percent.bolt"
        case .menuBar: return "menubar.rectangle"
        case .apps:    return "trash.fill"
        case .general: return "gearshape.fill"
        case .about:   return "info.circle.fill"
        }
    }
    // Apps fills the window and scrolls its list and details on their own, so it
    // never nests a scroll view inside the page's.
    var scrolls: Bool { self != .apps }
    // Pages that lay cards out in two columns get the wider measure.
    var contentWidth: CGFloat {
        switch self {
        case .fans, .battery, .general, .apps: return Theme.wideContentMaxWidth
        case .menuBar, .about:                 return Theme.contentMaxWidth
        }
    }
}

// Set from launch args (--section) so screenshots can open a specific pane.
enum LaunchOptions { static var section: SettingsSection? }

// Keep navigation independently of the hosting tree, which is released on close.
final class SettingsState: ObservableObject {
    @Published var section: SettingsSection = .fans
}

struct SettingsView: View {
    let mon: Monitor
    @ObservedObject var store: ConfigStore
    let engine: Engine
    let updater: Updater
    let battery: BatterySampler
    let charge: ChargeController
    let menuBar: MenuBarManager?
    var uninstaller: AppUninstaller?
    @ObservedObject var state: SettingsState
    @Namespace private var selection

    // Desktop Macs have no battery pane.
    var sections: [SettingsSection] {
        SettingsSection.allCases.filter {
            ($0 != .battery || battery.isPresent) && ($0 != .menuBar || menuBar != nil) && ($0 != .apps || uninstaller != nil)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.line)
            // Each page starts at the top and fades in; one column, one width.
            ZStack {
                Group {
                    if state.section.scrolls {
                        ScrollView { page }
                    } else {
                        page.frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .id(state.section)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
        }
        .frame(minWidth: 880, idealWidth: 1060, maxWidth: .infinity,
               minHeight: 600, idealHeight: 760, maxHeight: .infinity)
        .background(Theme.bg)
        .environment(\.colorScheme, store.config.appearance.colorScheme)
        .onAppear { if let s = LaunchOptions.section { state.section = s; LaunchOptions.section = nil } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 18, height: 18)
                Text("OmniStats").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
            }.padding(.bottom, 16).padding(.horizontal, 6).padding(.top, 8)

            // Row metrics (30 pt rows, 4 pt apart) are what RuntimeTests clicks.
            ForEach(sections) { s in
                let selected = state.section == s
                Button { withAnimation(Theme.Motion.standard) { state.section = s } } label: {
                    HStack(spacing: 9) {
                        Image(systemName: s.icon).frame(width: 18)
                        Text(s.title).font(.system(size: 13, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7).padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .foregroundStyle(selected ? Theme.accent : Theme.ink2)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: Theme.Radius.control - 1, style: .continuous)
                                .fill(Theme.accent.opacity(0.16))
                                .matchedGeometryEffect(id: "selection", in: selection)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(12).frame(width: 200)
        .background(Theme.bg)
    }

    private var page: some View {
        content
            .frame(maxWidth: state.section.contentWidth, maxHeight: state.section.scrolls ? nil : .infinity, alignment: .topLeading)
            .padding(Theme.Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch state.section {
        case .fans:    FansPane(mon: mon, store: store, engine: engine)
        case .battery: BatteryPane(sampler: battery, store: store, mon: mon, charge: charge)
        case .menuBar: if let menuBar { MenuBarPane(store: store, manager: menuBar) }
        case .apps:    if let uninstaller { AppsPane(model: uninstaller) }
        case .general: GeneralPane(store: store, hasBattery: battery.isPresent)
        case .about:   AboutPane(mon: mon, store: store, updater: updater)
        }
    }
}

// MARK: - Fans / curve  (two-column: hero curve + compact controls)
struct FansPane: View {
    @ObservedObject var mon: Monitor
    @ObservedObject var store: ConfigStore
    @ObservedObject var engine: Engine
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            PageHeader(title: L.t("f.title"), subtitle: L.t("f.subtitle"))

            if mon.fanCount == 0 {
                Card(L.t("f.noFan.title"), icon: "fanblades") { Note(L.t("f.noFan.body")) }
            } else {
                if !mon.helperAvailable || mon.helperNeedsUpdate {
                    HelperCallout(mon: mon, title: L.t(mon.helperNeedsUpdate ? "control.update" : "f.enableBannerTitle"),
                                  message: L.t(mon.helperNeedsUpdate ? "control.updateBody" : "f.enableBannerBody"))
                }
                if engine.safetyPaused { Callout(.warning, message: L.t("control.sensorPaused")) }
                if let error = mon.controlError { Callout(.error, message: error) }
                modePicker
                // The curve needs the room; live speeds and tuning sit beside it.
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    mainColumn.frame(maxWidth: .infinity, alignment: .leading)
                    sideColumn.frame(width: 262)
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("", selection: Binding(get: { store.config.mode }, set: { store.config.mode = $0 })) {
            ForEach(FanMode.allCases) { m in Text(m.title).tag(m) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Theme.accent)
    }

    @ViewBuilder private var mainColumn: some View {
        switch store.config.mode {
        case .auto:   autoCard
        case .manual: manualCard
        case .curve:  curveCard
        }
    }
    private var sideColumn: some View {
        VStack(spacing: Theme.Space.l) {
            liveFans
            if store.config.mode == .curve { advancedCard }
        }
    }

    private var autoCard: some View {
        Card(L.t("f.autoTitle"), icon: "wand.and.stars") {
            Text(L.t("f.autoBody")).font(Theme.Typo.secondary).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualCard: some View {
        Card(L.t("f.manualTitle"), icon: "hand.raised.fill", accessory: {
            Text("\(Int(store.config.manualPct))%").font(Theme.telemetry(20)).foregroundStyle(Theme.accent)
        }) {
            Slider(value: Binding(get: { store.config.manualPct }, set: { store.config.manualPct = $0 }), in: 0...100)
                .tint(Theme.accent)
            Note(L.t("f.manualBody"))
        }
    }

    private var curveCard: some View {
        let driving = engine.drivingTemp.isNaN ? Double(mon.socMax) : engine.drivingTemp
        return Card {
            HStack(spacing: 6) {
                Text(L.t("f.preset")).font(Theme.Typo.caption).foregroundStyle(Theme.ink3)
                presetButton(L.t("f.presetQuiet"), OmniStatsConfig.presetQuiet)
                presetButton(L.t("f.presetBalanced"), OmniStatsConfig.presetBalanced)
                presetButton(L.t("f.presetCool"), OmniStatsConfig.presetCool)
                Spacer(minLength: Theme.Space.s)
                Text(L.t("f.dragHint")).font(Theme.Typo.caption).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            CurveEditor(points: Binding(get: { store.config.curve }, set: { store.config.curve = $0 }),
                        liveTemp: driving,
                        commandedPct: engine.commandedPct,
                        fahrenheit: store.config.fahrenheit,
                        height: 330)
            HStack(spacing: 6) {
                Circle().fill(Theme.temp(driving)).frame(width: 8, height: 8)
                Text(L.f("f.drivingTemp", fmtTemp(Float(driving), fahrenheit: store.config.fahrenheit), Int(engine.commandedPct)))
                    .font(Theme.Typo.caption).foregroundStyle(Theme.ink2)
                Spacer(minLength: Theme.Space.s)
                Text(L.t("f.operatingHint")).font(Theme.Typo.caption).foregroundStyle(Theme.ink3).lineLimit(1)
            }
        }
    }
    private func presetButton(_ title: String, _ curve: [CurvePoint]) -> some View {
        Button { store.config.curve = curve } label: { Text(title).font(Theme.Typo.caption) }.secondaryButton()
    }

    private var advancedCard: some View {
        Card {
            Button { withAnimation(Theme.Motion.standard) { showAdvanced.toggle() } } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent).frame(width: 16)
                    Text(L.t("f.advanced")).font(Theme.Typo.heading).foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                        .rotationEffect(.degrees(showAdvanced ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(L.t(showAdvanced ? "toggle.on" : "toggle.off"))

            if showAdvanced {
                rampRow(L.t("f.rampUp"), value: Binding(get: { store.config.rampUpPctPerSec }, set: { store.config.rampUpPctPerSec = $0 }), range: 2...40, unit: "%/s")
                rampRow(L.t("f.rampDown"), value: Binding(get: { store.config.rampDownPctPerSec }, set: { store.config.rampDownPctPerSec = $0 }), range: 2...40, unit: "%/s")
                rampRow(L.t("f.deadband"), value: Binding(get: { store.config.deadbandPct }, set: { store.config.deadbandPct = $0 }), range: 0...10, unit: "%")
                Note(L.t("f.advancedBody"))
                Button { restoreDefaults() } label: {
                    Label(L.t("f.restoreDefaults"), systemImage: "arrow.counterclockwise").font(Theme.Typo.caption)
                }.secondaryButton()
            } else {
                Note(L.f("f.defaultsSummary", Int(store.config.rampUpPctPerSec), Int(store.config.rampDownPctPerSec), Int(store.config.deadbandPct)))
            }
        }
    }
    private func restoreDefaults() {
        let def = OmniStatsConfig()
        store.config.rampUpPctPerSec = def.rampUpPctPerSec
        store.config.rampDownPctPerSec = def.rampDownPctPerSec
        store.config.deadbandPct = def.deadbandPct
    }
    private func rampRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(label).font(Theme.Typo.secondary).foregroundStyle(Theme.ink2)
                .lineLimit(1).fixedSize().frame(minWidth: 34, alignment: .leading)
            Slider(value: value, in: range).tint(Theme.accent)
            Text(verbatim: "\(Int(value.wrappedValue))\(unit)").font(Theme.telemetry(11)).foregroundStyle(Theme.ink2)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var liveFans: some View {
        Card(L.t("f.liveRpm"), icon: "gauge.with.dots.needle.67percent") {
            ForEach(0..<mon.fanCount, id: \.self) { i in
                let rpm = i < mon.fanRPM.count ? mon.fanRPM[i] : .nan
                let share = i < mon.fanMax.count && !rpm.isNaN && mon.fanMax[i] > 0 ? Double(rpm / mon.fanMax[i]) : nil
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(i == 0 ? L.t("m.fanLeft") : i == 1 ? L.t("m.fanRight") : L.f("m.fanN", i + 1))
                            .font(Theme.Typo.secondary).foregroundStyle(Theme.ink2)
                        Spacer()
                        // Plain digits, as in the panel (no grouping separator).
                        Text(verbatim: rpm.isNaN ? "—" : "\(Int(rpm))").font(Theme.telemetry(14)).foregroundStyle(Theme.ink)
                        Text(verbatim: "rpm").font(Theme.Typo.micro).foregroundStyle(Theme.ink3)
                        if let share {
                            Text(verbatim: String(format: "%.0f%%", share * 100)).font(Theme.telemetry(12)).foregroundStyle(Theme.accent)
                        }
                    }
                    if let share { ProgressView(value: share).tint(Theme.accent).controlSize(.small) }
                }
            }
        }
    }
}

// The one prompt to install or update the privileged helper, wherever a page needs it.
struct HelperCallout: View {
    @ObservedObject var mon: Monitor
    let title: String
    let message: String

    var body: some View {
        Callout(.action, title: title, message: message) {
            Button { mon.enableControl() } label: {
                HStack(spacing: 6) {
                    if mon.busy { ProgressView().controlSize(.small) }
                    Text(mon.busy ? L.t("m.enabling") : L.t(mon.helperNeedsUpdate ? "control.updateShort" : "f.enableShort"))
                }
            }
            .primaryButton().disabled(mon.busy)
        }
    }
}

// MARK: - General
struct GeneralPane: View {
    @ObservedObject var store: ConfigStore
    let hasBattery: Bool
    @StateObject private var loginItem = LoginItem()
    private var cfg: OmniStatsConfig { store.config }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            PageHeader(title: L.t("g.title"), subtitle: L.t("g.subtitle"))
            // Cards of similar height side by side; the sampling table takes the full width.
            Columns {
                appearanceCard
                chartsCard
            } right: {
                menuBarCard
            }
            startupCard
        }
        // The user can change the login item in System Settings while we're away.
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private var appearanceCard: some View {
        Card(L.t("g.sectionAppearance"), icon: "paintpalette.fill") {
            SettingRow(L.t("g.theme")) { segmented(\.appearance, AppearanceMode.allCases) { $0.title } }
            RowDivider()
            SettingRow(L.t("g.accent")) { accentSwatches }
            RowDivider()
            SettingRow(L.t("g.language")) {
                Picker("", selection: bind(\.language)) {
                    ForEach(AppLanguage.allCases) { l in Text(l.displayName).tag(l) }
                }.labelsHidden().fixedSize()
            }
            RowDivider()
            SettingRow(L.t("g.tempUnit")) {
                Picker("", selection: bind(\.fahrenheit)) {
                    Text("°C").tag(false); Text("°F").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize().tint(Theme.accent)
            }
        }
    }

    private var menuBarCard: some View {
        Card(L.t("g.sectionMenubar"), icon: "menubar.rectangle") {
            ToggleRow(L.t("g.showTemp"), isOn: bind(\.showTempInMenuBar))
            RowDivider()
            ToggleRow(L.t("g.showNetwork"), isOn: bind(\.showNetworkInMenuBar))
            RowDivider()
            SettingRow(L.t("g.numberColor")) { segmented(\.menuNumberColor, MenuNumberColorMode.allCases) { $0.title } }
            RowDivider()
            ToggleRow(L.t("g.showNetworkPanel"), isOn: bind(\.showNetworkPanel))
            RowDivider()
            ToggleRow(L.t("g.showProcesses"), isOn: bind(\.showProcesses))
            if hasBattery {
                RowDivider()
                ToggleRow(L.t("g.showBatteryPanel"), isOn: bind(\.showBatteryPanel))
            }
            RowDivider()
            SettingRow(L.t("g.cpuWindow")) { segmented(\.cpuWindow, CPUWindow.allCases) { $0.title } }
        }
    }

    private var chartsCard: some View {
        Card(L.t("g.sectionCharts"), icon: "chart.xyaxis.line") {
            SettingRow(L.t("g.topWidgetStyle")) { segmented(\.topWidgetStyle, TopWidgetStyle.allCases) { $0.title } }
            if cfg.topWidgetStyle.isChart {
                RowDivider()
                SettingRow(L.t("g.topWidgetWindow")) { segmented(\.topWidgetWindow, ChartWindow.allCases) { $0.title } }
            }
            RowDivider()
            SettingRow(L.t("g.netChartKind")) { segmented(\.netChartKind, ChartKind.allCases) { $0.title } }
        }
    }

    private var startupCard: some View {
        Card(L.t("g.sectionStartup"), icon: "power") {
            startupRows
            RowDivider()
            SettingRow(L.t("refresh.mode")) { segmented(\.refreshMode, RefreshMode.allCases) { $0.title } }
            refreshTable.frame(maxWidth: 560, alignment: .leading)   // compact rows read across easily
            Note(L.t("refresh.body"))
        }
    }

    // Turning the item off stays possible from anywhere; turning it on needs an
    // installed copy, so a stale DMG/Downloads path never ends up as a login item.
    @ViewBuilder private var startupRows: some View {
        let blocked = !loginItem.canRegister && !loginItem.isOn
        ToggleRow(L.t("g.launchAtLogin"), isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setEnabled($0) }))
            .disabled(blocked)
        if blocked {
            Note(L.t("g.loginNeedsApplications"))
        } else if loginItem.needsApproval {
            Callout(.warning, message: L.t("g.loginApproval")) {
                Button(L.t("g.openLoginItems")) { loginItem.openSystemSettings() }.secondaryButton()
            }
        }
        if let error = loginItem.lastError { Callout(.error, message: L.f("g.loginFailed", error)) }
    }

    // The three refresh modes side by side, the one in use highlighted.
    private var refreshTable: some View {
        let columns = [L.t("refresh.colSensors"), L.t("refresh.colNetwork"), L.t("refresh.colProcesses")]
        return VStack(spacing: 2) {
            HStack(spacing: Theme.Space.s) {
                Color.clear.frame(width: 88, height: 1)
                ForEach(columns, id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .trailing) }
            }
            .font(Theme.Typo.caption).foregroundStyle(Theme.ink3).padding(.horizontal, Theme.Space.s)
            ForEach(RefreshMode.allCases) { mode in
                let on = mode == cfg.refreshMode
                let i = mode.intervals
                HStack(spacing: Theme.Space.s) {
                    Text(mode.title).frame(width: 88, alignment: .leading)
                    ForEach(Array([i.sensors, i.network, i.processes].enumerated()), id: \.offset) { _, seconds in
                        Text(L.f("refresh.seconds", Int(seconds))).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .font(on ? Theme.Typo.secondary.weight(.semibold) : Theme.Typo.secondary)
                .foregroundStyle(on ? Theme.accent : Theme.ink2)
                .padding(.vertical, 5).padding(.horizontal, Theme.Space.s)
                .background(on ? Theme.accent.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .animation(Theme.Motion.quick, value: on)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .monospacedDigit()
    }

    private var accentSwatches: some View {
        HStack(spacing: 10) {
            ForEach(AccentPreset.allCases) { a in
                let on = cfg.accent == a
                Button { withAnimation(Theme.Motion.quick) { store.config.accent = a } } label: {
                    Circle().fill(a.swatch).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().stroke(Theme.ink, lineWidth: on ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help(a.title)
                .accessibilityLabel(a.title)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }

    // MARK: layout helpers
    private func bind<T>(_ kp: WritableKeyPath<OmniStatsConfig, T>) -> Binding<T> {
        Binding(get: { store.config[keyPath: kp] }, set: { store.config[keyPath: kp] = $0 })
    }
    // Segments size to their labels, so no language gets clipped.
    private func segmented<T: Hashable & Identifiable>(_ kp: WritableKeyPath<OmniStatsConfig, T>, _ options: [T],
                                                       title: @escaping (T) -> String) -> some View {
        Picker("", selection: bind(kp)) {
            ForEach(options) { option in Text(title(option)).tag(option) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Theme.accent)
    }
}

// MARK: - About
struct AboutPane: View {
    @ObservedObject var mon: Monitor
    @ObservedObject var store: ConfigStore
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            PageHeader(title: L.t("a.title"), subtitle: L.t("a.subtitle"))
            hero
            Card(L.t("a.softwareUpdate"), icon: "arrow.triangle.2.circlepath", accessory: {
                // Sparkle presents its own found-update / download / install dialogs.
                Button(L.t("a.checkNow")) { updater.checkForUpdates() }
                    .secondaryButton().disabled(!updater.canCheckForUpdates)
            }) {
                ToggleRow(L.t("a.autoCheck"), isOn: Binding(get: { updater.automaticallyChecksForUpdates },
                                                            set: { updater.automaticallyChecksForUpdates = $0 }))
                RowDivider()
                ToggleRow(L.t("a.autoDownload"), isOn: Binding(get: { updater.automaticallyDownloadsUpdates },
                                                               set: { updater.automaticallyDownloadsUpdates = $0 }))
                    .disabled(!updater.automaticallyChecksForUpdates)
            }
            components
            Note(L.t("a.license"))
        }
    }

    private var hero: some View {
        Card {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: Theme.Space.s) {
                        Text("OmniStats").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.ink)
                        Badge(text: L.f("a.versionBadge", updater.currentVersion))
                    }
                    Text(L.t("a.body")).font(Theme.Typo.secondary).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            RowDivider()
            HStack(spacing: Theme.Space.s) {
                link(L.t("a.githubRepo"), "chevron.left.forwardslash.chevron.right", Repo.url)
                link(L.t("a.releases"), "tag.fill", Repo.releasesURL)
                link(L.t("a.issues"), "exclamationmark.bubble.fill", Repo.issuesURL)
                link(L.t("a.licenseLink"), "doc.text.fill", Repo.licenseURL)
            }
        }
    }

    // The helper is shared by fan control and battery management, so its state,
    // update and removal live here rather than on either page.
    private var components: some View {
        Card(L.t("a.components"), icon: "lock.shield.fill") {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Space.s) {
                        Text(L.t("a.helper")).font(Theme.Typo.body).foregroundStyle(Theme.ink)
                        helperBadge
                    }
                    Note(L.t("a.helperDetail"))
                }
                .layoutPriority(1)
                Spacer(minLength: Theme.Space.s)
                if mon.busy {
                    ProgressView().controlSize(.small)
                } else {
                    if !mon.helperAvailable || mon.helperNeedsUpdate {
                        Button(L.t(mon.helperNeedsUpdate ? "control.updateShort" : "a.helperInstall")) { mon.enableControl() }
                            .primaryButton()
                    }
                    if mon.helperAvailable {
                        ConfirmButton(title: L.t("a.removeHelper"), icon: "trash", confirmTitle: L.t("a.removeConfirmTitle"),
                                      message: L.t("a.removeConfirmBody")) { mon.disableControl() }
                    }
                }
            }
            if let error = mon.controlError { Callout(.error, message: error) }
        }
    }

    @ViewBuilder private var helperBadge: some View {
        if !mon.helperAvailable {
            Badge(text: L.t("a.helperMissing"), icon: "minus", tint: Theme.ink3)
        } else if mon.helperNeedsUpdate {
            Badge(text: L.t("a.helperOutdated"), icon: "arrow.up", tint: Theme.warning)
        } else {
            Badge(text: L.t("a.helperInstalled"), icon: "checkmark", tint: Theme.success)
        }
    }

    private func link(_ title: String, _ icon: String, _ url: String) -> some View {
        Button { updater.open(url) } label: { Label(title, systemImage: icon) }.secondaryButton()
    }
}
