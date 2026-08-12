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

    func applicationDidFinishLaunching(_ n: Notification) {
        syncPresentation(store.config)
        _ = engine   // start the control loop

        // Launch args (used for screenshots / deep-linking).
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
        if args.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NotificationCenter.default.post(name: .openOmniSettings, object: nil)
            }
        }
    }
    func applicationWillTerminate(_ n: Notification) {
        monitor.revertAll()
    }
}

@main
struct OmniStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(mon: delegate.monitor, store: delegate.store, engine: delegate.engine,
                      net: delegate.net, proc: delegate.proc, netProc: delegate.netProc)
        } label: {
            MenuLabel(mon: delegate.monitor, store: delegate.store, net: delegate.net)
        }
        .menuBarExtraStyle(.window)

        Window(L.t("settings.window"), id: "settings") {
            SettingsView(mon: delegate.monitor, store: delegate.store, engine: delegate.engine, updater: delegate.updater)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}
