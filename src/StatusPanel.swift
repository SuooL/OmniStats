import SwiftUI
import AppKit
import Combine

// The menu-bar status item and its drop-down panel, hosted directly on AppKit.
//
// This replaces SwiftUI's `MenuBarExtra(.window)`. That API owns its host window
// and sizes it from the SwiftUI fitting size *asynchronously*: when the panel's
// content shrank (collapsing the network row) the window kept its old height for
// a frame or two, the shorter content was centred inside it, and the desktop
// showed through above and below — then the window snapped shut. Driving the
// resize from a measured PreferenceKey (the previous workaround) added a second
// full layout pass on every height change and still left the two visible jumps.
//
// Owning the NSPanel removes the whole class of problem: `SizingHostingView`
// reports SwiftUI's ideal size from inside `layout()`, and the window frame is
// updated *in the same layout pass*, anchored to its top edge. Content and
// window therefore always agree, and an animated SwiftUI disclosure drives the
// window height frame-by-frame instead of snapping.

// MARK: - Shared panel state
// The controller owns expansion so it can stop the network subprocess on
// dismissal without waiting for a SwiftUI render or disappearance callback.
final class PanelState: ObservableObject {
    @Published var netExpanded = false
}

// MARK: - Panel window
// Borderless, non-activating, and key-capable so Esc and outside-click dismissal
// behave like a real menu.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Self-measuring hosting view
// Publishes SwiftUI's ideal size on every layout pass. The controller resizes
// the window from this callback, synchronously, so the window never lags the
// content.
final class SizingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: ((CGSize) -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        onSizeChange?(intrinsicContentSize)
    }
}

// MARK: - Status item + panel controller
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let mon: Monitor
    private let store: ConfigStore
    private let engine: Engine
    private let net: NetSampler
    private let proc: ProcSampler
    private let netProc: NetProcSampler
    private let onOpenSettings: @MainActor () -> Void
    private let activity: ActivityState

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panelState = PanelState()
    private(set) var panel: PanelWindow?
    private var hosting: SizingHostingView<MenuPanel>?
    private var labelRefreshPending = false
    private var lastLabelContent: MenuBarContent?
    private var lastLabelScale: CGFloat = 0
    private var lastLabelAppearance: AppearanceMode?

    private var pinnedTop: CGFloat = 0        // screen y of the panel's top edge, held across resizes
    private var resizing = false              // re-entrancy guard for layout → setFrame → layout
    private var closingPanel = false
    private var lastClose = Date.distantPast
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var bag = Set<AnyCancellable>()

    init(mon: Monitor, store: ConfigStore, engine: Engine, net: NetSampler,
         proc: ProcSampler, netProc: NetProcSampler, activity: ActivityState = ActivityState(),
         onOpenSettings: @MainActor @escaping () -> Void) {
        self.mon = mon; self.store = store; self.engine = engine
        self.net = net; self.proc = proc; self.netProc = netProc
        self.onOpenSettings = onOpenSettings
        self.activity = activity
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageOnly
        }

        // A sensor refresh publishes several fields synchronously. Queue only
        // one render for the entire batch, after all values have settled.
        Publishers.MergeMany(
            net.objectWillChange.eraseToAnyPublisher(),
            mon.objectWillChange.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleLabelRefresh() } }
        .store(in: &bag)

        store.objectWillChange
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in MainActor.assumeIsolated {
            self?.configureSamplers()
            self?.scheduleLabelRefresh()
        } }
        .store(in: &bag)

        panelState.$netExpanded
        .sink { [weak self] expanded in MainActor.assumeIsolated {
            guard let self else { return }
            self.netProc.enabled = self.panel?.isVisible == true
                && self.store.config.showNetworkPanel && expanded
        } }
        .store(in: &bag)

        proc.enabled = store.config.showProcesses
        configureSamplers()
        refreshLabel()
    }

    private func configureSamplers() {
        proc.windowSeconds = store.config.cpuWindow.seconds
        netProc.enabled = panel?.isVisible == true
            && store.config.showNetworkPanel && panelState.netExpanded
    }

    private func scheduleLabelRefresh() {
        guard !labelRefreshPending else { return }
        labelRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.labelRefreshPending = false
            self.refreshLabel()
        }
    }

    // MARK: menu-bar label
    // SwiftUI clips a multi-row status-item label, so the whole readout is
    // rasterised into one NSImage — the menu bar draws an image at its natural
    // size with no clipping. This is how pro menu-bar apps stack upload/download
    // on two rows.
    private func refreshLabel() {
        let cfg = store.config
        let mono = cfg.menuNumberColor == .mono
        func tint(_ rate: Double) -> Color {
            switch cfg.menuNumberColor {
            case .tempGradient: return Theme.speed(rate)
            case .accent:       return Theme.accent
            case .mono:         return .primary
            }
        }
        let tempTint: Color
        switch cfg.menuNumberColor {
        case .tempGradient: tempTint = Theme.temp(Double(mon.socMax))
        case .accent:       tempTint = Theme.accent
        case .mono:         tempTint = .primary
        }

        let content = MenuBarContent(
            showNet: cfg.showNetworkInMenuBar,
            showTemp: cfg.showTempInMenuBar,
            txText: cfg.showNetworkInMenuBar ? menuBarRate(net.txBps) : "",
            rxText: cfg.showNetworkInMenuBar ? menuBarRate(net.rxBps) : "",
            tempText: cfg.showTempInMenuBar ? fmtTemp(mon.socMax, fahrenheit: cfg.fahrenheit) : "",
            txColor: cfg.showNetworkInMenuBar ? tint(net.txBps) : .clear,
            rxColor: cfg.showNetworkInMenuBar ? tint(net.rxBps) : .clear,
            tempColor: cfg.showTempInMenuBar ? tempTint : (mono ? .primary : Theme.accent))

        let scale = statusItem.button?.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        guard content != lastLabelContent || scale != lastLabelScale
                || cfg.appearance != lastLabelAppearance else { return }
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, cfg.appearance.colorScheme))
        renderer.scale = scale
        guard let img = renderer.nsImage else { return }
        img.isTemplate = mono   // mono → adaptive template (legible on any menu-bar tint)
        statusItem.button?.image = img
        let description = "OmniStats · \(content.tempText) · ↑ \(content.txText) ↓ \(content.rxText)"
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
        lastLabelContent = content
        lastLabelScale = scale
        lastLabelAppearance = cfg.appearance
    }

    // MARK: panel lifecycle
    private func buildPanel() {
        let root = MenuPanel(mon: mon, store: store, engine: engine, net: net, proc: proc,
                             netProc: netProc, state: panelState,
                             onOpenSettings: { [weak self] in
                                 self?.closePanel()
                                 self?.onOpenSettings()
                             })
        let host = SizingHostingView(rootView: root)
        host.onSizeChange = { [weak self] size in self?.applyContentSize(size) }

        let p = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none          // we own the geometry; no AppKit fade/zoom
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self

        panel = p
        hosting = host
    }

    // Called from the hosting view's layout pass. Resizes the window to the
    // content's ideal size, keeping the top edge pinned under the menu bar.
    private func applyContentSize(_ size: CGSize) {
        guard !resizing, let panel, panel.isVisible,
              size.width.isFinite, size.height.isFinite,
              size.width > 1, size.height > 1 else { return }
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard abs(frame.height - panel.frame.height) > 0.5
                || abs(frame.width - panel.frame.width) > 0.5 else { return }
        frame.origin.x = panel.frame.origin.x
        frame.origin.y = pinnedTop - frame.height
        resizing = true
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        resizing = false
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            // A click on the status item first makes the panel resign key, which
            // already closed it; without this guard the action would immediately
            // re-open it and the panel would never dismiss.
            guard Date().timeIntervalSince(lastClose) > 0.2 else { return }
            openPanel()
        }
    }

    func openPanel() {
        guard panel?.isVisible != true else { return }
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        if panel == nil { buildPanel() }
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.intrinsicContentSize
        let frameSize = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size

        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = anchor.midX - frameSize.width / 2
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(visible.minX + 8, x), visible.maxX - frameSize.width - 8)
        }
        pinnedTop = anchor.minY - 6

        panel.setFrame(NSRect(x: x, y: pinnedTop - frameSize.height,
                              width: frameSize.width, height: frameSize.height), display: false)
        button.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        activity.panelVisible = true
        panel.invalidateShadow()
        installMonitors()
    }

    func closePanel() {
        guard !closingPanel, let panel, panel.isVisible else { return }
        closingPanel = true
        defer { closingPanel = false }
        removeMonitors()
        panel.orderOut(nil)
        activity.panelVisible = false
        statusItem.button?.highlight(false)
        panelState.netExpanded = false
        netProc.enabled = false          // stop the nettop child as soon as it's off screen
        // orderOut alone retains the hosting tree and its live subscriptions.
        // Destroy it so hidden charts cannot keep SwiftUI laying out.
        hosting?.onSizeChange = nil
        panel.contentView = nil
        panel.close()
        hosting = nil
        self.panel = nil
        lastClose = Date()
    }

    // MARK: dismissal
    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.closePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            self?.closePanel()
            return nil
        }
    }
    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    func windowDidResignKey(_ notification: Notification) { closePanel() }
}

// MARK: - Settings window
// A plain AppKit window hosting `SettingsView`. The app has no SwiftUI `Scene`
// graph any more, so `@Environment(\.openWindow)` is unavailable — and this is
// simpler anyway: one window, created lazily and released when closed.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let mon: Monitor
    private let store: ConfigStore
    private let engine: Engine
    private let updater: Updater
    private let activity: ActivityState
    private let settingsState = SettingsState()
    private var savedFrame: NSRect?
    private(set) var window: NSWindow?

    init(mon: Monitor, store: ConfigStore, engine: Engine, updater: Updater, activity: ActivityState = ActivityState()) {
        self.mon = mon; self.store = store; self.engine = engine; self.updater = updater
        self.activity = activity
    }

    func show() {
        if window == nil {
            let host = NSHostingController(
                rootView: SettingsView(mon: mon, store: store, engine: engine, updater: updater, state: settingsState))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.title = L.t("settings.window")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false      // we keep the reference; AppKit must not free it
            w.delegate = self
            if let savedFrame { w.setFrame(savedFrame, display: false) } else { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        activity.settingsVisible = true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        savedFrame = closing.frame
        activity.settingsVisible = false
        // A closed NSWindow otherwise retains its NSHostingController, which
        // continues observing the monitor for the rest of the app's lifetime.
        closing.contentViewController = nil
        window = nil
    }
    func windowDidMiniaturize(_ notification: Notification) { activity.settingsVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { activity.settingsVisible = true }
}

// MARK: - Menu-bar readout
// The rasterised menu-bar content: stacked upload/download on the left,
// temperature on the right. Rendered off-screen by ImageRenderer, so colors are
// passed in explicitly rather than read from the environment.
struct MenuBarContent: View, Equatable {
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
