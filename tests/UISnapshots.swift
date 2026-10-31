import AppKit
import SwiftUI
import Sparkle

// Renders every Settings page in each language and theme to PNGs for review:
// make ui-snapshots  →  build/ui-snapshots/<page>-<language>-<theme>.png
// Isolated preferences, C hardware stubs and a canned helper reply: it never
// touches the installed app's settings or its helper. Needs a logged-in desktop.
// Test-only switches in tests/hardware_stubs.c: a current helper is installed.
@_silgen_name("cb_test_available") func cbTestAvailable(_ available: Int32)
@_silgen_name("cb_test_version") func cbTestVersion(_ version: Int32)

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
        // A capture occasionally fails while the window server is busy; retry a little.
        for attempt in 1...3 {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
            try! capture.run(); capture.waitUntilExit()
            if capture.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) { return }
            if attempt < 3 { drain(0.5) }
        }
        fatalError("Cannot capture \(url.lastPathComponent); the terminal needs Screen Recording")
    }

    // The page's scroll view: the widest one, so the sidebar never qualifies.
    @MainActor static func contentScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var found: [NSScrollView] = []
        func walk(_ v: NSView) { if let s = v as? NSScrollView { found.append(s) }; v.subviews.forEach(walk) }
        walk(view)
        return found.max { $0.frame.width < $1.frame.width }
    }

    // 30 days of believable history, shaped on measurements from an M5 Pro: held
    // at an 85 % limit on AC most of the day, an hour or two on battery at about
    // 5 % an hour, a ~2 A recharge, nights asleep (gaps). Seeded, so every run
    // draws the same charts.
    static func syntheticHistory(in directory: URL, now: TimeInterval) {
        var state: UInt64 = 0x5EED_0B57   // SplitMix64
        func random() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9; z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        let rawMax = 8132.0
        var records: [BatteryHistoryRecord] = []
        var percent = 85.0, load = 18.0
        let start = (now - 30 * 86400).rounded(.down)
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: start)).timeIntervalSince1970
        for minute in stride(from: start, through: now, by: 60) {
            let hour = (minute - midnight).truncatingRemainder(dividingBy: 86400) / 3600
            let day = Int((minute - midnight) / 86400)
            if hour >= 1 && hour < 7.5 { continue }                    // asleep
            let unplugged = (hour >= 12.5 && hour < 13.5 + Double(day % 3) * 0.5) || (day % 5 == 2 && hour >= 19 && hour < 21)
            load = min(42, max(7, load + (random() - 0.5) * 3 + (16 - load) * 0.05))
            var charging = false, power = 0.0
            if unplugged {
                power = -load * 0.45; percent = max(10, percent + power / 12.5 * 1000 / 60 / rawMax * 100)
            } else if percent < 84 {
                charging = true; power = 24 + random() * 4; percent = min(85, percent + power / 12.8 / rawMax * 1000 * 100 / 60)
            }
            let volts = 11.6 + percent / 100 * 1.6 + (charging ? 0.25 : 0)
            var record = BatteryHistoryRecord(time: UInt32(minute), percent: UInt8(percent.rounded()))
            if !unplugged { record.flags.insert(.external) }
            if charging { record.flags.insert(.charging) }
            record.flags.insert(.telemetry)
            record.temperature = Int16((28 + load * 0.18 + (charging ? 2.5 : 0) + random()) * 100)
            record.rawCurrent = UInt16(percent / 100 * rawMax); record.rawMax = UInt16(rawMax)
            record.voltage = UInt16(volts * 1000)
            record.current = Int16(power / volts * 1000)
            record.systemLoad = Int32(load * 1000); record.batteryPower = Int32(power * 1000)
            record.systemPowerIn = unplugged ? 0 : Int32((load + power) * 1000)
            records.append(record)
        }
        let snapshots = (0..<30).map { i -> BatteryHealthSnapshot in
            let date = Date(timeIntervalSince1970: start + Double(i) * 86400)
            return BatteryHealthSnapshot(day: BatteryHealthSnapshot.day(for: date.timeIntervalSince1970),
                                         nominalCapacity: UInt16(8420 - i * 36 / 29), rawMaxCapacity: UInt16(rawMax),
                                         designCapacity: 8579, cycleCount: UInt16(30 + i * 11 / 29))
        }
        try! PackedFile.write(records, to: directory.appendingPathComponent("battery-history.bin"))
        try! PackedFile.write(snapshots, to: directory.appendingPathComponent("battery-health.bin"))
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
        store.config.mode = .curve   // the Fans page's richest state

        cbTestAvailable(1); cbTestVersion(8)
        if let range = ProcessInfo.processInfo.environment["OMNISTATS_SNAPSHOT_RANGE"].flatMap(HistoryRange.init(rawValue:)) {
            BatteryPane.initialRange = range
        }
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
        let historyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("omnistats-snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        syntheticHistory(in: historyDirectory, now: Date().timeIntervalSince1970)
        let history = BatteryHistory(isPresent: true, directory: historyDirectory, read: { _ in nil })
        history.start()
        let loaded = Date().addingTimeInterval(3)
        while history.latest == nil && Date() < loaded { drain(0.05) }
        // What one refresh of the Battery page's charts costs over 30 days of records.
        let timing = BatteryHistoryModel()
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 { timing.reload(history, range: .days30, limit: 85, fahrenheit: false) }
        print(String(format: "Battery charts refresh, 30 days of records: %.1f ms (mean of 20, measured)",
                     Double(DispatchTime.now().uptimeNanoseconds - started) / 20 / 1e6))
        let settings = SettingsWindowController(mon: mon, store: store, engine: engine,
                                                updater: Updater(updater: updaterController.updater),
                                                battery: battery, charge: charge,
                                                menuBar: MenuBarManager(store: store, defaults: defaults),
                                                uninstaller: AppUninstaller(), history: history)
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
        let width = Double(ProcessInfo.processInfo.environment["OMNISTATS_SNAPSHOT_WIDTH"] ?? "") ?? 1060
        window.setFrame(NSRect(x: 40, y: 40, width: width, height: height), display: true)
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

        // The menu-bar panel, with the battery section's two-hour trend.
        if ProcessInfo.processInfo.environment["OMNISTATS_SNAPSHOT_PANEL"] != "0" {
            let resources = ResourceSampler(read: {
                ResourceSnapshot(cpuPercent: 23, memory: CapacityUsage(used: 26 * 1_073_741_824, total: 48 * 1_073_741_824),
                                 disk: CapacityUsage(used: 612e9, total: 1000e9), gpuPercent: 11)
            })
            let netProc = NetProcSampler(runnerURL: URL(fileURLWithPath: "build/omnistats-nettop"))
            let status = StatusItemController(mon: mon, store: store, engine: engine, net: NetSampler(), proc: ProcSampler(),
                                              netProc: netProc, resources: resources, battery: battery, charge: charge,
                                              history: history, onOpenSettings: {})
            for language in languages {
                for theme in themes {
                    store.config.language = language
                    store.config.appearance = theme
                    NSApp.activate(ignoringOtherApps: true)
                    if status.panel?.isVisible != true { status.openPanel() }
                    drain(0.8)
                    guard let panel = status.panel else { continue }
                    write(panel, to: directory.appendingPathComponent("panel-\(language.rawValue)-\(theme.rawValue).png"))
                    count += 1
                }
            }
            status.closePanel()
            withExtendedLifetime(status) {}
        }
        store.flush()
        print("Wrote \(count) snapshots to \(directory.path)")
    }
}
