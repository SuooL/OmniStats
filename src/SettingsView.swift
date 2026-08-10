import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case fans, general, about
    var id: String { rawValue }
    var title: String { self == .fans ? "风扇" : self == .general ? "通用" : "关于" }
    var icon: String { self == .fans ? "fanblades.fill" : self == .general ? "gearshape.fill" : "info.circle.fill" }
}

struct SettingsView: View {
    @ObservedObject var mon: Monitor
    @ObservedObject var store: ConfigStore
    let engine: Engine
    let updater: Updater
    @State private var section: SettingsSection = .fans

    var body: some View {
        Theme.mode = store.config.appearance
        applyAppChrome(store.config.appearance)
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
            header("风扇控制", "温度驱动的转速策略 · 渐进调速,不伤硬件")

            if mon.fanCount == 0 {
                infoCard("本机没有风扇", "如 MacBook Air 采用无风扇被动散热,仅提供温度监控。")
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
            Label("固件自动控制", systemImage: "cpu").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("交回 macOS 固件的散热策略,风扇随负载与温度自动调节。切到「手动」或「曲线」即可接管。")
                .font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualCard: some View {
        card {
            HStack {
                Text("固定转速").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(Int(store.config.manualPct))%").font(Theme.telemetry(20)).foregroundStyle(Theme.accent)
            }
            Slider(value: Binding(get: { store.config.manualPct }, set: { store.config.manualPct = $0 }), in: 0...100)
                .tint(Theme.accent)
            Text("按各风扇量程的百分比换算,自动适配左右风扇不同上限。")
                .font(.system(size: 11)).foregroundStyle(Theme.ink3)
        }
    }

    private var curveCard: some View {
        let driving = engine.drivingTemp.isNaN ? Double(mon.socMax) : engine.drivingTemp
        return card {
            HStack(spacing: 6) {
                Text("预设").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                presetButton("静音", OmniStatsConfig.presetQuiet)
                presetButton("均衡", OmniStatsConfig.presetBalanced)
                presetButton("高性能", OmniStatsConfig.presetCool)
                Spacer()
                Text("拖拽控制点微调").font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
            CurveEditor(points: Binding(get: { store.config.curve }, set: { store.config.curve = $0 }),
                        liveTemp: driving,
                        commandedPct: engine.commandedPct,
                        fahrenheit: store.config.fahrenheit,
                        height: 330)
            HStack(spacing: 6) {
                Circle().fill(Theme.temp(driving)).frame(width: 8, height: 8)
                Text("驱动温度 \(fmtTemp(Float(driving), fahrenheit: store.config.fahrenheit)) → 目标转速 \(Int(engine.commandedPct))%")
                    .font(.system(size: 11)).foregroundStyle(Theme.ink2)
                Spacer()
                Text("光点=当前工作点").font(.system(size: 11)).foregroundStyle(Theme.ink3)
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
                    Text("高级配置").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
            }.buttonStyle(.plain)

            if showAdvanced {
                rampRow("升速", value: Binding(get: { store.config.rampUpPctPerSec }, set: { store.config.rampUpPctPerSec = $0 }), range: 2...40, unit: "%/s")
                rampRow("降速", value: Binding(get: { store.config.rampDownPctPerSec }, set: { store.config.rampDownPctPerSec = $0 }), range: 2...40, unit: "%/s")
                rampRow("抖动抑制", value: Binding(get: { store.config.deadbandPct }, set: { store.config.deadbandPct = $0 }), range: 0...10, unit: "%")
                Text("温度已平滑过滤尖峰;目标变化小于「抖动抑制」不调整;升/降速限制每秒最大变化,渐进不瞬跳。")
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                Button { restoreDefaults() } label: {
                    Label("还原推荐默认", systemImage: "arrow.counterclockwise").font(.system(size: 11))
                }.buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
            } else {
                Text("已使用推荐默认值 · 升速 \(Int(store.config.rampUpPctPerSec)) / 降速 \(Int(store.config.rampDownPctPerSec)) / 抖动 \(Int(store.config.deadbandPct))")
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
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.ink2).frame(width: 34, alignment: .leading)
            Slider(value: value, in: range).tint(Theme.accent)
            Text("\(Int(value.wrappedValue))\(unit)").font(Theme.telemetry(11)).foregroundStyle(Theme.ink2).frame(width: 46, alignment: .trailing)
        }
    }

    private var liveFans: some View {
        card {
            Text("实时转速").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            ForEach(0..<mon.fanCount, id: \.self) { i in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(i == 0 ? "左风扇" : i == 1 ? "右风扇" : "风扇\(i+1)").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                        Spacer()
                        Text(i < mon.fanRPM.count && !mon.fanRPM[i].isNaN ? "\(Int(mon.fanRPM[i]))" : "—")
                            .font(Theme.telemetry(14)).foregroundStyle(Theme.ink)
                        Text("rpm").font(.system(size: 9)).foregroundStyle(Theme.ink3)
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
                Text("风扇控制未启用").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("可先设计曲线;点击授权一次安装 root 助手后即生效。").font(.system(size: 11)).foregroundStyle(Theme.ink2)
            }
            Spacer()
            Button { mon.enableControl() } label: {
                HStack { if mon.busy { ProgressView().controlSize(.small) }; Text(mon.busy ? "正在启用…" : "启用…") }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("通用").font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.ink)
                Text("显示与单位").font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("主题").font(.system(size: 13)).foregroundStyle(Theme.ink)
                    Spacer()
                    Picker("", selection: Binding(get: { store.config.appearance }, set: { store.config.appearance = $0 })) {
                        ForEach(AppearanceMode.allCases) { m in Text(m.title).tag(m) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                }
                Divider().overlay(Theme.line)
                HStack {
                    Text("温度单位").font(.system(size: 13)).foregroundStyle(Theme.ink)
                    Spacer()
                    Picker("", selection: Binding(get: { store.config.fahrenheit }, set: { store.config.fahrenheit = $0 })) {
                        Text("°C").tag(false); Text("°F").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 96)
                }
            }
            .padding(16).frame(maxWidth: 520, alignment: .leading)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: 7, y: 2)
            Spacer()
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
                Text("关于").font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.ink)
                Text("OmniStats \(updater.currentVersion) · Apple Silicon 系统监控").font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }

            aboutCard {
                Text("OmniStats 是一套轻量的 Apple Silicon 菜单栏系统监控工具。当前提供温度监控与风扇控制:温度取自 HID 传感器,风扇经 SMC 控制,采用温度平滑 + 限斜率渐进调速,并带安全看门狗。")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { updater.openRepo() } label: {
                        Label("GitHub 仓库", systemImage: "chevron.left.forwardslash.chevron.right")
                    }.buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                    Text(Repo.url).font(.system(size: 11)).foregroundStyle(Theme.ink3).textSelection(.enabled)
                }
            }

            aboutCard {
                Text("软件更新").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Toggle(isOn: Binding(get: { store.config.autoCheckUpdates }, set: { store.config.autoCheckUpdates = $0 })) {
                    Text("自动检查更新(每天一次)").font(.system(size: 12)).foregroundStyle(Theme.ink)
                }.toggleStyle(.switch).tint(Theme.accent)

                HStack(spacing: 10) {
                    Button { updater.check() } label: {
                        HStack { if updater.checking { ProgressView().controlSize(.small) }; Text("立即检查") }
                    }.buttonStyle(.bordered).controlSize(.small).tint(Theme.accent).disabled(updater.checking)
                    Text("当前版本 \(updater.currentVersion)").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                    if !updater.status.isEmpty {
                        Text(updater.status).font(.system(size: 11)).foregroundStyle(updater.updateAvailable ? Theme.accent : Theme.ink3)
                    }
                }
                if updater.updateAvailable {
                    HStack(spacing: 10) {
                        Button { updater.installUpdate() } label: { Label("下载并安装", systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.accent)
                        Button { updater.openReleasePage() } label: { Text("查看发布说明") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }

            aboutCard {
                if mon.helperAvailable {
                    Button(role: .destructive) { mon.disableControl() } label: {
                        Label("移除风扇控制助手", systemImage: "trash")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                Text("MIT License · 开源项目,欢迎 issue 与 PR。").font(.system(size: 11)).foregroundStyle(Theme.ink3)
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
