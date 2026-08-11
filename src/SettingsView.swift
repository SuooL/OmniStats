import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case fans, general, about
    var id: String { rawValue }
    var title: String { self == .fans ? L.t("section.fans") : self == .general ? L.t("section.general") : L.t("section.about") }
    var icon: String { self == .fans ? "fanblades.fill" : self == .general ? "gearshape.fill" : "info.circle.fill" }
}

// Set from launch args (--section) so screenshots can open a specific pane.
enum LaunchOptions { static var section: SettingsSection? }

struct SettingsView: View {
    @ObservedObject var mon: Monitor
    @ObservedObject var store: ConfigStore
    let engine: Engine
    let updater: Updater
    @State private var section: SettingsSection = LaunchOptions.section ?? .fans

    var body: some View {
        syncPresentation(store.config)
        return HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.line)
            ScrollView {
                content.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
        }
        .frame(minWidth: 880, idealWidth: 960, maxWidth: .infinity,
               minHeight: 600, idealHeight: 660, maxHeight: .infinity)
        .background(Theme.bg)
        .environment(\.colorScheme, store.config.appearance.colorScheme)
        .onAppear { if let s = LaunchOptions.section { section = s; LaunchOptions.section = nil } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "thermometer.sun.fill").foregroundStyle(Theme.accent)
                Text("OmniStats").font(.system(size: 15, weight: .bold))
            }.padding(.bottom, 16).padding(.horizontal, 6).padding(.top, 8)

            ForEach(SettingsSection.allCases) { s in
                Button { section = s } label: {
                    HStack(spacing: 9) {
                        Image(systemName: s.icon).frame(width: 18)
                        Text(s.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(.vertical, 7).padding(.horizontal, 8)
                    .background(section == s ? Theme.accent.opacity(0.16) : .clear)
                    .foregroundStyle(section == s ? Theme.accent : Theme.ink2)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12).frame(width: 168)
        .background(Theme.bg)
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .fans:    FansPane(mon: mon, store: store, engine: engine)
        case .general: GeneralPane(store: store)
        case .about:   AboutPane(mon: mon, store: store, updater: updater)
        }
    }
}

// MARK: - Fans / curve  (two-column: hero curve + compact controls)
struct FansPane: View {
    @ObservedObject var mon: Monitor
    @ObservedObject var store: ConfigStore
    let engine: Engine
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header(L.t("f.title"), L.t("f.subtitle"))

            if mon.fanCount == 0 {
                infoCard(L.t("f.noFan.title"), L.t("f.noFan.body"))
            } else {
                if !mon.helperAvailable { enableBanner }
                modePicker
                HStack(alignment: .top, spacing: 18) {
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
        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
    }

    @ViewBuilder private var mainColumn: some View {
        switch store.config.mode {
        case .auto:   autoCard
        case .manual: manualCard
        case .curve:  curveCard
        }
    }
    private var sideColumn: some View {
        VStack(spacing: 14) {
            liveFans
            if store.config.mode == .curve { advancedCard }
        }
    }

    private var autoCard: some View {
        card {
            Label(L.t("f.autoTitle"), systemImage: "cpu").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(L.t("f.autoBody"))
                .font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualCard: some View {
        card {
            HStack {
                Text(L.t("f.manualTitle")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(Int(store.config.manualPct))%").font(Theme.telemetry(20)).foregroundStyle(Theme.accent)
            }
            Slider(value: Binding(get: { store.config.manualPct }, set: { store.config.manualPct = $0 }), in: 0...100)
                .tint(Theme.accent)
            Text(L.t("f.manualBody"))
                .font(.system(size: 11)).foregroundStyle(Theme.ink3)
        }
    }

    private var curveCard: some View {
        let driving = engine.drivingTemp.isNaN ? Double(mon.socMax) : engine.drivingTemp
        return card {
            HStack(spacing: 6) {
                Text(L.t("f.preset")).font(.system(size: 11)).foregroundStyle(Theme.ink3)
                presetButton(L.t("f.presetQuiet"), OmniStatsConfig.presetQuiet)
                presetButton(L.t("f.presetBalanced"), OmniStatsConfig.presetBalanced)
                presetButton(L.t("f.presetCool"), OmniStatsConfig.presetCool)
                Spacer()
                Text(L.t("f.dragHint")).font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
            CurveEditor(points: Binding(get: { store.config.curve }, set: { store.config.curve = $0 }),
                        liveTemp: driving,
                        commandedPct: engine.commandedPct,
                        fahrenheit: store.config.fahrenheit,
                        height: 330)
            HStack(spacing: 6) {
                Circle().fill(Theme.temp(driving)).frame(width: 8, height: 8)
                Text(L.f("f.drivingTemp", fmtTemp(Float(driving), fahrenheit: store.config.fahrenheit), Int(engine.commandedPct)))
                    .font(.system(size: 11)).foregroundStyle(Theme.ink2)
                Spacer()
                Text(L.t("f.operatingHint")).font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
        }
    }
    private func presetButton(_ title: String, _ curve: [CurvePoint]) -> some View {
        Button { store.config.curve = curve } label: { Text(title).font(.system(size: 11)) }
            .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
    }

    private var advancedCard: some View {
        card {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(Theme.accent)
                    Text(L.t("f.advanced")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
            }.buttonStyle(.plain)

            if showAdvanced {
                rampRow(L.t("f.rampUp"), value: Binding(get: { store.config.rampUpPctPerSec }, set: { store.config.rampUpPctPerSec = $0 }), range: 2...40, unit: "%/s")
                rampRow(L.t("f.rampDown"), value: Binding(get: { store.config.rampDownPctPerSec }, set: { store.config.rampDownPctPerSec = $0 }), range: 2...40, unit: "%/s")
                rampRow(L.t("f.deadband"), value: Binding(get: { store.config.deadbandPct }, set: { store.config.deadbandPct = $0 }), range: 0...10, unit: "%")
                Text(L.t("f.advancedBody"))
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                Button { restoreDefaults() } label: {
                    Label(L.t("f.restoreDefaults"), systemImage: "arrow.counterclockwise").font(.system(size: 11))
                }.buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
            } else {
                Text(L.f("f.defaultsSummary", Int(store.config.rampUpPctPerSec), Int(store.config.rampDownPctPerSec), Int(store.config.deadbandPct)))
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3)
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
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                .lineLimit(1).fixedSize().frame(minWidth: 34, alignment: .leading)
            Slider(value: value, in: range).tint(Theme.accent)
            Text("\(Int(value.wrappedValue))\(unit)").font(Theme.telemetry(11)).foregroundStyle(Theme.ink2).frame(width: 46, alignment: .trailing)
        }
    }

    private var liveFans: some View {
        card {
            Text(L.t("f.liveRpm")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            ForEach(0..<mon.fanCount, id: \.self) { i in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(i == 0 ? L.t("m.fanLeft") : i == 1 ? L.t("m.fanRight") : L.f("m.fanN", i + 1))
                            .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                        Spacer()
                        Text(i < mon.fanRPM.count && !mon.fanRPM[i].isNaN ? "\(Int(mon.fanRPM[i]))" : "—")
                            .font(Theme.telemetry(14)).foregroundStyle(Theme.ink)
                        Text("rpm").font(.system(size: 9)).foregroundStyle(Theme.ink3)
                        if i < mon.fanRPM.count, i < mon.fanMax.count, !mon.fanRPM[i].isNaN, mon.fanMax[i] > 0 {
                            Text(String(format: "%.0f%%", Double(mon.fanRPM[i] / mon.fanMax[i]) * 100))
                                .font(Theme.telemetry(12)).foregroundStyle(Theme.accent)
                        }
                    }
                    if i < mon.fanRPM.count, i < mon.fanMax.count, !mon.fanRPM[i].isNaN, mon.fanMax[i] > 0 {
                        ProgressView(value: Double(mon.fanRPM[i] / mon.fanMax[i])).tint(Theme.accent).controlSize(.small)
                    }
                }
            }
        }
    }

    private var enableBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L.t("f.enableBannerTitle")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(L.t("f.enableBannerBody")).font(.system(size: 11)).foregroundStyle(Theme.ink2)
            }
            Spacer()
            Button { mon.enableControl() } label: {
                HStack { if mon.busy { ProgressView().controlSize(.small) }; Text(mon.busy ? L.t("m.enabling") : L.t("f.enableShort")) }
            }.buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small).disabled(mon.busy)
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(Theme.accent.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.4), lineWidth: 1))
    }

    // helpers
    private func header(_ t: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.ink)
            Text(s).font(.system(size: 12)).foregroundStyle(Theme.ink3)
        }
    }
    private func infoCard(_ t: String, _ s: String) -> some View {
        card {
            Text(t).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            Text(s).font(.system(size: 12)).foregroundStyle(Theme.ink2)
        }
    }
    @ViewBuilder private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: 7, y: 2)
    }
}

// MARK: - General
struct GeneralPane: View {
    @ObservedObject var store: ConfigStore
    private var cfg: OmniStatsConfig { store.config }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("g.title")).font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(L.t("g.subtitle")).font(.system(size: 12)).foregroundStyle(Theme.ink3)
                }

                // Display, language & colors
                cardSection(L.t("g.sectionDisplay")) {
                    row(L.t("g.language")) {
                        Picker("", selection: bind(\.language)) {
                            ForEach(AppLanguage.allCases) { l in Text(l.displayName).tag(l) }
                        }.labelsHidden().frame(width: 160)
                    }
                    Divider().overlay(Theme.line)
                    row(L.t("g.theme")) {
                        Picker("", selection: bind(\.appearance)) {
                            ForEach(AppearanceMode.allCases) { m in Text(m.title).tag(m) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                    }
                    Divider().overlay(Theme.line)
                    row(L.t("g.tempUnit")) {
                        Picker("", selection: bind(\.fahrenheit)) {
                            Text("°C").tag(false); Text("°F").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 96)
                    }
                    Divider().overlay(Theme.line)
                    row(L.t("g.accent")) { accentSwatches }
                    Divider().overlay(Theme.line)
                    row(L.t("g.numberColor")) {
                        Picker("", selection: bind(\.menuNumberColor)) {
                            ForEach(MenuNumberColorMode.allCases) { m in Text(m.title).tag(m) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    }
                }

                // Menu bar & panel visibility
                cardSection(L.t("g.sectionMenubar")) {
                    toggleRow(L.t("g.showTemp"), bind(\.showTempInMenuBar))
                    Divider().overlay(Theme.line)
                    toggleRow(L.t("g.showNetwork"), bind(\.showNetworkInMenuBar))
                    Divider().overlay(Theme.line)
                    toggleRow(L.t("g.showNetworkPanel"), bind(\.showNetworkPanel))
                    Divider().overlay(Theme.line)
                    toggleRow(L.t("g.showProcesses"), bind(\.showProcesses))
                    Divider().overlay(Theme.line)
                    row(L.t("g.cpuWindow")) {
                        Picker("", selection: bind(\.cpuWindow)) {
                            ForEach(CPUWindow.allCases) { w in Text(w.title).tag(w) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var accentSwatches: some View {
        HStack(spacing: 10) {
            ForEach(AccentPreset.allCases) { a in
                Button { store.config.accent = a } label: {
                    Circle().fill(a.swatch).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white, lineWidth: cfg.accent == a ? 2 : 0))
                        .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                        .shadow(color: a.swatch.opacity(cfg.accent == a ? 0.6 : 0), radius: 4)
                }
                .buttonStyle(.plain)
                .help(a.title)
            }
        }
    }

    // MARK: layout helpers
    private func bind<T>(_ kp: WritableKeyPath<OmniStatsConfig, T>) -> Binding<T> {
        Binding(get: { store.config[keyPath: kp] }, set: { store.config[keyPath: kp] = $0 })
    }
    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack { Text(label).font(.system(size: 13)).foregroundStyle(Theme.ink); Spacer(); control() }
    }
    private func toggleRow(_ label: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) { Text(label).font(.system(size: 13)).foregroundStyle(Theme.ink) }
            .toggleStyle(.switch).tint(Theme.accent)
    }
    @ViewBuilder private func cardSection<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(16).frame(maxWidth: 520, alignment: .leading)
                .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
                .shadow(color: Theme.cardShadow, radius: 7, y: 2)
        }
    }
}

// MARK: - About
struct AboutPane: View {
    @ObservedObject var mon: Monitor
    @ObservedObject var store: ConfigStore
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L.t("a.title")).font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.ink)
                Text(L.f("a.subtitle", updater.currentVersion)).font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }

            aboutCard {
                Text(L.t("a.body"))
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { updater.openRepo() } label: {
                        Label(L.t("a.githubRepo"), systemImage: "chevron.left.forwardslash.chevron.right")
                    }.buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                    Text(Repo.url).font(.system(size: 11)).foregroundStyle(Theme.ink3).textSelection(.enabled)
                }
            }

            aboutCard {
                Text(L.t("a.softwareUpdate")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Toggle(isOn: Binding(get: { updater.automaticallyChecksForUpdates }, set: { updater.automaticallyChecksForUpdates = $0 })) {
                    Text(L.t("a.autoCheck")).font(.system(size: 12)).foregroundStyle(Theme.ink)
                }.toggleStyle(.switch).tint(Theme.accent)
                Toggle(isOn: Binding(get: { updater.automaticallyDownloadsUpdates }, set: { updater.automaticallyDownloadsUpdates = $0 })) {
                    Text(L.t("a.autoDownload")).font(.system(size: 12)).foregroundStyle(Theme.ink)
                }.toggleStyle(.switch).tint(Theme.accent).disabled(!updater.automaticallyChecksForUpdates)

                // Sparkle presents its own found-update / download / install dialogs.
                HStack(spacing: 10) {
                    Button { updater.checkForUpdates() } label: { Text(L.t("a.checkNow")) }
                        .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                        .disabled(!updater.canCheckForUpdates)
                    Text(L.f("a.currentVersion", updater.currentVersion)).font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
            }

            aboutCard {
                if mon.helperAvailable {
                    Button(role: .destructive) { mon.disableControl() } label: {
                        Label(L.t("a.removeHelper"), systemImage: "trash")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                Text(L.t("a.license")).font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
            Spacer()
        }
    }

    @ViewBuilder private func aboutCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16).frame(maxWidth: 560, alignment: .leading)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: 7, y: 2)
    }
}
