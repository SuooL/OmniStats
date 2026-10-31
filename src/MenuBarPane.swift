import SwiftUI
import AppKit

// Settings for hiding menu-bar icons behind ‹ (see MenuBarManager).
struct MenuBarPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var manager: MenuBarManager
    @State private var recording = false
    @State private var keyMonitor: Any?
    @State private var invalidShortcut = false

    private var cfg: OmniStatsConfig { store.config }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            PageHeader(title: L.t("mb.title"), subtitle: L.t("mb.subtitle"))
            if !MenuBarLayout.isSupported() {
                Callout(.warning, message: L.t("mb.unsupported"))
            } else {
                Card {
                    ToggleRow(L.t("mb.enable"), isOn: bind(\.menuBarHiding))
                    diagram
                    Note(L.t("mb.howto"))
                    if cfg.menuBarHiding && manager.misordered { Callout(.warning, message: L.t("mb.misordered")) }
                }
                if cfg.menuBarHiding { optionsCard }
            }
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
                Callout(.info, message: L.t("mb.systemNote")) {
                    Button(L.t("mb.openSettings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .secondaryButton()
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private var optionsCard: some View {
        Card(L.t("mb.options"), icon: "slider.horizontal.3") {
            ToggleRow(L.t("mb.alwaysHidden"), detail: L.t("mb.alwaysHiddenHelp"), isOn: bind(\.menuBarAlwaysHidden))
            RowDivider()
            SettingRow(L.t("mb.autoHide")) {
                Picker("", selection: bind(\.menuBarAutoHide)) {
                    ForEach(OmniStatsConfig.menuBarAutoHideChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? L.t("mb.never") : seconds == 60 ? L.t("mb.minute") : L.f("mb.seconds", seconds)).tag(seconds)
                    }
                }
                .labelsHidden().fixedSize()
            }
            RowDivider()
            SettingRow(L.t("mb.shortcut")) {
                HStack(spacing: Theme.Space.s) {
                    if cfg.menuBarHotKey != nil && !recording {
                        Button(L.t("mb.clear")) { store.config.menuBarHotKey = nil }
                            .buttonStyle(.borderless).controlSize(.small)
                    }
                    Button(recording ? L.t("mb.recording") : cfg.menuBarHotKey?.display ?? L.t("mb.record")) {
                        recording ? stopRecording() : startRecording()
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(recording ? Theme.accent : nil)
                }
            }
            if invalidShortcut { Note(L.t("mb.shortcutHint")) }
            if manager.hotKeyFailed { Callout(.warning, message: L.t("mb.shortcutTaken")) }
        }
    }

    // An illustration, not the real icons: [ hidden ] | [ shown ] ‹ [ OmniStats ]
    private var diagram: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Badge(text: L.t("mb.example"), tint: Theme.ink3)
            HStack(alignment: .top, spacing: Theme.Space.s) {
                group(["speaker.wave.2.fill", "wifi", "moon.fill"], caption: L.t("mb.hiddenLabel")).opacity(0.4)
                Rectangle().fill(Theme.ink2).frame(width: 1.5, height: 16)
                group(["battery.75percent", "magnifyingglass"], caption: L.t("mb.shownLabel"))
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                    .frame(height: 16)
                Image(systemName: "thermometer.medium").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    .frame(height: 16)
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L.t("mb.howto"))
    }
    private func group(_ symbols: [String], caption: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 7) {
                ForEach(symbols, id: \.self) { Image(systemName: $0).font(.system(size: 12)).foregroundStyle(Theme.ink) }
            }
            .frame(height: 16)
            Text(caption).font(Theme.Typo.micro).foregroundStyle(Theme.ink3)
        }
    }

    // Records the next key combination typed while Settings is focused; needs
    // no permission because it only sees this window's events.
    private func startRecording() {
        stopRecording()
        recording = true; invalidShortcut = false
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }   // Escape cancels
            if let hotKey = MenuBarHotKey(keyCode: event.keyCode, flags: event.modifierFlags,
                                          characters: event.charactersIgnoringModifiers) {
                store.config.menuBarHotKey = hotKey
                stopRecording()
            } else {
                invalidShortcut = true
            }
            return nil
        }
    }
    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil; recording = false
    }

    private func bind<T>(_ keyPath: WritableKeyPath<OmniStatsConfig, T>) -> Binding<T> {
        Binding(get: { store.config[keyPath: keyPath] }, set: { store.config[keyPath: keyPath] = $0 })
    }
}
