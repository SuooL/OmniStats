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
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
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

        let suite = "OmniStats.RuntimeTests.(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigStore(defaults: defaults)
        store.config.showProcesses = false
        let mon = Monitor()
        let net = NetSampler()
        let proc = ProcSampler()
        let netProc = NetProcSampler()
        let engine = Engine(monitor: mon, store: store)
        let status = StatusItemController(mon: mon, store: store, engine: engine,
            net: net, proc: proc, netProc: netProc, onOpenSettings: {})
        check(status.panel == nil, "Startup must not construct the hidden panel")
        check(!proc.enabled, "Process sampling preferences must apply before opening a panel")
        drain()

        guard let button = status.statusItem.button, button.window != nil else {
            fatalError("Runtime tests require a logged-in macOS desktop session")
        }
        check(button.image != nil, "Menu-bar image must render")
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
            updater: Updater(updater: updaterController.updater))
        var previousSettingsFrame: NSRect?

        // Warm up framework caches before measuring repeated window lifetimes.
        for iteration in 0..<12 {
            weak var panelHost: NSView?
            weak var settingsHost: NSViewController?
            autoreleasepool {
                status.openPanel()
                check(status.panel?.isVisible == true, "Panel must reopen")
                panelHost = status.panel?.contentView
                if iteration == 0, let host = panelHost as? SizingHostingView<MenuPanel> {
                    let height = status.panel!.frame.height
                    host.rootView.state.netExpanded = true
                    drain(0.15)
                    check(status.panel!.frame.height > height, "Expanded network must resize the panel")
                    host.rootView.state.netExpanded = false
                    drain(0.15)
                    check(abs(status.panel!.frame.height - height) < 1, "Collapsed panel must regain its height")
                }
                status.closePanel()
                check(status.panel == nil && !netProc.enabled, "Dismissal must discard the panel and stop nettop")
                settings.show()
                check(settings.window?.isVisible == true, "Settings must reopen")
                if let previousSettingsFrame {
                    check(settings.window?.frame == previousSettingsFrame, "Settings geometry must survive closing")
                }
                settingsHost = settings.window?.contentViewController
                if let host = settingsHost as? NSHostingController<SettingsView> {
                    if iteration == 0 { host.rootView.state.section = .general }
                    check(host.rootView.state.section == .general, "Settings navigation must survive closing")
                }
                previousSettingsFrame = settings.window?.frame
                settings.window?.close()
                check(settings.window == nil, "Closed settings window must be released")
            }
            drain(0.1)
            check(panelHost == nil, "Closed panel hosting tree is retained")
            check(settingsHost == nil, "Closed settings hosting controller is retained")
        }

        // Report a short idle sample, not a long-run leak or energy guarantee.
        drain(0.2)
        let before = resources()
        let start = ProcessInfo.processInfo.systemUptime
        drain(3)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let after = resources()
        print(String(format: "Idle test process: %.2f%% CPU, %.1f MiB footprint (3-second sample)",
                     (after.cpu - before.cpu) / elapsed * 100, after.memory))
        print("PASS: batched renders, unchanged/hidden label caching, presentation updates, stable row identity, panel resizing, and 12 window release/reopen cycles")
    }
}
