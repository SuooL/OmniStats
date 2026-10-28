import AppKit
import SwiftUI
import Sparkle

// Run in a logged-in macOS desktop session: make test-runtime.
// Uses isolated preferences and C hardware stubs, never the installed helper.
@main
enum RuntimeTests {
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    @MainActor static func drain(_ seconds: TimeInterval = 0.05) {
        // RunLoop alone delivers SwiftUI/dispatch work but does not dispatch
        // AppKit's queued activation and focus events without NSApplication.run.
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast,
                                             inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        } while Date() < deadline
    }

    @MainActor static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(2)
        while !NSApp.isActive && Date() < deadline { drain(0.01) }
        check(NSApp.isActive, "Focus tests require the test application to be active")
    }

    @MainActor static func snapshot(_ view: NSView?, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["OMNISTATS_TEST_SNAPSHOT_DIR"], let view,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        if let scroll = view as? NSScrollView {
            let details = "Snapshot \(name): scroll=\(scroll.frame) clip=\(scroll.contentView.bounds) document=\(scroll.documentView!.frame) flipped=\(scroll.documentView!.isFlipped)"
            FileHandle.standardError.write(Data(details.utf8) + Data([10]))
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    // Compare the dashboard above the network section in screen-relative
    // coordinates. A stable window frame alone cannot catch content centering
    // or compression inside the hosting view.
    @MainActor static func upperPanelImage(_ view: NSView) -> Data {
        let height: CGFloat = 390
        let rect = NSRect(x: view.bounds.minX,
                          y: view.isFlipped ? view.bounds.minY : view.bounds.maxY - height,
                          width: view.bounds.width, height: height)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else {
            fatalError("Cannot capture the upper dashboard")
        }
        view.cacheDisplay(in: rect, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])!
    }

    @MainActor static func checkPanelSurface(_ view: NSView) {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let actual = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 6)!.usingColorSpace(.sRGB)!
        // Offscreen AppKit bitmaps vary by display color profile. Verify the
        // selected light/dark surface, rather than exact encoded RGB bytes.
        let brightness = (actual.redComponent + actual.greenComponent + actual.blueComponent) / 3
        check(Theme.mode == .light ? brightness > 0.7 : brightness < 0.3,
              "Both panel surfaces must update to the selected appearance")
    }

    @MainActor static func click(_ point: NSPoint, in window: NSWindow) {
        let local = window.convertPoint(fromScreen: point)
        let timestamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                               timestamp: timestamp + (type == .leftMouseUp ? 0.01 : 0),
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Queue mouse-up first so AppKit controls with synchronous tracking can
        // consume it while handling mouse-down. SwiftUI may leave it queued.
        NSApp.postEvent(event(.leftMouseUp), atStart: true)
        window.sendEvent(event(.leftMouseDown))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                   inMode: .default, dequeue: true) {
            window.sendEvent(up)
        }
        drain()
    }

    @MainActor static func sendEscape(in window: NSWindow) {
        NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!)
        drain()
    }

    @MainActor static func checkSettingsNavigation(_ host: NSHostingController<SettingsView>, in window: NSWindow) {
        for (index, section) in SettingsSection.allCases.enumerated() {
            // Sidebar geometry: 12 pt inset, header, 4 pt spacing,
            // 30 pt rows. The icon/text gap is x=38...47 in the root view.
            // Check text first to distinguish event delivery from hit testing.
            for location in ["text", "gap", "trailing", "leading", "vertical"] {
                host.rootView.state.section = section == .fans ? .about : .fans
                drain()
                let y = host.view.safeAreaInsets.top + CGFloat(75 + index * 34)
                var point = NSPoint(x: 84, y: y)
                switch location {
                case "text": point.x = 60
                case "gap": point.x = 42
                case "trailing": point.x = 151
                case "leading": point.x = 15
                default: point.y += 13
                }
                if !host.view.isFlipped { point.y = host.view.bounds.height - point.y }
                click(window.convertPoint(toScreen: host.view.convert(point, to: nil)), in: window)
                check(host.rootView.state.section == section,
                      "Settings tab \(section.rawValue) must respond to its \(location) area")
            }
        }
    }

    static func resources() -> (cpu: Double, memory: Double) {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { fatalError("Cannot measure test process") }
        return (Double(info.ri_user_time + info.ri_system_time) / 1e9,
                Double(info.ri_phys_footprint) / 1048576)
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let suite = "OmniStats.RuntimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigStore(defaults: defaults)
        defer { store.flush() }
        store.config.showProcesses = false
        let mon = Monitor()
        let net = NetSampler()
        let proc = ProcSampler()
        let netProc = NetProcSampler(runnerURL: URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("omnistats-nettop"))
        let engine = Engine(monitor: mon, store: store)
        let activity = ActivityState()
        let resourceSampler = ResourceSampler(read: {
            ResourceSnapshot(cpuPercent: 37, memory: CapacityUsage(used: 32 * 1_073_741_824, total: 64 * 1_073_741_824),
                             disk: CapacityUsage(used: 400e9, total: 1000e9), gpuPercent: 42)
        })
        let coordinator = SamplingCoordinator(monitor: mon, net: net, proc: proc, netProc: netProc,
                                             engine: engine, store: store, activity: activity, resources: resourceSampler)
        defer { withExtendedLifetime(coordinator) {} }
        let status = StatusItemController(mon: mon, store: store, engine: engine,
            net: net, proc: proc, netProc: netProc, activity: activity, resources: resourceSampler, onOpenSettings: {})
        check(status.panel == nil, "Startup must not construct the hidden panel")
        check(!proc.enabled, "Process sampling preferences must apply before opening a panel")
        drain()

        guard let button = status.statusItem.button, button.window != nil else {
            fatalError("Runtime tests require a logged-in macOS desktop session")
        }
        check(button.image != nil, "Menu-bar image must render")
        check(button.toolTip?.contains("content.") == false, "Tooltip must interpolate live values")
        let backgroundCadence: Double = ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 10
        check(mon.samplingInterval == backgroundCadence, "Coordinator must apply background cadence")
        activity.panelVisible = true; drain()
        check(mon.samplingInterval == 10 && net.samplingInterval == 3, "Visible panel must use default sampling")
        check(resourceSampler.samplingInterval == 10 && resourceSampler.hasSample, "Visible panel must collect resources")
        activity.panelVisible = false; drain()
        check(resourceSampler.samplingInterval == nil, "Hidden panel must stop resource sampling")
        check(mon.samplingInterval == backgroundCadence, "Hidden panel must restore background cadence")
        // Cadence transitions can invalidate the asynchronous startup sample.
        // Establish real baseline content before asserting an unchanged render,
        // and prevent live host traffic from changing this isolated cache check.
        net.setSamplingInterval(nil)
        mon.refresh()
        let sampleDeadline = Date().addingTimeInterval(2)
        while mon.lastSampleTime == 0 && Date() < sampleDeadline { drain(0.01) }
        check(mon.lastSampleTime > 0, "Cache tests require the initial sensor sample")
        drain()
        var imageWrites = 0
        let observation = button.observe(\.image, options: [.new]) { _, _ in imageWrites += 1 }
        defer { observation.invalidate() }

        let initial = button.image
        mon.refresh()
        mon.power = 30
        mon.volt = 11
        drain()
        check(button.image === initial, "Unchanged menu content must retain its image")
        check(imageWrites == 0, "Unrelated sensor publications must not render the label")

        for i in 0..<100 {
            mon.socMax = Float(51 + i % 10)
            net.rxBps = Double(i * 1024)
            net.txBps = Double(i * 512)
        }
        drain()
        check(imageWrites == 1, "One synchronous publication batch must produce one image")
        check(button.image !== initial, "Visible changes must update the image")

        store.config.showNetworkInMenuBar = false
        store.config.showTempInMenuBar = false
        drain()
        let hidden = button.image
        mon.socMax = 90
        net.rxBps = 100_000_000
        net.txBps = 50_000_000
        drain()
        check(button.image === hidden, "Hidden readings must not redraw the fallback icon")
        store.config.appearance = .light
        check(NSApp.appearance?.name == .aqua && Theme.mode == .light,
              "Presentation must update without evaluating a view body")
        drain()
        store.config.appearance = .dark
        store.config.showNetworkInMenuBar = true
        store.config.showTempInMenuBar = true
        drain()

        check(ProcUsage(name: "Example", cpu: 1).id == ProcUsage(name: "Example", cpu: 2).id,
              "CPU rows need stable identity across readings")
        check(NetProcUsage(name: "Example", rxBps: 1, txBps: 0).id
              == NetProcUsage(name: "Example", rxBps: 2, txBps: 1).id,
              "Network rows need stable identity across readings")

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let settings = SettingsWindowController(mon: mon, store: store, engine: engine,
            updater: Updater(updater: updaterController.updater), activity: activity)
        var previousSettingsFrame: NSRect?

        // Warm up framework caches before measuring repeated window lifetimes.
        for iteration in 0..<12 {
            weak var panelHost: NSView?
            weak var dashboardHost: NSView?
            weak var settingsHost: NSViewController?
            weak var detailWindow: NSWindow?
            weak var detailHost: NSView?
            autoreleasepool {
                if iteration == 0 {
                    activateApp()
                }
                status.openPanel()
                check(status.panel?.isVisible == true, "Panel must reopen")
                panelHost = status.panel?.contentView
                dashboardHost = status.hosting
                if iteration == 0, let host = status.hosting {
                    // Hold readings constant to isolate disclosure layout from
                    // legitimate live metric updates and ring animations.
                    mon.setSamplingInterval(nil)
                    net.setSamplingInterval(nil)
                    resourceSampler.setSamplingInterval(nil)
                    drain(0.6)
                    snapshot(status.panel?.contentView, name: "resources")
                    let upperImage = upperPanelImage(status.panel!.contentView!)
                    let mainFrame = status.panel!.frame
                    host.rootView.state.netExpanded = true
                    drain(0.1)
                    check(status.networkPanel?.isVisible == true && netProc.enabled,
                          "Expanded network must open its own window and start sampling")
                    check(status.panel!.frame == mainFrame,
                          "Opening network details must leave the complete dashboard frame unchanged")
                    check(upperPanelImage(status.panel!.contentView!) == upperImage,
                          "Opening network details must not move or resize dashboard content")
                    check(status.networkPanel?.parent === status.panel,
                          "Network details must belong to the dashboard window group")
                    let detailFrame = status.networkPanel!.frame
                    let expected = NetworkPanelLayout.frame(beside: mainFrame,
                        contentSize: status.networkHosting!.frame.size,
                        visible: status.panel!.screen!.visibleFrame)
                    check(detailFrame == expected, "Network details must use the adjacent screen-bounded placement")
                    snapshot(status.panel?.contentView, name: "network-dashboard")
                    snapshot(status.networkPanel?.contentView, name: "network-details")

                    netProc.suspended = true
                    for count in [0, 1, 5, 2, 0] {
                        netProc.top = (0..<count).map {
                            NetProcUsage(name: "Long application name \($0)", rxBps: 1e9, txBps: 1e6)
                        }
                        drain()
                        check(status.networkPanel!.frame == detailFrame && status.panel!.frame == mainFrame,
                              "Sampling states and row counts must not resize either window")
                        if count == 5 { snapshot(status.networkPanel?.contentView, name: "network-five-rows") }
                    }
                    store.config.appearance = .light
                    drain()
                    snapshot(status.panel?.contentView, name: "network-dashboard-light")
                    snapshot(status.networkPanel?.contentView, name: "network-details-light")
                    checkPanelSurface(status.panel!.contentView!)
                    checkPanelSurface(status.networkPanel!.contentView!)
                    store.config.appearance = .dark
                    drain()
                    checkPanelSurface(status.panel!.contentView!)
                    checkPanelSurface(status.networkPanel!.contentView!)

                    status.networkPanel!.makeKeyAndOrderFront(nil)
                    drain()
                    check(status.networkPanel?.isKeyWindow == true && status.panel?.isVisible == true,
                          "Focusing network details must keep both windows open: active=\(NSApp.isActive), main=\(String(describing: status.panel)), detail=\(String(describing: status.networkPanel)), key=\(String(describing: NSApp.keyWindow))")
                    status.panel!.makeKeyAndOrderFront(nil)
                    drain()
                    check(status.panel?.isKeyWindow == true && status.networkPanel?.isVisible == true,
                          "Returning focus to the dashboard must keep network details open")

                    // Use the detail window's real close button, then the main
                    // row state. Both must collapse without changing the parent.
                    click(NSPoint(x: detailFrame.maxX - 26, y: detailFrame.maxY - 29),
                          in: status.networkPanel!)
                    check(status.networkPanel == nil && !host.rootView.state.netExpanded && !netProc.enabled,
                          "The detail close button must collapse and stop sampling")
                    check(status.panel!.frame == mainFrame, "Detail close must preserve the dashboard frame")
                    host.rootView.state.netExpanded = true
                    drain()
                    host.rootView.state.netExpanded = false
                    check(status.networkPanel == nil && !netProc.enabled,
                          "Collapsing the network row must immediately close its window and stop sampling")
                    for _ in 0..<4 {
                        host.rootView.state.netExpanded = true
                        host.rootView.state.netExpanded = false
                    }
                    host.rootView.state.netExpanded = true
                    drain(0.1)
                    check(status.panel?.childWindows?.count == 1 && status.networkPanel?.isVisible == true,
                          "Rapid toggles must leave exactly one detail window: active=\(NSApp.isActive) main=\(String(describing: status.panel)) detail=\(String(describing: status.networkPanel)) key=\(String(describing: NSApp.keyWindow))")
                    sendEscape(in: status.networkPanel!)
                    check(status.networkPanel == nil && status.panel?.isVisible == true,
                          "Escape must dismiss details before the dashboard")
                    check(status.panel!.frame == mainFrame,
                          "All detail interactions must preserve the complete dashboard frame")
                    netProc.suspended = false
                    let now = sampleTime()
                    for i in 0..<30 {
                        mon.socHistory.record(60 + 12 * sin(Double(i)/3), at: now-Double(29-i)*10, cadence: 10)
                        mon.ssdHistory.record(40 + 4 * sin(Double(i)/5), at: now-Double(29-i)*10, cadence: 10)
                    }
                    store.config.topWidgetStyle = .line
                    drain(0.15)
                    snapshot(status.panel?.contentView, name: "smooth-history")
                    store.config.topWidgetStyle = .ring
                    drain(0.1)
                }
                status.hosting!.rootView.state.netExpanded = true
                drain()
                detailWindow = status.networkPanel
                detailHost = status.networkHosting
                status.closePanel()
                check(status.panel == nil && status.networkPanel == nil && !netProc.enabled,
                      "Dismissal must discard both panels and stop nettop")
                settings.show()
                drain()
                if iteration == 0, let window = settings.window,
                   let screen = NSScreen.screens.first(where: {
                       $0.visibleFrame.width >= window.frame.width && $0.visibleFrame.height >= window.frame.height
                   }) {
                    // Keep the fixture on one screen. AppKit constrains a
                    // restored window that originally straddled two displays.
                    window.setFrameOrigin(NSPoint(x: floor(screen.visibleFrame.midX - window.frame.width / 2),
                                                  y: floor(screen.visibleFrame.midY - window.frame.height / 2)))
                    drain()
                }
                check(settings.window?.isVisible == true, "Settings must reopen")
                if let previousSettingsFrame {
                    check(settings.window?.frame == previousSettingsFrame,
                          "Settings geometry must survive closing: previous=\(previousSettingsFrame), current=\(settings.window!.frame)")
                }
                settingsHost = settings.window?.contentViewController
                if let host = settingsHost as? NSHostingController<SettingsView> {
                    if iteration == 0 {
                        drain()
                        snapshot(host.view, name: "settings-navigation")
                        checkSettingsNavigation(host, in: settings.window!)
                        host.rootView.state.section = .general
                        drain()
                    }
                    check(host.rootView.state.section == .general, "Settings navigation must survive closing")
                }
                previousSettingsFrame = settings.window?.frame
                settings.window?.close()
                check(settings.window == nil, "Closed settings window must be released")
            }
            drain(0.1)
            check(panelHost == nil && dashboardHost == nil, "Closed panel viewport or hosting tree is retained")
            check(settingsHost == nil, "Closed settings hosting controller is retained")
            check(detailWindow == nil && detailHost == nil, "Closed network window or hosting tree is retained")
        }

        status.maximumPanelHeight = 300
        status.openPanel(); drain(0.1)
        check(status.panel!.frame.height <= 300, "Small screens must cap the panel viewport")
        check(status.hosting!.frame.height > status.panel!.frame.height, "Overflow content must remain scrollable")
        snapshot(status.panel?.contentView, name: "capped")
        if let scroll = status.panel?.contentView as? NSScrollView {
            let bottom = status.hosting!.frame.height - scroll.contentSize.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            check(abs(scroll.contentView.bounds.minY-bottom) < 1, "Overflow dashboard must scroll to its footer")
            let frame = status.panel!.frame
            status.hosting!.rootView.state.netExpanded = true
            drain()
            check(status.panel!.frame == frame && status.networkPanel?.isVisible == true,
                  "Network details must not affect a capped dashboard")
            check(abs(scroll.contentView.bounds.minY - bottom) < 1,
                  "Network details must preserve the dashboard scroll position")
            status.hosting!.rootView.state.netExpanded = false
        }
        status.closePanel()
        status.maximumPanelHeight = .greatestFiniteMagnitude

        status.openPanel(); drain()
        let closingState = status.hosting!.rootView.state
        closingState.netExpanded = true
        status.closePanel()
        drain()
        check(!closingState.netExpanded && status.networkPanel == nil && !netProc.enabled,
              "Immediate dashboard dismissal must release details and stop sampling")
        status.openPanel(); drain()
        check(!status.hosting!.rootView.state.netExpanded && status.networkPanel == nil,
              "Reopening must start with closed network details")
        status.hosting!.rootView.state.netExpanded = true
        drain()
        store.config.showNetworkPanel = false
        drain()
        check(status.networkPanel == nil && !netProc.enabled && !status.hosting!.rootView.state.netExpanded,
              "Disabling network display must close its detail window and stop sampling")
        store.config.showNetworkPanel = true
        drain()
        status.hosting!.rootView.state.netExpanded = true
        drain()
        sendEscape(in: status.panel!)
        sendEscape(in: status.panel!)
        check(status.panel == nil && status.networkPanel == nil, "A second Escape must dismiss the dashboard")

        status.openPanel(); drain()
        status.hosting!.rootView.state.netExpanded = true
        drain()
        let outside = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100),
                               styleMask: [.titled], backing: .buffered, defer: false)
        outside.isReleasedWhenClosed = false
        activateApp()
        outside.makeKeyAndOrderFront(nil)
        drain(0.1)
        check(status.panel == nil && status.networkPanel == nil && !netProc.enabled,
              "Focusing an unrelated window must dismiss both panels and stop sampling: active=\(NSApp.isActive), outsideKey=\(outside.isKeyWindow), mainKey=\(status.panel?.isKeyWindow == true), detailKey=\(status.networkPanel?.isKeyWindow == true), key=\(String(describing: NSApp.keyWindow))")
        outside.close()

        // Exercise real read-only nettop subprocesses, including callbacks from old sessions.
        var retired: [pid_t] = []
        for _ in 0..<4 {
            netProc.enabled = true
            guard let pid = netProc.processIdentifier else { fatalError("nettop must launch") }
            retired.append(pid)
            netProc.enabled = false
        }
        netProc.enabled = true
        let activePID = netProc.processIdentifier
        let deadline = Date().addingTimeInterval(12)
        while netProc.state == .warmingUp && Date() < deadline { drain(0.05) }
        check(netProc.state == .running && netProc.processIdentifier == activePID,
              "Live nettop must parse data; retired callbacks must not stop its replacement")
        check(retired.allSatisfy { kill($0, 0) == -1 && errno == ESRCH }, "Retired nettop children must terminate")
        netProc.suspended = true
        drain(0.1)
        check(netProc.state == .stopped && netProc.processIdentifier == nil, "Sleep must stop nettop")
        netProc.enabled = false
        netProc.suspended = false

        // Report a short idle sample, not a long-run leak or energy guarantee.
        drain(0.2)
        let before = resources()
        let start = ProcessInfo.processInfo.systemUptime
        drain(3)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let after = resources()
        print(String(format: "Idle test process: %.2f%% CPU, %.1f MiB footprint (3-second sample)",
                     (after.cpu - before.cpu) / elapsed * 100, after.memory))
        print("PASS: batched renders, unchanged/hidden label caching, presentation updates, stable row identity, adjacent network panels, settings hit regions, 12 window release/reopen cycles, adaptive visibility, and live nettop cleanup")
    }
}
