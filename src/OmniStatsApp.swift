import SwiftUI
import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    let store = ConfigStore()
    let net = NetSampler()
    let proc = ProcSampler()
    let netProc = NetProcSampler()
    lazy var engine = Engine(monitor: monitor, store: store)

    // Sparkle: start the updater immediately; scheduled checks + UI are driven by
    // the SU* keys in Info.plist. `updater` is a thin SwiftUI wrapper for Settings.
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    lazy var updater = Updater(updater: updaterController.updater)

    private var statusController: StatusItemController?
    private var settingsController: SettingsWindowController?
    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ n: Notification) {
        applyLaunchArguments()
        syncPresentation(store.config)
        _ = engine   // start the control loop

        let settings = SettingsWindowController(mon: monitor, store: store, engine: engine, updater: updater)
        settingsController = settings
        statusController = StatusItemController(
            mon: monitor, store: store, engine: engine, net: net, proc: proc, netProc: netProc,
            onOpenSettings: { settings.show() })

        // Delivered on the main queue, so the main-actor-isolated window work is
        // safe to run synchronously.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .openOmniSettings, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { settings.show() }
            }

        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NotificationCenter.default.post(name: .openOmniSettings, object: nil)
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        monitor.revertAll()
    }

    // Launch args (used for screenshots / deep-linking).
    private func applyLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--theme"), i + 1 < args.count {
            store.config.appearance = (args[i+1] == "light") ? .light : .dark
        }
        if let i = args.firstIndex(of: "--mode"), i + 1 < args.count,
           let m = FanMode(rawValue: args[i+1]) {
            store.config.mode = m
        }
        if let i = args.firstIndex(of: "--lang"), i + 1 < args.count,
           let l = AppLanguage(rawValue: args[i+1]) {
            store.config.language = l
        }
        if let i = args.firstIndex(of: "--section"), i + 1 < args.count,
           let s = SettingsSection(rawValue: args[i+1]) {
            LaunchOptions.section = s
        }
    }
}

// AppKit entry point. There is no SwiftUI `Scene` graph: the menu-bar item and
// its panel are an NSStatusItem + NSPanel we own (see StatusPanel.swift), which
// is what lets the panel resize in lockstep with its content. Settings is a
// plain NSWindow hosting `SettingsView`.
@main
enum OmniStatsMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate      // NSApplication.delegate is a weak reference
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

private var retainedDelegate: AppDelegate?
