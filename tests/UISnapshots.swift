import AppKit
import SwiftUI
import Sparkle

// Renders every Settings page in each language and theme to PNGs for review:
// make ui-snapshots  →  build/ui-snapshots/<page>-<language>-<theme>.png
// Isolated preferences, C hardware stubs and a canned helper reply: it never
// touches the installed app's settings or its helper. Needs a logged-in desktop.
@main
enum UISnapshots {
    @MainActor static func drain(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        } while Date() < deadline
    }

    // cacheDisplay misses layer-backed SwiftUI content inside scroll views, so ask
    // the window server for exactly this window, as it is on screen.
    @MainActor static func write(_ window: NSWindow, to url: URL) {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
        try! capture.run(); capture.waitUntilExit()
        guard capture.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            fatalError("Cannot capture \(url.lastPathComponent); the terminal needs Screen Recording")
        }
    }

    // The page's scroll view: the widest one, so the sidebar never qualifies.
    @MainActor static func contentScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var found: [NSScrollView] = []
        func walk(_ v: NSView) { if let s = v as? NSScrollView { found.append(s) }; v.subviews.forEach(walk) }
        walk(view)
        return found.max { $0.frame.width < $1.frame.width }
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        if let icon = NSImage(contentsOfFile: "icons/AppIcon.icns") { app.applicationIconImage = icon }

        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMNISTATS_SNAPSHOT_DIR"] ?? "build/ui-snapshots")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "OmniStats.UISnapshots.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigStore(defaults: defaults)
        store.config.showProcesses = false

        let mon = Monitor()
        let engine = Engine(monitor: mon, store: store)
        // Values measured on an M5 Pro MacBook Pro, held at an 85 % limit on a 140 W adapter.
        let battery = BatterySampler(isPresent: true, read: {
            BatterySnapshot(registry: [
                "ExternalConnected": true, "IsCharging": false, "FullyCharged": false,
                "CurrentCapacity": 85, "MaxCapacity": 100, "AppleRawCurrentCapacity": 6912, "AppleRawMaxCapacity": 8132,
                "CycleCount": 41, "DesignCycleCount9C": 1000, "DesignCapacity": 8579, "NominalChargeCapacity": 8384,
                "Temperature": 3035, "Voltage": 12836, "Amperage": 0,
                "AdapterDetails": ["Watts": 140, "Name": "140W USB-C Power Adapter"],
                "PowerTelemetryData": ["SystemPowerIn": 21062, "SystemLoad": 21062, "AdapterEfficiencyLoss": 111],
            ])
        })
        let status = "OK backend=chte enabled=1 limit=85 sailing=5 sleepstop=1 stayawake=1 heat=1 heatlimit=45 led=1 "
            + "topup=0 inhibited=1 heatheld=0 percent=85 external=1 charging=0 temp=3035 ledsupported=1 adapter=1 cut=0 "
            + "plugged=1 discharge=0 autodischarge=1 calibration=0 calelapsed=0 calresult=0 conflict=- writefailed=0"
        let charge = ChargeController(monitor: mon, request: { command, reply in reply(command == "BSTATUS" ? status : "OK") },
                                      readNativeLimit: { 100 })
        let updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let settings = SettingsWindowController(mon: mon, store: store, engine: engine,
                                                updater: Updater(updater: updaterController.updater),
                                                battery: battery, charge: charge,
                                                menuBar: MenuBarManager(store: store, defaults: defaults))
        battery.setSamplingInterval(60)
        charge.refresh(forceNative: true)

        let pages = ProcessInfo.processInfo.environment["OMNISTATS_SNAPSHOT_PAGES"]
            .map { $0.split(separator: ",").compactMap { SettingsSection(rawValue: String($0)) } } ?? SettingsSection.allCases
        let languages: [AppLanguage] = [.zhHans, .en, .ja]
        let themes: [AppearanceMode] = [.dark, .light]
        settings.show(section: pages.first)
        guard let window = settings.window else { fatalError("Settings did not open") }
        // Tall enough to show a whole page; review the default size separately.
        let height = Double(ProcessInfo.processInfo.environment["OMNISTATS_SNAPSHOT_HEIGHT"] ?? "") ?? 1100
        window.setFrame(NSRect(x: 40, y: 40, width: 900, height: height), display: true)
        drain(1)

        var count = 0
        for language in languages {
            for theme in themes {
                store.config.language = language
                store.config.appearance = theme
                for page in pages {
                    settings.show(section: page)
                    window.orderFrontRegardless()
                    drain(0.6)
                    let name = "\(page.rawValue)-\(language.rawValue)-\(theme.rawValue)"
                    write(window, to: directory.appendingPathComponent(name + ".png"))
                    count += 1
                    // A page taller than the screen gets a second shot of its end.
                    if let scroll = contentScrollView(in: window.contentView), let document = scroll.documentView,
                       document.frame.height > scroll.contentView.bounds.height + 1 {
                        let bottom = document.isFlipped ? document.frame.height - scroll.contentView.bounds.height : 0
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        drain(0.4)
                        write(window, to: directory.appendingPathComponent(name + "-end.png"))
                        count += 1
                    }
                }
            }
        }
        settings.window?.close()
        store.flush()
        print("Wrote \(count) snapshots to \(directory.path)")
    }
}
