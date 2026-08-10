import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    let store = ConfigStore()
    let updater = Updater()
    lazy var engine = Engine(monitor: monitor, store: store)

    func applicationDidFinishLaunching(_ n: Notification) {
        Theme.mode = store.config.appearance
        applyAppChrome(store.config.appearance)
        _ = engine   // start the control loop
        updater.checkAutomatically(store.config.autoCheckUpdates)

        // Launch args (used for screenshots / deep-linking).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--theme"), i + 1 < args.count {
            store.config.appearance = (args[i+1] == "light") ? .light : .dark
        }
        if let i = args.firstIndex(of: "--mode"), i + 1 < args.count,
           let m = FanMode(rawValue: args[i+1]) {
            store.config.mode = m
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
            MenuPanel(mon: delegate.monitor, store: delegate.store, engine: delegate.engine)
        } label: {
            MenuLabel(mon: delegate.monitor)
        }
        .menuBarExtraStyle(.window)

        Window("OmniStats 设置", id: "settings") {
            SettingsView(mon: delegate.monitor, store: delegate.store, engine: delegate.engine, updater: delegate.updater)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}
