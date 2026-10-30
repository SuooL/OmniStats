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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L.t("mb.title")).font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.ink)
                Text(L.t("mb.subtitle")).font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
            if !MenuBarLayout.isSupported() {
                card { alert(L.t("mb.unsupported"), .orange) }
            } else {
                card {
                    toggleRow(L.t("mb.enable"), bind(\.menuBarHiding))
                    diagram
                    note(L.t("mb.howto"))
                    if cfg.menuBarHiding && manager.misordered { alert(L.t("mb.misordered"), .orange) }
                }
                if cfg.menuBarHiding { optionsCard }
            }
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
                card {
                    HStack(alignment: .top, spacing: 10) {
                        note(L.t("mb.systemNote"))
                        Spacer()
                        Button(L.t("mb.openSettings")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onDisappear { stopRecording() }
    }

    private var optionsCard: some View {
        card {
            toggleRow(L.t("mb.alwaysHidden"), bind(\.menuBarAlwaysHidden))
            note(L.t("mb.alwaysHiddenHelp"))
            Divider().overlay(Theme.line)
            HStack {
                Text(L.t("mb.autoHide")).font(.system(size: 13)).foregroundStyle(Theme.ink)
                Spacer()
                Picker("", selection: bind(\.menuBarAutoHide)) {
                    ForEach(OmniStatsConfig.menuBarAutoHideChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? L.t("mb.never") : seconds == 60 ? L.t("mb.minute") : L.f("mb.seconds", seconds)).tag(seconds)
                    }
                }
                .labelsHidden().frame(width: 140)
            }
            Divider().overlay(Theme.line)
            HStack(spacing: 10) {
                Text(L.t("mb.shortcut")).font(.system(size: 13)).foregroundStyle(Theme.ink)
                Spacer()
                Button(recording ? L.t("mb.recording") : cfg.menuBarHotKey?.display ?? L.t("mb.record")) {
                    recording ? stopRecording() : startRecording()
                }
                .buttonStyle(.bordered).controlSize(.small).tint(recording ? Theme.accent : nil)
                if cfg.menuBarHotKey != nil {
                    Button(L.t("mb.clear")) { store.config.menuBarHotKey = nil }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
            if invalidShortcut { note(L.t("mb.shortcutHint")) }
            if manager.hotKeyFailed { alert(L.t("mb.shortcutTaken"), .orange) }
        }
    }

    // [ hidden icons ] | [ visible icons ] ‹ [ OmniStats ]
    private var diagram: some View {
        HStack(spacing: 6) {
            icons(3).opacity(0.35)
            Rectangle().fill(Theme.ink2).frame(width: 1.5, height: 14)
            icons(2)
            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
            Image(systemName: "thermometer.medium").font(.system(size: 11)).foregroundStyle(Theme.ink2)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.line.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
    private func icons(_ count: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3).fill(Theme.ink2).frame(width: 12, height: 12)
            }
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
    private func toggleRow(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) { Text(label).font(.system(size: 13)).foregroundStyle(Theme.ink) }.toggleStyle(.themed)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
    }
    private func alert(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16).frame(maxWidth: 560, alignment: .leading)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: 7, y: 2)
    }
}
