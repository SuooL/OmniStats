import SwiftUI
import AppKit
import Combine

// Own the status item and dashboard window so content changes keep the top
// edge pinned to the menu bar. A scroll viewport caps tall dashboards to the
// visible screen. Intrinsic-size notifications are coalesced after SwiftUI
// commits layout; resizing a hosting view reentrantly can retain old centering.

// MARK: - Shared panel state
// The controller owns expansion so it can stop the network subprocess on
// dismissal without waiting for a SwiftUI render or disappearance callback.
final class PanelState: ObservableObject {
    @Published var netExpanded = false
}

enum NetworkPanelLayout {
    static let gap: CGFloat = 8

    static func frame(beside parent: NSRect, contentSize: CGSize, visible: NSRect) -> NSRect {
        let width = ceil(contentSize.width)
        let top = min(parent.maxY, visible.maxY)
        let height = min(ceil(contentSize.height), max(1, floor(top - visible.minY - 8)))
        let left = parent.minX - gap - width
        let right = parent.maxX + gap
        let minX = visible.minX + 8, maxX = visible.maxX - width - 8
        let x: CGFloat
        if left >= minX { x = left }
        else if right <= maxX { x = right }
        else { x = max(minX, min(left, maxX)) }
        return NSRect(x: floor(x), y: top - height, width: width, height: height)
    }
}

// MARK: - Panel window
// Borderless, non-activating, and key-capable so Esc and outside-click dismissal
// behave like a real menu.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Self-measuring hosting view
// Coalesces ideal-size changes after layout commits, avoiding reentrant frame
// writes while retaining no closed hosting trees.
final class SizingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: ((CGSize) -> Void)?
    private var sizeNotificationPending = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        scheduleSizeNotification()
    }

    private func scheduleSizeNotification() {
        guard !sizeNotificationPending else { return }
        sizeNotificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeNotificationPending = false
            self.onSizeChange?(self.intrinsicContentSize)
        }
    }

    override func layout() {
        super.layout()
        // Resize the document after this layout commits. Resizing an NSHostingView
        // from inside its own layout leaves SwiftUI centered in the previous size.
        scheduleSizeNotification()
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
    private let resources: ResourceSampler

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panelState = PanelState()
    private(set) var panel: PanelWindow?
    private(set) var hosting: SizingHostingView<MenuPanel>?
    private(set) var networkPanel: PanelWindow?
    private(set) var networkHosting: SizingHostingView<NetworkDetailsView>?
    private var scrolling: NSScrollView?
    private var networkScrolling: NSScrollView?
    var maximumPanelHeight: CGFloat = .greatestFiniteMagnitude
    private var labelRefreshPending = false
    private var lastLabelContent: MenuBarContent?
    private var lastLabelScale: CGFloat = 0
    private var lastLabelAppearance: AppearanceMode?

    private var panelVisibleFrame: NSRect?
    private var pinnedTop: CGFloat = 0        // screen y of the panel's top edge, held across resizes
    private var resizing = false              // re-entrancy guard for layout → setFrame → layout
    private var closingPanel = false
    private var lastClose = Date.distantPast
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var bag = Set<AnyCancellable>()

    init(mon: Monitor, store: ConfigStore, engine: Engine, net: NetSampler,
         proc: ProcSampler, netProc: NetProcSampler, activity: ActivityState = ActivityState(),
         resources: ResourceSampler = ResourceSampler(),
         onOpenSettings: @MainActor @escaping () -> Void) {
        self.mon = mon; self.store = store; self.engine = engine
        self.net = net; self.proc = proc; self.netProc = netProc
        self.onOpenSettings = onOpenSettings
        self.activity = activity; self.resources = resources
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
        .removeDuplicates()
        .sink { [weak self] expanded in MainActor.assumeIsolated {
            guard let self else { return }
            if expanded && self.panel?.isVisible == true && self.store.config.showNetworkPanel {
                self.openNetworkDetails()
            } else {
                self.closeNetworkDetails()
            }
        } }
        .store(in: &bag)

        proc.enabled = store.config.showProcesses
        configureSamplers()
        refreshLabel()
    }

    private func configureSamplers() {
        proc.windowSeconds = store.config.cpuWindow.seconds
        if !store.config.showNetworkPanel { panelState.netExpanded = false }
        netProc.enabled = panel?.isVisible == true && networkPanel?.isVisible == true
            && store.config.showNetworkPanel
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
                             resources: resources, state: panelState,
                             onOpenSettings: { [weak self] in
                                 self?.closePanel()
                                 self?.onOpenSettings()
                             })
        let host = SizingHostingView(rootView: root)
        host.onSizeChange = { [weak self] size in self?.applyContentSize(size) }
        let (window, scroll) = makePanel(document: host)
        panel = window
        hosting = host
        scrolling = scroll
    }

    private func makePanel(document: NSView) -> (PanelWindow, NSScrollView) {
        let p = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // Keep the fixed-width dashboard intact even when macOS forces legacy
        // scrollbars. Trackpad/wheel and accessibility scrolling remain available.
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        p.contentView = scroll
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

        return (p, scroll)
    }

    private func openNetworkDetails() {
        guard let panel, panel.isVisible, networkPanel == nil else { return }
        let root = NetworkDetailsView(net: net, netProc: netProc, store: store,
                                      onClose: { [weak self] in self?.panelState.netExpanded = false })
        let host = SizingHostingView(rootView: root)
        let (detail, scroll) = makePanel(document: host)
        detail.title = L.t("m.network")
        networkPanel = detail
        networkHosting = host
        networkScrolling = scroll
        host.onSizeChange = { [weak self] _ in self?.layoutNetworkDetails() }
        host.layoutSubtreeIfNeeded()
        layoutNetworkDetails()
        panel.addChildWindow(detail, ordered: .above)
        detail.orderFront(nil)
        netProc.enabled = true
    }

    private func layoutNetworkDetails() {
        guard let panel, panel.isVisible, let networkPanel, let host = networkHosting,
              let visible = panel.screen?.visibleFrame ?? panelVisibleFrame else { return }
        let size = host.intrinsicContentSize
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return }
        let documentSize = CGSize(width: ceil(size.width), height: ceil(size.height))
        if host.frame.size != documentSize { host.setFrameSize(documentSize) }
        let frame = NetworkPanelLayout.frame(beside: panel.frame, contentSize: documentSize, visible: visible)
        if networkPanel.frame != frame {
            networkPanel.setFrame(frame, display: true)
            networkPanel.invalidateShadow()
        }
        if let scroll = networkScrolling {
            let y = min(scroll.contentView.bounds.minY, max(0, documentSize.height - frame.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func closeNetworkDetails() {
        netProc.enabled = false
        guard let detail = networkPanel else { return }
        let restoreFocus = detail.isKeyWindow && !closingPanel
        detail.delegate = nil
        panel?.removeChildWindow(detail)
        detail.orderOut(nil)
        networkHosting?.onSizeChange = nil
        networkScrolling?.documentView = nil
        detail.contentView = nil
        detail.close()
        networkPanel = nil
        networkHosting = nil
        networkScrolling = nil
        if restoreFocus, panel?.isVisible == true { panel?.makeKeyAndOrderFront(nil) }
    }

    // Size the scroll viewport to fit the screen while retaining full document height.
    private func boundedContentSize(_ size: CGSize) -> CGSize {
        let available = panelVisibleFrame.map { max(100, pinnedTop - $0.minY - 8) } ?? ceil(size.height)
        // AppKit rounds window geometry to whole points. Fractional disclosure
        // heights can otherwise round the origin and height in opposite
        // directions, shifting the top edge by one point between frames.
        return CGSize(width: ceil(size.width),
                      height: min(ceil(size.height), floor(available), floor(maximumPanelHeight)))
    }

    private func applyContentSize(_ size: CGSize) {
        guard !resizing, let panel, panel.isVisible,
              size.width.isFinite, size.height.isFinite,
              size.width > 1, size.height > 1 else { return }
        let bounded = boundedContentSize(size)
        let documentSize = CGSize(width: ceil(size.width), height: ceil(size.height))
        let documentChanged = hosting.map { abs($0.frame.height-documentSize.height) > 0.5 || abs($0.frame.width-documentSize.width) > 0.5 } ?? false
        let viewportChanged = abs(panel.frame.height-bounded.height) > 0.5 || abs(panel.frame.width-bounded.width) > 0.5
        guard documentChanged || viewportChanged else { return }
        resizing = true
        defer { resizing = false }
        if documentChanged { hosting?.setFrameSize(documentSize) }
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: bounded))
        frame.origin.x = panel.frame.origin.x
        frame.origin.y = pinnedTop - frame.height
        if abs(frame.height-panel.frame.height) > 0.5 || abs(frame.width-panel.frame.width) > 0.5 {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        if let scrolling {
            let y = min(scrolling.contentView.bounds.minY, max(0, documentSize.height-bounded.height))
            scrolling.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scrolling.reflectScrolledClipView(scrolling.contentView)
        }
        layoutNetworkDetails()
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
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panelVisibleFrame = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame
        if let visible = panelVisibleFrame {
            // Overflowed menu-bar items can have an off-screen anchor during
            // programmatic opening; keep the dashboard on its actual screen.
            pinnedTop = anchor.minY > visible.minY ? min(anchor.minY - 6, visible.maxY) : visible.maxY - 6
        } else { pinnedTop = anchor.minY - 6 }
        pinnedTop = floor(pinnedTop)
        if panel == nil { buildPanel() }
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.intrinsicContentSize
        hosting.setFrameSize(CGSize(width: ceil(size.width), height: ceil(size.height)))
        let frameSize = panel.frameRect(forContentRect: NSRect(origin: .zero, size: boundedContentSize(size))).size

        var x = anchor.midX - frameSize.width / 2
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(visible.minX + 8, x), visible.maxX - frameSize.width - 8)
        }

        panel.setFrame(NSRect(x: x, y: pinnedTop - frameSize.height,
                              width: frameSize.width, height: frameSize.height), display: false)
        button.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        scrolling?.contentView.scroll(to: .zero)
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
        closeNetworkDetails()
        netProc.enabled = false          // stop the nettop child as soon as it's off screen
        // orderOut alone retains the hosting tree and its live subscriptions.
        // Destroy it so hidden charts cannot keep SwiftUI laying out.
        hosting?.onSizeChange = nil
        scrolling?.documentView = nil
        panel.contentView = nil
        panel.close()
        hosting = nil; scrolling = nil
        self.panel = nil
        lastClose = Date()
    }

    // MARK: dismissal
    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.closePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                if self.panelState.netExpanded { self.panelState.netExpanded = false }
                else { self.closePanel() }
                return nil
            }
            if event.type != .keyDown, event.window !== self.panel, event.window !== self.networkPanel {
                self.closePanel()
            }
            return event
        }
    }
    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    func windowDidResignKey(_ notification: Notification) {
        // AppKit sends resign before the other panel becomes key. Decide after
        // the focus transfer, treating both panels as one transient group.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel?.isVisible == true else { return }
            if let key = NSApp.keyWindow, key === self.panel || key === self.networkPanel { return }
            self.closePanel()
        }
    }

    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panel { layoutNetworkDetails() }
    }
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
