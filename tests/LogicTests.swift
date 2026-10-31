import AppKit
import Foundation
import Carbon.HIToolbox

@main
struct LogicTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func wait(_ complete: () -> Bool, seconds: Double = 2, line: UInt = #line) {
        let end = Date().addingTimeInterval(seconds)
        while !complete() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(complete(), "Asynchronous operation at line \(line) did not finish")
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        var config = OmniStatsConfig()
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let detailSize = CGSize(width: 300, height: 320)
        let dashboard = NSRect(x: 1000, y: 300, width: 300, height: 548)
        let adjacent = NetworkPanelLayout.frame(beside: dashboard, contentSize: detailSize, visible: screen)
        check(adjacent.maxX == dashboard.minX - 8 && adjacent.maxY == dashboard.maxY,
              "Network details prefer the left side with an 8-point gap and aligned tops")
        let leftEdge = NSRect(x: 8, y: 300, width: 300, height: 548)
        let flipped = NetworkPanelLayout.frame(beside: leftEdge, contentSize: detailSize, visible: screen)
        check(flipped.minX == leftEdge.maxX + 8, "Network details fall back to the right without moving the dashboard")
        let shortScreen = NSRect(x: -1440, y: -200, width: 1440, height: 260)
        let shortParent = NSRect(x: -320, y: -140, width: 300, height: 200)
        let boundedDetail = NetworkPanelLayout.frame(beside: shortParent, contentSize: detailSize, visible: shortScreen)
        check(shortScreen.contains(boundedDetail) && boundedDetail.height < detailSize.height,
              "Network details fit short screens and negative monitor coordinates")
        let narrow = NSRect(x: 0, y: 0, width: 640, height: 900)
        check(narrow.contains(NetworkPanelLayout.frame(beside: NSRect(x: 170, y: 300, width: 300, height: 548),
              contentSize: detailSize, visible: narrow)), "Narrow-screen fallback keeps details visible")
        check(RefreshMode.balanced.title == L.t("refresh.balanced"), "Refresh titles must be localized")
        func policy(panel: Bool = false, display: Bool = false, asleep: Bool = false, lowPower: Bool = false) -> SamplingPolicy {
            SamplingPolicy(config: config, panelVisible: panel, settingsVisible: false,
                displayAsleep: display, systemAsleep: asleep, lowPower: lowPower)
        }
        check(policy().sensors == 10 && policy().network == 3 && policy().processes == 10, "Balanced background cadence")
        check(policy(panel: true).sensors == 10 && policy(panel: true).network == 3 && policy(panel: true).processes == 10, "Visible panel cadence")
        check(policy(lowPower: true).sensors == 30 && policy(lowPower: true).network == 10 && policy(lowPower: true).processes == 30, "Low Power Mode")
        config.refreshMode = .economical
        check(policy().sensors == 30 && policy().network == 10 && policy().processes == 30, "Eco background cadence")
        check(policy(panel: true, lowPower: true).sensors == 10 && policy(panel: true).network == 3
              && policy(panel: true).processes == 10, "Visible panels always use default cadence")
        config.refreshMode = .balanced
        config.showNetworkInMenuBar = false; config.showNetworkPanel = false
        check(policy(panel: true).network == nil, "Hidden network must stop its timer")
        config.cpuWindow = .realtime
        check(policy().processes == nil && policy(panel: true).processes == 10, "Hidden realtime ranking must stop")
        config.mode = .curve
        check(policy(display: true).sensors == nil && policy(display: true).controlSensors == 2 && policy(display: true).network == nil, "Screen sleep must preserve active control sampling")
        check(policy(asleep: true).sensors == nil, "System sleep must stop sampling")
        check(policy(asleep: true).controlSensors == nil, "System sleep also stops control sensor reads")
        config.mode = .manual
        check(policy().controlSensors == nil && policy().sensors == 10, "Fixed manual speed does not need rapid temperature reads")
        config.manualPct = .infinity; config.rampUpPctPerSec = -10; config.deadbandPct = 999
        let id = UUID()
        config.curve = [.init(id: id, temp: 40, pct: -20), .init(id: id, temp: 40, pct: 10),
                        .init(id: id, temp: 60, pct: 150), .init(temp: .nan, pct: 10)]
        let sanitized = config.validated()
        check(sanitized.manualPct == 40 && sanitized.rampUpPctPerSec == 2 && sanitized.deadbandPct == 10, "Numeric bounds")
        check(sanitized.curve.count == 2 && sanitized.curve[0].pct == 0 && sanitized.curve[1].pct == 100, "Curve validation")
        check(Set(sanitized.curve.map(\.id)).count == 2, "Curve IDs must remain unique")
        check(sanitized.curvePct(at: .nan).isNaN, "Invalid temperature must not select the hottest curve point")
        let oldConfig = try! JSONDecoder().decode(OmniStatsConfig.self, from: Data("{}".utf8))
        check(oldConfig.refreshMode == .balanced, "Old configs must acquire the new default")
        check(RefreshMode.responsive.intervals == (3, 1, 5) && RefreshMode.economical.intervals == (30, 10, 30),
              "General's refresh table shows the intervals sampling uses")
        let presentation = (Theme.mode, Theme.accentPreset, L.lang)
        let followSystem = try! JSONDecoder().decode(OmniStatsConfig.self, from: Data(#"{"appearance":"system"}"#.utf8))
        check(followSystem.appearance == .system && oldConfig.appearance == .dark, "Follow-system decodes; old configs stay dark")
        syncPresentation(followSystem)
        check(Theme.mode != .system && AppearanceMode.system.colorScheme == (Theme.mode == .light ? .light : .dark),
              "Following the system resolves to dark or light")
        syncPresentation(oldConfig)
        check(Theme.mode == .dark && AppearanceMode.light.colorScheme == .light, "A fixed appearance wins over the system")
        (Theme.mode, Theme.accentPreset, L.lang) = presentation

        for values: [CGFloat] in [[0, 1, 8, 8, 3, 0], [10, 10, 10], [100, 0, 100], [0, 1]] {
            let points = values.enumerated().map { CGPoint(x: CGFloat($0.offset * $0.offset + $0.offset), y: $0.element) }
            let curves = SmoothHistory.segments(points)
            check(curves.count == points.count-1, "Smoothing retains every measured interval")
            for (i, curve) in curves.enumerated() {
                check(curve.start == points[i] && curve.end == points[i+1], "Interpolation must pass through the measurements")
                let low = min(curve.start.y, curve.end.y), high = max(curve.start.y, curve.end.y)
                for step in 0...100 {
                    let p = curve.point(at: CGFloat(step)/100)
                    check(p.y >= low-1e-8 && p.y <= high+1e-8, "Smooth history must not invent extrema")
                }
            }
        }
        check(SmoothHistory.segments([.zero]).isEmpty, "A single sample cannot form a curve")
        check(CapacityUsage(used: 20, total: 10) == nil && CapacityUsage(used: 0, total: 0) == nil, "Invalid capacities must be unavailable")
        check(CapacityUsage(used: 4, total: 8)?.fraction == 0.5, "Capacity fractions")
        check(ResourceReader.validGPUPercent(0) == 0 && ResourceReader.validGPUPercent(100) == 100
              && ResourceReader.validGPUPercent(.nan) == nil && ResourceReader.validGPUPercent(101) == nil, "GPU telemetry validation")
        var cpu = SystemCPUUsage()
        let baseline = CPUUsageCounters(user: 100, system: 50, idle: 850, nice: 0)
        let busy30 = CPUUsageCounters(user: 120, system: 60, idle: 920, nice: 0)
        check(cpu.consume(baseline) == nil, "CPU requires an interval, not an average since boot")
        check(cpu.consume(busy30) == 30, "CPU must normalize aggregate busy ticks to 0...100")
        check(cpu.consume(busy30) == nil, "An empty CPU interval must not report zero usage")
        check(cpu.consume(CPUUsageCounters(user: 120, system: 60, idle: 1020, nice: 0)) == 0, "Fully idle CPU")
        check(cpu.consume(CPUUsageCounters(user: 220, system: 60, idle: 1020, nice: 0)) == 100, "Fully busy CPU")
        check(cpu.consume(CPUUsageCounters(user: 220, system: 60, idle: 1070, nice: 50)) == 50, "Nice time counts as busy")
        check(cpu.consume(nil) == nil && cpu.needsBaseline, "Failed CPU reads invalidate the baseline")
        check(cpu.consume(baseline) == nil, "CPU recovery must establish a fresh interval")
        var wrappingCPU = SystemCPUUsage()
        _ = wrappingCPU.consume(CPUUsageCounters(user: .max - 5, system: 0, idle: 100, nice: 0))
        check(wrappingCPU.consume(CPUUsageCounters(user: 4, system: 0, idle: 110, nice: 0)) == 50,
              "CPU tick wrap must retain the correct delta")
        var wideCPU = SystemCPUUsage()
        _ = wideCPU.consume(CPUUsageCounters(user: 0, system: 0, idle: 0, nice: 0))
        check(wideCPU.consume(CPUUsageCounters(user: .max, system: .max, idle: .max, nice: .max)) == 75,
              "Aggregate CPU deltas must not overflow 32 bits")
        let liveResources = ResourceReader().sample()
        check(liveResources.memory != nil && liveResources.disk != nil, "Read-only memory and startup capacity APIs must work")
        check(liveResources.cpuWarmingUp && liveResources.cpuPercent == nil, "Live CPU API must establish a baseline")
        let liveResourceSampler = ResourceSampler()
        liveResourceSampler.setSamplingInterval(10)
        wait { liveResourceSampler.snapshot.cpuPercent != nil }
        check((0...100).contains(liveResourceSampler.snapshot.cpuPercent!) && !liveResourceSampler.snapshot.cpuWarmingUp,
              "Live CPU utilization must be ready before the normal 10-second interval")
        liveResourceSampler.setSamplingInterval(nil)
        print("Resource API smoke test: CPU, memory and disk available; GPU available: \(liveResources.gpuPercent != nil)")
        let gate = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
        var resourceReads = 0
        let resourceSampler = ResourceSampler(read: {
            resourceReads += 1
            if resourceReads == 1 { started.signal(); gate.wait() }
            return ResourceSnapshot(memory: CapacityUsage(used: 4, total: 8), disk: nil, gpuPercent: 25)
        })
        check(resourceSampler.samplingInterval == nil, "Resources must not sample before opening a panel")
        resourceSampler.setSamplingInterval(10)
        check(started.wait(timeout: .now()+1) == .success, "Resource sampling runs asynchronously")
        resourceSampler.setSamplingInterval(nil); resourceSampler.setSamplingInterval(10)
        gate.signal()
        wait { resourceSampler.hasSample }
        check(resourceReads == 2 && resourceSampler.snapshot.gpuPercent == 25, "Quick reopen must discard stale work and prime a fresh resource snapshot")
        // Tick counters can stall for ~1 s: empty follow-ups keep warming up.
        var warmupReads = 0
        let warming = ResourceSampler(read: {
            warmupReads += 1
            return warmupReads < 4 ? ResourceSnapshot(cpuWarmingUp: true) : ResourceSnapshot(cpuPercent: 12)
        })
        warming.setSamplingInterval(10)
        wait { warming.snapshot.cpuPercent == 12 }
        check(warmupReads == 4, "Empty CPU intervals must follow up until a value arrives")
        warming.setSamplingInterval(nil)
        var stalledReads = 0
        let stalled = ResourceSampler(read: { stalledReads += 1; return ResourceSnapshot(cpuWarmingUp: true) })
        stalled.setSamplingInterval(10)
        wait({ stalledReads > ResourceSampler.maximumWarmups }, seconds: 4)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check(stalledReads == ResourceSampler.maximumWarmups + 1, "CPU warm-up follow-ups must be bounded")
        stalled.setSamplingInterval(nil)
        resourceSampler.setSamplingInterval(nil)

        var warmingReads = 0
        let warmingSampler = ResourceSampler(read: {
            warmingReads += 1
            return ResourceSnapshot(cpuWarmingUp: true)
        })
        warmingSampler.setSamplingInterval(10)
        wait { warmingSampler.hasSample }
        warmingSampler.setSamplingInterval(nil)
        let cancellationDeadline = Date().addingTimeInterval(0.3)
        while Date() < cancellationDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(warmingReads == 1, "Closing the panel must cancel the CPU warmup follow-up")

        var history = CPUHistory()
        history.record(["App": 100], from: 0, to: 2)
        history.record([:], from: 2, to: 12)
        check(abs(history.average(window: 12, now: 12)["App"]! - 100.0/6) < 0.001, "CPU averages must be duration weighted")
        check(history.average(window: 5, now: 12)["App"] == nil, "Window clipping must exclude old CPU time")
        check(history.average(window: 0, now: 12).isEmpty, "Realtime must use only the latest interval")
        let series = MetricSeries(retention: 100, capacity: 20)
        for i in 0..<1000 { series.record(Double(i), at: Double(i)) }
        check(series.samples.count == 20 && series.samples.first?.t == 980, "History capacity")
        series.record(.infinity, at: 1000)
        check(series.samples.count == 20, "Nonfinite samples must be rejected")
        series.record(1, at: 1)
        check(series.samples.count == 1 && series.latest == 1, "Backward test clocks must reset history")

        let chartSamples = [TimedSample(t: 0, v: 1, cadence: 10), TimedSample(t: 10, v: 2, cadence: 10),
                            TimedSample(t: 60, v: 3, cadence: 10)]
        check(segments(chartSamples, from: 0).map(\.count) == [2, 1], "Eco chart cadence must remain continuous, with sleep gaps separated")

        let net = NetSampler(); net.setSamplingInterval(nil)
        net.accept(["en7": .init(rx: 1000, tx: 100)], at: 100)
        net.accept(["en7": .init(rx: 3000, tx: 300)], at: 102)
        check(net.rxBps == 1000 && net.txBps == 100 && net.iface == "en7", "Rate must use actual elapsed time")
        net.accept(["en7": .init(rx: 10, tx: 10)], at: 104)
        check(net.rxBps == 0, "Counter reset must not spike")
        net.accept([:], at: 106)
        check(net.iface.isEmpty && net.txBps == 0, "Removed interface must clear")

        var parser = NetTopParser(), rates = NetTopRates()
        check(parser.consume(Data("bytes_in bytes_out\nApp Helper.42 100 ".utf8), at: 10).isEmpty, "Partial rows")
        var frames = parser.consume(Data("200\nbytes_in bytes_out\nApp Helper.42 300 600\n".utf8), at: 12)
        check(frames.count == 1 && frames[0].counters[42]?.rx == 100, "Names containing spaces")
        check(rates.consume(frames[0], name: { _ in "App" }) == nil, "First network frame is a baseline")
        frames = parser.consume(Data("bytes_in bytes_out\n".utf8), at: 14)
        let ranked = rates.consume(frames[0], name: { _ in "App" })!
        check(ranked.first?.rxBps == 100 && ranked.first?.txBps == 200, "Per-process network rate")
        var malformed = NetTopParser()
        _ = malformed.consume(Data(repeating: 65, count: 5000), at: 1)
        check(malformed.overflowed, "Unterminated lines must be bounded")

        cb_test_reset(); cb_test_available(1)
        var clock = sampleTime()
        let control = ControlChannel(now: { clock })
        func command(_ plan: ControlPlan) -> Bool {
            var answer: Bool?
            control.submit(plan) { answer = $0 }
            wait { answer != nil }
            return answer!
        }
        check(command(.manual(rpms: [3000, 3000], validUntil: sampleTime()+10)), "Manual command")
        check(cb_test_sets() == 2, "Set each fan once")
        check(command(.manual(rpms: [3000, 3000], validUntil: sampleTime()+10)), "Stable command heartbeat")
        check(cb_test_sets() == 2 && cb_test_heartbeats() == 1, "Stable targets must heartbeat rather than write")
        clock += 13
        check(command(.manual(rpms: [3000, 3000], validUntil: clock+10)) && cb_test_sets() == 4,
              "Long control gaps must reapply targets even on the same connection")
        clock = sampleTime()
        cb_test_reconnect()
        check(command(.manual(rpms: [3000, 3000], validUntil: sampleTime()+10)) && cb_test_sets() == 6, "Reconnect must reapply all targets")
        check(command(.manual(rpms: [4000, 4000], validUntil: sampleTime()-1)) && cb_test_sets() == 6 && cb_test_autos() > 0, "Expired target must revert")
        cb_test_fail_set(1)
        check(!command(.manual(rpms: [4000, 4000], validUntil: sampleTime()+10)), "Failed write must report failure")
        check(cb_test_autos() >= 2, "Failed write must request automatic control")
        cb_test_fail_set(0)
        let beforeCoalescing = cb_test_sets()
        var lastCompleted = false, obsoleteCompleted = false
        control.submit(.manual(rpms: [3100,3100], validUntil: clock+10)) { _ in }
        control.submit(.manual(rpms: [3200,3200], validUntil: clock+10)) { _ in obsoleteCompleted = true }
        control.submit(.automatic) { _ in lastCompleted = true }
        wait { lastCompleted }
        check(!obsoleteCompleted && cb_test_sets() == beforeCoalescing+2, "Latest automatic intention must discard obsolete manual targets")
        control.shutdown()

        let suite = "OmniStats.LogicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ConfigStore(defaults: defaults)
        defer { store.flush(); defaults.removePersistentDomain(forName: suite) }
        let monitor = Monitor(startSampling: false)
        var snapshot = Monitor.Snapshot()
        snapshot.socMax = 60; snapshot.fanRPM = [1500,1500]
        snapshot.fanMin = [1200,1200]; snapshot.fanMax = [6000,6000]
        snapshot.fanMode = [0,0]
        monitor.accept(snapshot)
        let engine = Engine(monitor: monitor, store: store)
        check(!engine.isRunning, "Automatic fan mode must not run a control timer")
        store.config.mode = .curve
        wait { engine.isRunning }
        engine.step(at: snapshot.time + 7)
        check(engine.safetyPaused, "Stale curve input must pause control")
        snapshot.time = sampleTime(); monitor.accept(snapshot); engine.step(at: snapshot.time)
        check(!engine.safetyPaused, "Fresh input must resume curve control")
        engine.setSuspended(true)
        check(!engine.isRunning, "System sleep must stop the control timer")
        store.config.mode = .auto
        store.flush()
        let saved = try! JSONDecoder().decode(OmniStatsConfig.self, from: defaults.data(forKey: "OmniStatsConfig.v1")!)
        check(saved.mode == .auto, "Flush must persist final config")
        cb_test_sensor_delay(200)
        let start = sampleTime(); monitor.refresh()
        check(sampleTime() - start < 0.05, "Sensor I/O must not block its caller")
        var responsive = false
        DispatchQueue.main.async { responsive = true }
        wait({ responsive }, seconds: 0.1)
        wait { monitor.lastSampleTime > snapshot.time }
        cb_test_sensor_delay(0)
        let publishedTemperature = monitor.socMax, publishedTime = monitor.lastSampleTime
        var internalSample = snapshot; internalSample.time = sampleTime(); internalSample.socMax = 85
        monitor.accept(internalSample, publish: false)
        check(monitor.socMax == publishedTemperature && monitor.lastSampleTime == publishedTime, "Control sampling must not speed up display publication")
        check(monitor.latestSnapshot?.socMax == 85 && monitor.hasFreshTemperature(at: internalSample.time), "Control must consume the fresh internal temperature")
        monitor.setSamplingInterval(30, controlInterval: 2)
        check(monitor.samplingInterval == 30 && monitor.hardwareSamplingInterval == 2, "Eco display and curve safety cadence must remain independent")
        monitor.setSamplingInterval(nil)
        check(monitor.latestSnapshot == nil, "Sleep must invalidate internal control temperature")
        monitor.shutdown()
        check(HelperInstaller.shellQuote("a'b") == "'a'\\''b'", "Shell paths containing quotes")
        let home = "/Users/tester"
        check(LoginItem.isInstalled(bundlePath: "/Applications/OmniStats.app", home: home), "System Applications is an installed copy")
        check(LoginItem.isInstalled(bundlePath: "/Users/tester/Applications/OmniStats.app", home: home), "User Applications is an installed copy")
        check(!LoginItem.isInstalled(bundlePath: "/private/var/folders/x/AppTranslocation/1234/d/OmniStats.app", home: home), "Translocated copies must not register")
        check(!LoginItem.isInstalled(bundlePath: "/Volumes/OmniStats/OmniStats.app", home: home), "The mounted DMG must not register")
        check(!LoginItem.isInstalled(bundlePath: "/Users/tester/Downloads/OmniStats.app", home: home), "Downloads must not register")
        check(!LoginItem.isInstalled(bundlePath: "/Applications/../tmp/OmniStats.app", home: home), "Paths are normalized before matching")
        check(!LoginItem.isInstalled(bundlePath: "/ApplicationsX/OmniStats.app", home: home), "Prefix match needs a folder boundary")

        let charging = BatterySnapshot(registry: [
            "ExternalConnected": true, "IsCharging": true, "FullyCharged": false,
            "CurrentCapacity": 50, "MaxCapacity": 100, "AppleRawCurrentCapacity": 4000, "AppleRawMaxCapacity": 8000,
            "AvgTimeToFull": 90, "AvgTimeToEmpty": 65535, "Amperage": 2000, "Voltage": 12000,
            "NominalChargeCapacity": 8300, "DesignCapacity": 8579, "CycleCount": 40, "DesignCycleCount9C": 1000,
            "Temperature": 3046,
            "AdapterDetails": ["Watts": 140, "Name": "140W USB-C Power Adapter"] as [String: Any],
            "PowerTelemetryData": ["SystemPowerIn": 35447, "SystemLoad": 30000, "AdapterEfficiencyLoss": 681],
        ])
        check(charging.state == .charging && charging.percent == 50 && charging.hardwarePercent == 50, "Charging state and percentages")
        check(charging.timeToFullMinutes == 90 && charging.timeToEmptyMinutes == nil, "Only the relevant time estimate is shown")
        check(charging.batteryPower == 24 && charging.amperage == 2 && charging.voltage == 12, "Battery power is voltage × current")
        check(abs((charging.health ?? 0) - 8300.0 / 8579.0 * 100) < 1e-9 && charging.cycleCount == 40, "Health is nominal ÷ design capacity")
        check(charging.temperature == 30.46 && charging.adapterWatts == 140, "Temperature in 0.01 °C, adapter rating")
        check(charging.systemPowerIn == 35.447 && charging.systemLoad == 30 && charging.adapterLoss == 0.681, "Power telemetry in mW")
        // IOKit hands negative currents over as 64-bit two's complement.
        let discharging = BatterySnapshot(registry: [
            "ExternalConnected": false, "IsCharging": false, "CurrentCapacity": 70, "MaxCapacity": 100,
            "Amperage": NSNumber(value: UInt64(18446744073709540042)), "Voltage": 12000,
            "AvgTimeToEmpty": 200, "AdapterDetails": ["Watts": 140] as [String: Any],
        ])
        check(discharging.state == .discharging && discharging.amperage == -11.574, "Two's-complement current is negative")
        check(abs((discharging.batteryPower ?? 0) + 138.888) < 1e-9, "Discharging power is negative")
        check(discharging.timeToEmptyMinutes == 200 && discharging.adapterWatts == nil, "No adapter details on battery power")
        let held = BatterySnapshot(registry: ["ExternalConnected": true, "IsCharging": false, "FullyCharged": false, "AvgTimeToFull": 65535])
        check(held.state == .notCharging && held.timeToFullMinutes == nil, "Plugged in but held below full")
        check(BatterySnapshot(registry: ["ExternalConnected": true, "FullyCharged": true]).state == .charged, "Fully charged")
        let invalid = BatterySnapshot(registry: [
            "CurrentCapacity": 50, "MaxCapacity": 0, "DesignCapacity": 0, "NominalChargeCapacity": 8000,
            "Temperature": 99999, "Voltage": 0, "AppleRawMaxCapacity": 0, "AppleRawCurrentCapacity": 10,
        ])
        check(invalid.percent == nil && invalid.health == nil && invalid.temperature == nil, "Invalid readings are unavailable")
        check(invalid.voltage == nil && invalid.batteryPower == nil && invalid.hardwarePercent == nil, "No zero-division or fake zeros")
        check(BatterySnapshot(registry: [:]) == BatterySnapshot(), "Empty registry reads as nothing")
        check(formatBatteryMinutes(80) == L.f("b.hm", 1, 20) && formatBatteryMinutes(45) == L.f("b.m", 45), "Battery time format")
        let batterySampler = BatterySampler(isPresent: true, read: { charging })
        batterySampler.setSamplingInterval(5)
        wait { batterySampler.hasSample }
        check(batterySampler.snapshot == charging && batterySampler.samplingInterval == 5, "Battery sampler publishes readings")
        batterySampler.setSamplingInterval(nil)
        check(batterySampler.samplingInterval == nil && batterySampler.snapshot == charging, "Pausing keeps the last reading")
        let statusLine = "OK backend=chte enabled=1 limit=80 sailing=5 sleepstop=0 stayawake=1 heat=1 heatlimit=42 led=1 topup=0 "
            + "inhibited=1 heatheld=0 percent=85 external=1 charging=0 temp=3125 ledsupported=1 adapter=1 cut=1 plugged=1 "
            + "discharge=60 autodischarge=1 calibration=3 calelapsed=900 calresult=0 conflict=- writefailed=0"
        let status = ChargeControlStatus(reply: statusLine)
        check(status?.backend == .chte && status?.settings == ChargeLimitSettings(enabled: true, limit: 80, sailing: 5, sleepStop: false,
              stayAwake: true, heatProtect: true, heatLimit: 42, ledMode: .status, autoDischarge: true), "Charge-control status parses settings")
        check(status?.adapterSupported == true && status?.adapterCut == true && status?.plugged == true && status?.dischargeTarget == 60
              && status?.calibration == .discharge && status?.calibrationElapsed == 900 && status?.percent == 85,
              "Adapter, discharge and calibration state")
        check(ChargeControlStatus(reply: statusLine.replacingOccurrences(of: "percent=85", with: "percent=0"))?.percent == nil,
              "An unknown charge shows no progress")
        let savedLanguage = L.lang; L.lang = .en
        if var calibrating = ChargeControlStatus(reply: statusLine.replacingOccurrences(of: "percent=85", with: "percent=99")) {
            calibrating.calibration = .charge1; calibrating.calibrationElapsed = 61 * 60
            check(DischargeCard.calibrationText(calibrating) == "Calibrating · Step 1/5: charging to 100% · now 99%, 61 min so far",
                  "Calibration shows charge and time: \(DischargeCard.calibrationText(calibrating))")
            calibrating.calibration = .discharge
            check(DischargeCard.calibrationText(calibrating) == "Calibrating · Step 3/5: discharging to 15% · now 99%", "Discharge shows the charge")
        } else { check(false, "Calibration status parses") }
        L.lang = savedLanguage
        check(ChargeControlStatus(reply: statusLine.replacingOccurrences(of: "discharge=60", with: "discharge=0"))?.dischargeTarget == nil
              && ChargeControlStatus(reply: statusLine.replacingOccurrences(of: "calibration=3", with: "calibration=9")) == nil,
              "No session reads as nil; unknown calibration phases are rejected")
        check(status?.inhibited == true && status?.topUp == false && status?.heatHeld == false && status?.charging == false
              && status?.conflict == nil && status?.writeFailed == false, "Charge-control state flags")
        check(status?.temperature == 31.25 && status?.ledSupported == true, "Battery temperature and LED support")
        check(ChargeControlStatus(reply: statusLine.replacingOccurrences(of: "temp=3125", with: "temp=0"))?.temperature == nil,
              "Unknown temperature stays unknown")
        check(ChargeControlStatus(reply: statusLine.replacingOccurrences(of: "led=1", with: "led=7")) == nil, "Unknown LED modes are rejected")
        check(ChargeControlStatus(reply: statusLine.replacingOccurrences(of: "conflict=-", with: "conflict=AlDente"))?.conflict == "AlDente",
              "A running charge manager is reported by name")
        check(ChargeControlStatus(reply: "ERR command") == nil && ChargeControlStatus(reply: "OK backend=chte") == nil
              && ChargeControlStatus(reply: statusLine.replacingOccurrences(of: "backend=chte", with: "backend=magic")) == nil
              && ChargeControlStatus(reply: statusLine.replacingOccurrences(of: "limit=80", with: "limit=eighty")) == nil
              && ChargeControlStatus(reply: "OK backend=chte enabled=1 limit=80 sailing=5 sleepstop=0 stayawake=1 topup=0 inhibited=1 percent=85 external=1 conflict=- writefailed=0") == nil,
              "Old helpers and malformed status lines are not trusted")
        let limitSettings = ChargeLimitSettings(enabled: true, limit: 75, sailing: 3, sleepStop: true, stayAwake: false,
                                                heatProtect: true, heatLimit: 38, ledMode: .off)
        check(limitSettings.command == "BSET enabled=1 limit=75 sailing=3 sleepstop=1 stayawake=0 heat=1 heatlimit=38 led=2 autodischarge=0"
              && limitSettings.resumeAt == 72,
              "Settings serialize to one BSET line")
        let pmsetOutput = """
        Battery level limits:
        (
                {
                Terminated = 0;
                chargeSocLimitDrain = 1;
                chargeSocLimitOwner = 182;
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 85;
            },
                {
                Terminated = 0;
                chargeSocLimitOwner = 0;
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 90;
            },
                {
                Terminated = 0;
                chargeSocLimitReason = obc;
                chargeSocLimitSoc = 80;
            },
                {
                Terminated = 1;
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 60;
            }
        )
        """
        check(NativeChargeLimit.parse(pmsetOutput) == 85, "Native limit: lowest active manual limit, ignoring other reasons and ended ones")
        check(NativeChargeLimit.parse("No battery level limits set\n") == nil && NativeChargeLimit.parse("") == nil, "No native limit")
        var sentCommands: [String] = []
        let chargeController = ChargeController(monitor: Monitor(startSampling: false), request: { command, completion in
            sentCommands.append(command)
            completion(command == "BSTATUS" ? statusLine : command.contains("limit=19") ? "ERR args" : "OK")
        }, readNativeLimit: { 85 })
        chargeController.setPollingInterval(5)
        wait { chargeController.status != nil && chargeController.nativeLimit == 85 }
        check(chargeController.status?.settings.limit == 80 && chargeController.pollingInterval == 5, "Charge control polls the helper and pmset")
        chargeController.apply(limitSettings)
        check(sentCommands.contains(limitSettings.command) && chargeController.lastError == nil, "Edits go to the helper as one BSET")
        var rejected = limitSettings; rejected.limit = 19
        chargeController.apply(rejected)
        check(chargeController.lastError == "ERR args", "Helper rejections surface to the user")
        chargeController.setTopUp(true)
        check(sentCommands.last == "BSTATUS" && sentCommands.contains("BTOPUP 1") && chargeController.lastError == nil,
              "Top Up is sent and the status refreshed")
        chargeController.setPollingInterval(nil)
        check(chargeController.pollingInterval == nil, "Hidden charge control stops polling")
        // omnistats:// automation links.
        func link(_ text: String) -> AutomationCommand? { URL(string: text).flatMap(AutomationCommand.init(url:)) }
        check(link("omnistats://battery/limit?value=80") == .setLimit(80) && link("OMNISTATS://Battery/Limit?Value=75") == .setLimit(75),
              "Limit links, case-insensitive")
        check(link("omnistats://battery/enable") == .enableLimit(true) && link("omnistats://battery/disable") == .enableLimit(false), "Enable links")
        check(link("omnistats://battery/topup") == .topUp(true) && link("omnistats://battery/topup?enabled=0") == .topUp(false), "Top Up links")
        check(link("omnistats://battery/led?mode=off") == .led(.off) && link("omnistats://settings/battery") == .openBatterySettings, "LED and settings links")
        for bad in ["omnistats://battery/limit?value=19", "omnistats://battery/limit?value=101", "omnistats://battery/limit",
                    "omnistats://battery/discharge", "omnistats://battery/topup?enabled=maybe", "omnistats://battery/led?mode=blink",
                    "https://battery/limit?value=80", "omnistats://fans/limit?value=80"] {
            check(link(bad) == nil, "Rejected link: \(bad)")
        }
        check(AutomationCommand.setLimit(80).helperCommand == "BSET enabled=1 limit=80"
              && AutomationCommand.enableLimit(false).helperCommand == "BSET enabled=0"
              && AutomationCommand.topUp(true).helperCommand == "BTOPUP 1" && AutomationCommand.led(.status).helperCommand == "BSET led=1"
              && AutomationCommand.openBatterySettings.helperCommand == nil, "Links become partial helper commands")

        // Schedules, on a fixed UTC Gregorian calendar.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        check(utc.component(.weekday, from: at(2, 0)) == 2, "2 Nov 2026 is a Monday")
        let mondayTopUp = ChargeSchedule(weekdays: [2], hour: 7, minute: 0, action: .topUp)
        check(ChargeScheduler.occurrence(of: mondayTopUp, after: at(1, 23), upTo: at(2, 7, 30), calendar: utc) == at(2, 7),
              "A schedule fires once its time has passed")
        check(ChargeScheduler.occurrence(of: mondayTopUp, after: at(2, 7), upTo: at(2, 7, 30), calendar: utc) == nil,
              "The window excludes its start, so an action never runs twice")
        check(ChargeScheduler.occurrence(of: mondayTopUp, after: at(8, 23), upTo: at(9, 6, 59), calendar: utc) == nil, "Not yet due")
        check(ChargeScheduler.due([mondayTopUp], from: at(2, 6), to: at(2, 20), calendar: utc).isEmpty,
              "Older than the 12-hour catch-up window: skipped")
        var off = mondayTopUp; off.enabled = false
        check(ChargeScheduler.due([off], from: at(1, 23), to: at(2, 8), calendar: utc).isEmpty, "Disabled schedules never fire")
        let evening = ChargeSchedule(weekdays: Set(1...7), hour: 22, minute: 30, action: .setLimit, limit: 80)
        let morning = ChargeSchedule(weekdays: Set(1...7), hour: 6, minute: 0, action: .disable)
        check(ChargeScheduler.due([morning, evening], from: at(1, 22), to: at(2, 7), calendar: utc).map(\.action) == [.setLimit, .disable],
              "Due actions run oldest first")
        check(ChargeScheduler.next([mondayTopUp], after: at(2, 8), calendar: utc) == at(9, 7), "Next weekly occurrence")
        check(ChargeScheduler.next([mondayTopUp, morning], after: at(2, 8), calendar: utc) == at(3, 6), "Earliest next occurrence")
        check(ChargeSchedule(hour: 24).isValid == false && ChargeSchedule(weekdays: []).isValid == false
              && ChargeSchedule(weekdays: [0]).isValid == false && ChargeSchedule(limit: 10).isValid == false, "Schedule validation")

        let scheduleJSON = """
        {"chargeSchedules":[{"id":"\(UUID().uuidString)","enabled":true,"weekdays":[2],"hour":7,"minute":0,"action":"topUp","limit":80},
          {"id":"\(UUID().uuidString)","enabled":true,"weekdays":[2],"hour":7,"minute":0,"action":"launchRockets","limit":80},
          {"id":"\(UUID().uuidString)","enabled":true,"weekdays":[2],"hour":31,"minute":0,"action":"topUp","limit":80}]}
        """
        let scheduleConfig = try! JSONDecoder().decode(OmniStatsConfig.self, from: Data(scheduleJSON.utf8))
        check(scheduleConfig.chargeSchedules.count == 1 && scheduleConfig.chargeSchedules[0].action == .topUp,
              "Unknown or invalid schedules are dropped without losing the rest")

        let scheduleSuite = "OmniStats.ScheduleTests.\(getpid())"
        let scheduleDefaults = UserDefaults(suiteName: scheduleSuite)!
        scheduleDefaults.removePersistentDomain(forName: scheduleSuite)
        let scheduleStore = ConfigStore(defaults: scheduleDefaults)
        scheduleStore.config.chargeSchedules = [mondayTopUp]
        var scheduleClock = at(2, 6)
        var ran: [AutomationCommand] = []
        let runner = ChargeScheduleRunner(store: scheduleStore, defaults: scheduleDefaults, calendar: utc, now: { scheduleClock }) { ran.append($0) }
        check(ran.isEmpty && runner.nextFire == at(2, 7), "Nothing due at start; the timer targets the next occurrence")
        scheduleClock = at(2, 7, 1); runner.check()
        check(ran == [.topUp(true)] && runner.nextFire == at(9, 7), "The runner fires a due action once and re-arms")
        runner.check()
        check(ran.count == 1, "Re-checking does not repeat an action")
        let relaunched = ChargeScheduleRunner(store: scheduleStore, defaults: scheduleDefaults, calendar: utc, now: { scheduleClock }) { ran.append($0) }
        check(ran.count == 1 && relaunched.nextFire == at(9, 7), "A relaunch resumes from the persisted last check")
        scheduleDefaults.removePersistentDomain(forName: scheduleSuite)

        let previousLanguage = L.lang
        for language in [AppLanguage.zhHans, .en, .zhHant, .ja] {
            L.lang = language
            check(L.f("dc.phase.hold1", 40).contains("100%") && L.f("dc.needsNative100", 85).contains("100%")
                  && L.f("dc.needsNative100", 85).contains("85%"), "Literal percent signs survive formatting (\(language))")
        }
        L.lang = previousLanguage

        // App uninstaller: matching rules.
        check(LeftoverScanner.matchesBundleID("com.Example.App", "com.example.app")
              && LeftoverScanner.matchesBundleID("com.example.app.helper", "com.example.app")
              && LeftoverScanner.matchesBundleID("com.example.app_stats.sqlite3", "com.example.app"), "Bundle-ID matches and components")
        check(!LeftoverScanner.matchesBundleID("com.example.application", "com.example.app")
              && !LeftoverScanner.matchesBundleID("com.example.app-lite", "com.example.app")
              && !LeftoverScanner.matchesBundleID("com.example", "com.example.app"), "A longer or sibling identifier is a different app")
        check(LeftoverScanner.matchesGroup("group.com.example.app", "com.example.app")
              && LeftoverScanner.matchesGroup("ABCDE12345.com.example.app", "com.example.app")
              && !LeftoverScanner.matchesGroup("ABCDE12345.com.example.apps", "com.example.app"), "Group containers")
        check(LeftoverScanner.matchesName("AlDente", "AlDente") && !LeftoverScanner.matchesName("Google", "Google")
              && !LeftoverScanner.matchesName("Box", "Box") && !LeftoverScanner.matchesName("AlDente Pro", "AlDente")
              && !LeftoverScanner.matchesName("Uninstaller", "Uninstaller") && !LeftoverScanner.matchesName("Code", "Code")
              && LeftoverScanner.matchesName("Code", "Code", bundleID: "com.microsoft.VSCode"),
              "Names only match when distinctive and exact")

        // A scratch Applications folder, home and root.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("omnistats-uninstall-\(UUID().uuidString)")
        let fm = FileManager.default
        func makeApp(_ path: String, id: String, name: String, appStore: Bool = false) {
            let contents = scratch.appendingPathComponent(path).appendingPathComponent("Contents")
            try! fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.2",
                                       "CFBundlePackageType": "APPL"]
            try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            if appStore {
                try! fm.createDirectory(at: contents.appendingPathComponent("_MASReceipt"), withIntermediateDirectories: true)
                fm.createFile(atPath: contents.appendingPathComponent("_MASReceipt/receipt").path, contents: Data())
            }
        }
        func make(_ path: String, directory: Bool = false, plist: [String: Any]? = nil) {
            let url = scratch.appendingPathComponent(path)
            try! fm.createDirectory(at: directory ? url : url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let plist { try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url) }
            else if !directory { fm.createFile(atPath: url.path, contents: Data("x".utf8)) }
        }
        makeApp("Applications/Example.app", id: "com.example.app", name: "Example")
        makeApp("Applications/Vendor/Tool.app", id: "com.vendor.tool", name: "Tool", appStore: true)
        makeApp("Applications/Notes Clone.app", id: "com.apple.notesclone", name: "Notes")
        makeApp("Applications/OmniStats.app", id: "io.github.suool.omnistats", name: "OmniStats")
        let catalog = AppCatalog.installedApps(in: [scratch.appendingPathComponent("Applications")], excluding: "io.github.suool.omnistats")
        check(catalog.map(\.bundleID) == ["com.example.app", "com.vendor.tool"] && catalog[1].isAppStore && catalog[0].version == "1.2",
              "App list: one folder deep, no Apple apps, not OmniStats itself, App Store receipts")

        let fakeHome = "home/Library/", fakeRoot = "root/"
        for path in ["Application Support/com.example.app", "Application Support/Example", "Caches/com.example.app",
                     "Containers/com.example.app", "Group Containers/ABCDE12345.com.example.app", "WebKit/com.example.app",
                     "Saved Application State/com.example.app.savedState", "Application Support/Google"] {
            make(fakeHome + path, directory: true)
        }
        for path in ["Preferences/com.example.app.plist", "Preferences/com.example.app_stats.sqlite3", "HTTPStorages/com.example.app.binarycookies",
                     "Preferences/com.example.application.plist", "Caches/com.other.app"] { make(fakeHome + path) }
        make(fakeHome + "LaunchAgents/com.example.app.agent.plist", plist: ["Label": "com.example.app.agent"])
        make(fakeRoot + "Library/LaunchDaemons/com.vendor.updater.plist",
             plist: ["Label": "com.vendor.updater", "AssociatedBundleIdentifiers": ["com.example.app"],
                     "Program": "/Library/PrivilegedHelperTools/com.vendor.updater"])
        make(fakeRoot + "Library/LaunchDaemons/com.unrelated.daemon.plist", plist: ["Label": "com.unrelated.daemon", "Program": "/usr/bin/true"])
        make(fakeRoot + "Library/PrivilegedHelperTools/com.vendor.updater")
        make(fakeRoot + "Library/PrivilegedHelperTools/com.unrelated.daemon")
        make(fakeRoot + "Library/Application Support/Example", directory: true)
        make(fakeRoot + "private/var/db/receipts/com.example.app.pkg.bom")
        let scanner = LeftoverScanner(home: scratch.appendingPathComponent("home"), root: scratch.appendingPathComponent("root"))
        let found = scanner.scan(catalog[0])
        let names = Set(found.map { $0.url.lastPathComponent })
        check(names == ["Example.app", "com.example.app", "Example", "com.example.app.savedState", "com.example.app.plist",
                        "com.example.app_stats.sqlite3", "com.example.app.binarycookies", "ABCDE12345.com.example.app",
                        "com.example.app.agent.plist", "com.vendor.updater.plist", "com.vendor.updater", "com.example.app.pkg.bom"],
              "Leftovers found: \(names.sorted())")
        check(found.filter(\.byName).map(\.url.lastPathComponent) == ["Example", "Example"], "Name matches are flagged")
        check(found.filter { $0.url.lastPathComponent == "com.example.app" }.count == 4
              && found.filter { $0.url.lastPathComponent == "Example" }.count == 2, "Same names in different folders are separate items")
        check(found.first { $0.kind == .launchDaemon }?.system == true && found.first { $0.kind == .helper }?.system == true
              && found.first { $0.kind == .container }?.protected == true && found.first { $0.kind == .launchAgent }?.system == false,
              "Daemons, helpers and system folders need admin; containers need Full Disk Access")
        check(!names.contains("Google") && !names.contains("com.example.application.plist") && !names.contains("com.unrelated.daemon"),
              "Shared vendor folders, look-alike identifiers and unrelated daemons stay")
        check(LeftoverScanner.size(of: scratch.appendingPathComponent(fakeHome + "Preferences/com.example.app.plist")) ?? 0 > 0,
              "Sizes are measured")

        // Homebrew: the Caskroom symlink names the cask, its receipt the zap list.
        let caskVersion = scratch.appendingPathComponent("caskroom/example/1.0")
        try! fm.createDirectory(at: caskVersion, withIntermediateDirectories: true)
        try! fm.createSymbolicLink(atPath: caskVersion.appendingPathComponent("Example.app").path,
                                   withDestinationPath: scratch.appendingPathComponent("Applications/Example.app").path)
        let zapList = ["~/.example", "~/Library", "~/Library/Caches", "~/Documents", "~/Library/Logs/Example*",
                       "/etc/hosts", "/Library/Preferences/com.example.shared.plist", "/Library/Preferences/Example/nested.plist"]
        let receipt: [String: Any] = ["uninstall_artifacts": [["app": ["Example.app"]],
                                                              ["zap": [["trash": zapList], ["delete": "~/Library/Caches/com.example.app"]]]]]
        make("caskroom/example/.metadata/INSTALL_RECEIPT.json")
        try! JSONSerialization.data(withJSONObject: receipt).write(to: scratch.appendingPathComponent("caskroom/example/.metadata/INSTALL_RECEIPT.json"))
        for path in ["home/.example/config", "home/Library/Logs/Example Crash", "home/Library/Logs/ExampleLog", "home/Documents/a",
                     "root/etc/hosts", "root/Library/Preferences/com.example.shared.plist", "root/Library/Preferences/Example/nested.plist"] {
            make(path)
        }
        let savedCaskrooms = AppCatalog.caskrooms
        AppCatalog.caskrooms = [scratch.appendingPathComponent("caskroom")]
        let brewed = AppCatalog.installedApps(in: [scratch.appendingPathComponent("Applications")], excluding: nil)
        AppCatalog.caskrooms = savedCaskrooms
        check(brewed.first { $0.bundleID == "com.example.app" }?.cask == "example" && brewed.first?.zap.count == zapList.count + 1
              && brewed.first { $0.bundleID == "com.vendor.tool" }?.cask == nil, "Homebrew casks and their zap lists are found")
        if let brewedExample = brewed.first(where: { $0.bundleID == "com.example.app" }) {
            let zapped = scanner.scan(brewedExample)
            let fromCask = Set(zapped.filter(\.fromCask).map { $0.url.lastPathComponent })
            check(fromCask == [".example", "Example Crash", "ExampleLog", "com.example.shared.plist"],
                  "Zap items are added and marked: \(fromCask.sorted())")
            check(zapped.count == found.count + 4 && zapped.first { $0.url.lastPathComponent == "com.example.shared.plist" }?.system == true,
                  "Zap paths already found stay single; system ones need admin")
        }
        let zapHome = scratch.appendingPathComponent("home"), zapRoot = scratch.appendingPathComponent("root")
        check(["Library", "Library/Caches", "Documents", ".ssh"].allSatisfy { scanner.zapItem(zapHome.appendingPathComponent($0)) == nil }
              && scanner.zapItem(zapHome.appendingPathComponent("Library/Caches/x"))?.kind == .caches
              && scanner.zapItem(zapRoot.appendingPathComponent("etc/hosts")) == nil
              && scanner.zapItem(zapRoot.appendingPathComponent("Library/Preferences/Example/nested.plist")) == nil
              && scanner.zapItem(zapRoot.appendingPathComponent("Library/LaunchDaemons/x.plist"))?.kind == .launchDaemon,
              "Zap never takes a home or Library root, and outside home only what the cleaner may move")
        check(AppUninstaller.keptOnReset == [.app, .receipt, .launchAgent, .launchDaemon, .helper], "Reset keeps what installs and runs the app")

        // Leftovers of deleted apps.
        check(OrphanScanner.identifier(in: "com.gone.app.plist") == "com.gone.app"
              && OrphanScanner.identifier(in: "com.gone.app_stats.sqlite3") == "com.gone.app"
              && OrphanScanner.identifier(in: "com.gone.app.savedState") == "com.gone.app"
              && OrphanScanner.identifier(in: "com.gone.app.binarycookies") == "com.gone.app", "Identifiers from file names")
        check(["Example", "com.gone", "group.com.gone.app", "ABCDE12345.com.gone.app", "com..gone", "com.gone app.x"]
                .allSatisfy { OrphanScanner.identifier(in: $0) == nil }, "Only reverse-DNS names count")
        check(OrphanScanner.vendor("com.Example.app.helper") == "com.example" && OrphanScanner.vendor("io.github.someone.tool") == "io.github.someone",
              "Vendors, one level deeper on code hosts")
        let installedIDs = ["com.example.app", "io.github.someone.tool"]
        let installedVendors = Set(installedIDs.map(OrphanScanner.vendor))
        check(OrphanScanner.belongsToInstalled("com.example.app.helper", installed: installedIDs, vendors: installedVendors)
              && OrphanScanner.belongsToInstalled("com.example.updater", installed: installedIDs, vendors: installedVendors)
              && OrphanScanner.belongsToInstalled("com.amplitude.storage.x", installed: [], vendors: [])
              && OrphanScanner.belongsToInstalled("com.ookla.speedtest-cli", installed: [], vendors: [])
              && !OrphanScanner.belongsToInstalled("io.github.other.tool", installed: installedIDs, vendors: installedVendors)
              && !OrphanScanner.belongsToInstalled("com.gone.app", installed: installedIDs, vendors: installedVendors),
              "Installed apps, their vendors, SDK data and command-line tools are left alone")
        let orphanHome = "orphans/home/Library/", orphanRoot = "orphans/root/Library/"
        for path in ["Preferences/com.gone.app.plist", "HTTPStorages/com.gone.app.binarycookies", "Preferences/com.example.app.plist",
                     "Preferences/com.example.updater.plist", "Caches/com.registered.app", "Caches/com.amplitude.storage.x"] {
            make(orphanHome + path)
        }
        for path in ["Caches/com.gone.app", "Application Support/com.gone.app.helper", "Application Support/SomeName"] {
            make(orphanHome + path, directory: true)
        }
        make(orphanHome + "LaunchAgents/com.gone.agent.plist", plist: ["Label": "com.gone.agent", "Program": "/Applications/Gone.app/Contents/MacOS/agent"])
        make(orphanRoot + "LaunchDaemons/com.dead.daemon.plist", plist: ["Label": "com.dead.daemon", "Program": "/Library/PrivilegedHelperTools/com.dead.daemon"])
        make(orphanRoot + "LaunchDaemons/com.live.daemon.plist", plist: ["Label": "com.live.daemon", "Program": "/Library/PrivilegedHelperTools/com.live.daemon"])
        make(orphanRoot + "PrivilegedHelperTools/com.live.daemon")
        make(orphanRoot + "PrivilegedHelperTools/com.stale.helper")
        let orphans = OrphanScanner.scan(home: scratch.appendingPathComponent("orphans/home"), root: scratch.appendingPathComponent("orphans/root"),
                                         installedIDs: installedIDs, isRegistered: { $0 == "com.registered.app" })
        check(orphans.map(\.bundleID) == ["com.dead.daemon", "com.gone.agent", "com.gone.app", "com.stale.helper"],
              "Orphan groups: \(orphans.map(\.bundleID))")
        check(orphans.first { $0.bundleID == "com.gone.app" }?.items.count == 4, "A helper's data joins its app's group")
        check(orphans.first { $0.bundleID == "com.dead.daemon" }?.items.first?.system == true
              && orphans.first { $0.bundleID == "com.stale.helper" }?.items.first?.kind == .helper
              && orphans.first { $0.bundleID == "com.gone.agent" }?.items.first?.system == false,
              "Jobs whose program is gone and unused helpers count; system items need admin")
        try? fm.removeItem(at: scratch)

        var cleanerReport = UninstallReport()
        cleanerReport.absorbCleanerOutput("moved\t/Library/LaunchDaemons/a.plist\t/Users/x/.Trash/R/LaunchDaemons/a.plist\n"
            + "skipped\t/etc/hosts\toutside the allowed folders\nnoise line\n")
        check(cleanerReport.destinations["/Library/LaunchDaemons/a.plist"] == "/Users/x/.Trash/R/LaunchDaemons/a.plist",
              "Cleaner destinations are kept for the log")
        check(cleanerReport.moved == ["/Library/LaunchDaemons/a.plist"]
              && cleanerReport.skipped == [.init(path: "/etc/hosts", reason: "outside the allowed folders")], "Cleaner output parsing")
        let folder = AppUninstaller.trashFolderName(for: InstalledApp(url: URL(fileURLWithPath: "/Applications/系统 Tool.app"),
            bundleID: "x", name: "系统 Tool/../x", version: nil, isAppStore: false), date: Date(timeIntervalSince1970: 0))
        check(folder.hasPrefix("OmniStats Removed ") && !folder.contains("/") && !folder.contains("系")
              && folder.allSatisfy { $0.isASCII }, "Trash folder names are safe for the cleaner: \(folder)")

        // Menu-bar icon hiding.
        check(MenuBarLayout.collapsedLength(screenWidths: [1728, 1000]) == 3456
              && MenuBarLayout.collapsedLength(screenWidths: [6016]) == 10_000
              && MenuBarLayout.collapsedLength(screenWidths: [200]) == 500
              && MenuBarLayout.collapsedLength(screenWidths: []) == 2000, "Divider width covers every screen, capped at 10,000 pt")
        check(MenuBarLayout.isOrdered(toggle: 500, divider: 400, alwaysHidden: nil, usesAlwaysHidden: false)
              && MenuBarLayout.isOrdered(toggle: 500, divider: 400, alwaysHidden: 300, usesAlwaysHidden: true), "Dividers left of ‹ may hide")
        check(!MenuBarLayout.isOrdered(toggle: 500, divider: 600, alwaysHidden: nil, usesAlwaysHidden: false)
              && !MenuBarLayout.isOrdered(toggle: 500, divider: 400, alwaysHidden: 450, usesAlwaysHidden: true)
              && !MenuBarLayout.isOrdered(toggle: 500, divider: 400, alwaysHidden: nil, usesAlwaysHidden: true)
              && !MenuBarLayout.isOrdered(toggle: nil, divider: 400, alwaysHidden: nil, usesAlwaysHidden: false),
              "A misplaced or missing divider must never hide ‹ itself")
        check(MenuBarLayout.isSupported(majorVersion: 13) && MenuBarLayout.isSupported(majorVersion: 26)
              && !MenuBarLayout.isSupported(majorVersion: 27), "Divider hiding is off on macOS 27")
        let screens = [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: -1000, y: -178, width: 1000, height: 1600)]
        check(MenuBarLayout.pointerInMenuBar(CGPoint(x: 900, y: 1110), screens: screens)
              && MenuBarLayout.pointerInMenuBar(CGPoint(x: -500, y: 1410), screens: screens)
              && !MenuBarLayout.pointerInMenuBar(CGPoint(x: 900, y: 600), screens: screens), "Pointer on any menu bar defers auto-hide")
        let shortcut = MenuBarHotKey(keyCode: 11, flags: [.command, .option], characters: "b")
        check(shortcut?.display == "⌥⌘B" && shortcut?.modifiers == UInt32(cmdKey | optionKey) && shortcut?.keyCode == 11,
              "Shortcut capture and display")
        check(MenuBarHotKey(keyCode: 49, flags: [.control, .shift], characters: " ")?.display == "⌃⇧Space", "Named keys")
        check(MenuBarHotKey(keyCode: 11, flags: [], characters: "b") == nil
              && MenuBarHotKey(keyCode: 11, flags: [.shift], characters: "b") == nil, "Shortcuts need ⌘, ⌥ or ⌃")
        let menuBarJSON = #"{"menuBarHiding":true,"menuBarAutoHide":7,"menuBarHotKey":{"keyCode":11,"modifiers":2304,"key":"B"}}"#
        let menuBarConfig = try! JSONDecoder().decode(OmniStatsConfig.self, from: Data(menuBarJSON.utf8))
        check(menuBarConfig.menuBarHiding && menuBarConfig.menuBarAutoHide == 15 && menuBarConfig.menuBarHotKey?.key == "B",
              "Menu-bar settings decode; unknown auto-hide delays fall back to 15 s")
        check(!oldConfig.menuBarHiding && oldConfig.menuBarHotKey == nil, "Menu-bar hiding stays off until opted in")
        check((try? JSONDecoder().decode(OmniStatsConfig.self, from: Data(#"{"menuBarHotKey":42}"#.utf8)))?.menuBarHotKey == nil,
              "A malformed shortcut does not break the config")

        let desktop = BatterySampler(isPresent: false, read: { charging })
        desktop.setSamplingInterval(5)
        check(desktop.samplingInterval == nil && !desktop.hasSample, "Macs without a battery never sample")
        checkBatteryHistory()
        print("PASS: history interpolation, resource APIs/lifecycle, display/control cadence, policy, validation, weighted averages, bounded histories, network parsing, control reconnect/expiry/failure, fresh-temperature safety, async sensors, persistence, login-item install location, battery parsing and sampling, battery history storage/downsampling/stats/estimates, charge-control status and native limit parsing, automation links and schedules, menu-bar hiding, uninstaller scanning")
    }

    // Records, files, queries and the recorder, all inside a temporary folder:
    // the real Application Support folder is never touched.
    @MainActor static func checkBatteryHistory() {
        typealias Record = BatteryHistoryRecord
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("omnistats-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: root) }
        func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
        func size(_ url: URL) -> Int { ((try? files.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1 }
        func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }
        let base: TimeInterval = 1_790_000_000
        func sample(_ t: TimeInterval, percent: UInt8 = 60, flags: Record.Flags = [.external, .charging, .telemetry],
                    current: Int16 = 2000, powerIn: Int32 = 30000) -> Record {
            Record(time: UInt32(t), percent: percent, flags: flags, temperature: 3000, rawCurrent: 4000, rawMax: 8000,
                   voltage: 12500, current: current, systemPowerIn: powerIn, systemLoad: max(0, powerIn - 10000), batteryPower: 10000)
        }

        let reading: [String: Any] = [
            "UpdateTime": Int(base) - 10, "CurrentCapacity": 72, "MaxCapacity": 100,
            "AppleRawCurrentCapacity": 5800, "AppleRawMaxCapacity": 8100, "Voltage": 12600,
            "InstantAmperage": NSNumber(value: UInt64(bitPattern: -1500)), "Temperature": 3125,
            "ExternalConnected": false, "IsCharging": false, "FullyCharged": false,
            "PowerTelemetryData": ["SystemPowerIn": 0, "SystemLoad": 18900,
                                   "BatteryPower": NSNumber(value: UInt64(bitPattern: -18900))] as [String: Any],
        ]
        guard let decoded = Record(registry: reading, now: base) else { fatalError("A full reading must decode") }
        check(decoded.time == UInt32(base) - 10 && decoded.percent == 72 && decoded.flags == [.telemetry],
              "History records keep the gauge's UpdateTime and state")
        check(decoded.current == -1500 && decoded.batteryPower == -18900 && decoded.systemLoad == 18900 && decoded.rawMax == 8100,
              "Two's-complement current and battery power stay negative")
        check(decoded.value(.current) == -1.5 && decoded.value(.temperature) == 31.25 && decoded.value(.voltage) == 12.6
              && decoded.value(.batteryPower) == -18.9 && decoded.value(.rawCurrent) == 5800, "Chart fields use display units")
        var odd = reading
        odd["UpdateTime"] = 12345; odd["Temperature"] = 99999; odd["PowerTelemetryData"] = nil
        let fallback = Record(registry: odd, now: base)
        check(fallback?.time == UInt32(base) && fallback?.value(.temperature) == nil && fallback?.value(.systemPowerIn) == nil,
              "Implausible stamps and temperatures and missing telemetry are unavailable, not zero")
        check(Record(registry: ["MaxCapacity": 100], now: base) == nil
              && Record(registry: ["CurrentCapacity": 50, "MaxCapacity": 0], now: base) == nil, "No record without a charge reading")

        var extreme = decoded
        extreme.temperature = Record.noTemperature; extreme.current = .min; extreme.batteryPower = .min
        extreme.systemPowerIn = .max; extreme.rawCurrent = .max; extreme.flags = [.external, .charging, .fullyCharged, .telemetry]
        for record in [decoded, extreme] {
            let bytes = PackedFile.encode([record], header: false)
            check(bytes.count == Record.size && bytes.withUnsafeBytes { Record(packed: $0, at: 0) } == record,
                  "Records survive encode and decode")
        }
        check(MemoryLayout<Record>.stride == Record.size, "A record takes its 28 packed bytes in memory too")
        let header = PackedFile.encode([decoded], header: true)
        check(Array(header.prefix(8)) == Array("OSBH".utf8) + [1, 0, 28, 0]
              && Array(header[8..<12]) == withUnsafeBytes(of: decoded.time.littleEndian, Array.init), "Little-endian header and records")
        let health = BatteryHealthSnapshot(day: 20261030, nominalCapacity: 8376, rawMaxCapacity: 8132, designCapacity: 8579,
                                           cycleCount: 41, maximumCapacityPercent: 96)
        let healthBytes = PackedFile.encode([health], header: false)
        check(healthBytes.count == 13 && healthBytes.withUnsafeBytes { BatteryHealthSnapshot(packed: $0, at: 0) } == health,
              "Snapshots survive encode and decode")
        check(abs((health.health ?? 0) - 8376.0 / 8579.0 * 100) < 1e-9 && BatteryHealthSnapshot(registry: ["CycleCount": 4], day: 1) == nil
              && health.date.map { BatteryHealthSnapshot.day(for: $0.timeIntervalSince1970) } == 20261030, "Snapshot health and dates")

        // Batched appends, reload and de-duplication.
        let batch = BatteryHistoryStore(directory: folder("batch"))
        batch.load(now: base)
        check(batch.records.isEmpty && !files.fileExists(atPath: folder("batch").path), "An empty history writes nothing")
        let day = (0..<1440).map { sample(base + Double($0) * 60) }
        for record in day.prefix(10) { check(batch.append(record), "New minutes are kept") }
        batch.flush(now: base + 600)
        check(size(batch.historyURL) == 8 + 10 * 28, "The first flush writes the header and the batch")
        for record in day.dropFirst(10) { batch.append(record) }
        batch.flush(now: base + 86400)
        let bytesPerDay = size(batch.historyURL) - 8
        check(bytesPerDay == 1440 * 28, "Later flushes append only new records")
        let reloaded = BatteryHistoryStore(directory: folder("batch"))
        reloaded.load(now: base + 86400)
        check(reloaded.records == day, "Appended batches reload intact")
        let last = TimeInterval(day[1439].time)
        check(!reloaded.append(day[1439]), "A repeated UpdateTime is a duplicate")
        check(!reloaded.append(sample(last + 30)), "A reading within 45 s in the same state is a duplicate")
        check(reloaded.append(sample(last + 30, flags: [.telemetry])), "Unplugging is recorded at once")
        check(!reloaded.append(sample(last - 600)), "Slightly older readings are dropped")
        check(reloaded.append(sample(last - 7200)) && reloaded.records.count == 1320 && reloaded.records.last == sample(last - 7200),
              "A clock set back by hours drops the records it overtakes")
        reloaded.flush(now: base + 86400)
        check(PackedFile.load(reloaded.historyURL, as: Record.self).records == reloaded.records, "The drop is rewritten to disk")

        // Retention: 30 days, applied on load and by the daily compaction.
        let aging = BatteryHistoryStore(directory: folder("aging"))
        aging.load(now: base)
        for hour in 0..<(40 * 24) { aging.append(sample(base + Double(hour) * 3600)) }
        aging.append(sample(base + 50 * 86400))
        aging.flush(now: base)
        let compacted = BatteryHistoryStore(directory: folder("aging"))
        compacted.load(now: base + 40 * 86400)
        check(compacted.records.count == 720 && compacted.records.first?.time == UInt32(base) + 240 * 3600
              && size(compacted.historyURL) == 8 + 720 * 28, "Launch drops records past 30 days or in the future and rewrites")
        compacted.compact(now: base + 41 * 86400)
        check(compacted.records.count == 696 && PackedFile.load(compacted.historyURL, as: Record.self).records == compacted.records,
              "The daily compaction trims again")

        // Damaged files are moved aside, never trusted.
        let valid = Array(PackedFile.encode(Array(day.prefix(3)), header: true))
        let damaged: [(String, [UInt8])] = [
            ("garbage", Array("not a history".utf8)), ("empty", []), ("magic", [0x58] + valid[1...]),
            ("version", Array(valid[0..<4]) + [2, 0] + valid[6...]), ("record-size", Array(valid[0..<6]) + [32, 0] + valid[8...]),
        ]
        for (name, bytes) in damaged {
            let store = BatteryHistoryStore(directory: folder(name))
            try? files.createDirectory(at: folder(name), withIntermediateDirectories: true)
            try? Data(bytes).write(to: store.historyURL)
            try? Data(bytes).write(to: store.healthURL)
            store.load(now: base)
            check(store.records.isEmpty && store.snapshots.isEmpty && files.fileExists(atPath: store.historyURL.path + ".corrupt")
                  && files.fileExists(atPath: store.healthURL.path + ".corrupt"), "A \(name) file is moved aside")
            store.append(sample(base)); store.flush(now: base)
            let fresh = PackedFile.load(store.historyURL, as: Record.self)
            check(fresh.records == [sample(base)] && !fresh.damaged, "A fresh file replaces a \(name) one")
        }
        let torn = BatteryHistoryStore(directory: folder("torn"))
        try? files.createDirectory(at: folder("torn"), withIntermediateDirectories: true)
        try? Data(valid + [1, 2, 3]).write(to: torn.historyURL)
        torn.load(now: base)
        check(torn.records == Array(day.prefix(3)) && size(torn.historyURL) == valid.count
              && !files.fileExists(atPath: torn.historyURL.path + ".corrupt"), "A torn append keeps whole records and is trimmed")

        // Downsampling keeps extremes within N buckets.
        var profile = day
        profile[700].systemPowerIn = 140_000; profile[900].systemPowerIn = 1_000
        let dayRuns = BatteryHistoryBucket.series(profile, .systemPowerIn, from: base, to: base + 86400, maxPoints: 100)
        let buckets = dayRuns.flatMap { $0 }
        check(dayRuns.count == 1 && buckets.count == 100, "A full day downsamples to N buckets")
        check(buckets.map(\.high).max() == 140 && buckets.map(\.low).min() == 1 && buckets.reduce(0) { $0 + $1.count } == 1440,
              "Buckets keep every sample and its extremes")
        check(buckets.allSatisfy { $0.low <= $0.mean && $0.mean <= $0.high && $0.start <= $0.end }, "Means lie within each bucket")
        check(BatteryHistoryBucket.series(profile, .percent, from: base, to: base + 6000, maxPoints: 100).flatMap { $0 }.count == 100,
              "A sample exactly at the end stays within N")
        let fine = BatteryHistoryBucket.series(profile, .percent, from: base, to: base + 3540, maxPoints: 1000)
        check(fine.count == 1 && fine[0].count == 60 && fine[0].allSatisfy { $0.count == 1 }, "Short ranges keep every minute")
        check(BatteryHistoryBucket.series(profile, .percent, from: base, to: base, maxPoints: 10).isEmpty
              && BatteryHistoryBucket.series(profile, .percent, from: base, to: base + 60, maxPoints: 0).isEmpty, "Empty ranges")

        // Gaps stay gaps.
        var holes = Array(day.prefix(120))
        holes.remove(at: 90)
        holes.removeSubrange(30..<60)
        let gapRuns = BatteryHistoryBucket.series(holes, .percent, from: base, to: base + 7200, maxPoints: 1000)
        check(gapRuns.count == 3 && gapRuns[0].last?.end == at(base + 29 * 60) && gapRuns[1].first?.start == at(base + 60 * 60)
              && gapRuns[1].last?.end == at(base + 89 * 60) && gapRuns[2].first?.start == at(base + 91 * 60),
              "Sleep and a single missing minute are gaps, never bridged")
        var untelemetered = Array(day.prefix(60))
        for i in 20..<40 { untelemetered[i].flags = [.external, .charging] }
        check(BatteryHistoryBucket.series(untelemetered, .systemPowerIn, from: base, to: base + 3600, maxPoints: 1000).count == 2
              && BatteryHistoryBucket.series(untelemetered, .percent, from: base, to: base + 3600, maxPoints: 1000).count == 1,
              "Missing telemetry is a gap in the power series only")
        let coarse = BatteryHistoryBucket.series(holes, .percent, from: base, to: base + 30 * 86400, maxPoints: 30)
        check(coarse.count == 1 && coarse[0].count == 1, "Gaps narrower than a bucket fall inside it at coarse zoom")

        // Today's statistics: 1 h charging, a 30 min gap, 1 h held at 80 %, 1 h on battery.
        var log: [Record] = []
        for m in 0...60 { log.append(sample(base + Double(m) * 60, percent: m < 30 ? 98 : 99)) }
        for m in 90..<150 { log.append(sample(base + Double(m) * 60, percent: 80, flags: [.external, .telemetry], current: 0, powerIn: 12000)) }
        for m in 150...210 { log.append(sample(base + Double(m) * 60, percent: 79, flags: [.telemetry], current: -1500, powerIn: 0)) }
        let stats = BatteryDayStats(log, from: base, to: base + 210 * 60, limit: 80)
        check(abs(stats.wallEnergy - 41.9) < 1e-9, "Wall energy integrates SystemPowerIn and skips the gap")
        check(stats.heldAtLimit == 3600 && stats.onBattery == 3600 && stats.full == 1800 && stats.covered == 10800,
              "Time held at the limit, on battery and full")
        let clipped = BatteryDayStats(log, from: base + 15, to: base + 210 * 60, limit: 80)
        check(abs(clipped.wallEnergy - 41.775) < 1e-9 && clipped.covered == 10785, "An interval across midnight counts only its share")
        check(BatteryDayStats(log, from: base, to: base + 210 * 60, limit: 85).heldAtLimit == 0, "Held time needs the given limit")

        // Estimates.
        check(abs((BatteryEstimate.timeToTarget(85, rawCurrent: 4000, rawMax: 8000, current: 2800) ?? 0) - 3600) < 1e-6,
              "Time to the charge limit")
        check([BatteryEstimate.timeToTarget(85, rawCurrent: 4000, rawMax: 8000, current: -2000),
               BatteryEstimate.timeToTarget(85, rawCurrent: 4000, rawMax: 8000, current: 0),
               BatteryEstimate.timeToTarget(85, rawCurrent: 4000, rawMax: 8000, current: 20),
               BatteryEstimate.timeToTarget(50, rawCurrent: 4000, rawMax: 8000, current: 2800),
               BatteryEstimate.timeToTarget(85, rawCurrent: 4000, rawMax: 0, current: 2800),
               BatteryEstimate.timeToTarget(101, rawCurrent: 4000, rawMax: 8000, current: 2800)].allSatisfy { $0 == nil },
              "No charge estimate while discharging, idle, at the target or without capacity")
        check(BatteryEstimate.timeToEmpty(rawCurrent: 4000, current: -2000) == 7200, "Time to empty")
        check([BatteryEstimate.timeToEmpty(rawCurrent: 4000, current: 2000), BatteryEstimate.timeToEmpty(rawCurrent: 4000, current: 0),
               BatteryEstimate.timeToEmpty(rawCurrent: 4000, current: -20), BatteryEstimate.timeToEmpty(rawCurrent: 0, current: -2000)]
              .allSatisfy { $0 == nil }, "No time to empty while charging, idle or empty")
        let charge = [sample(base, current: 1000), sample(base + 60, current: 2000), sample(base + 120, current: 3000)]
        check(BatteryEstimate.recentCurrent(charge, now: base + 130) == 2000, "Recent average current")
        check(BatteryEstimate.recentCurrent(charge, now: base + 400) == nil, "A stale reading gives no average")
        check(BatteryEstimate.recentCurrent(Array(charge.prefix(2)), now: base + 70) == nil, "Too few readings give no average")
        check(BatteryEstimate.recentCurrent([sample(base - 60, flags: [.telemetry], current: -3000)] + charge, now: base + 130) == 2000
              && BatteryEstimate.recentCurrent([sample(base - 600, current: 9000)] + charge, now: base + 130) == 2000,
              "Only the current power state since the last gap counts")
        check(BatteryEstimate.recentCurrent(day, now: last) == 2000 && BatteryEstimate.recentCurrent([], now: base) == nil,
              "The window bounds the average")

        // The recorder, with an injected gauge and clock.
        var clock = Calendar.current.startOfDay(for: at(base)).timeIntervalSince1970 + 12 * 3600
        var gauge = reading.merging([
            "UpdateTime": Int(clock) - 5, "ExternalConnected": true, "IsCharging": true, "InstantAmperage": 2800,
            "AppleRawCurrentCapacity": 4000, "AppleRawMaxCapacity": 8000, "NominalChargeCapacity": 8376,
            "DesignCapacity": 8579, "CycleCount": 41,
            "PowerTelemetryData": ["SystemPowerIn": 35000, "SystemLoad": 25000, "BatteryPower": 10000] as [String: Any],
        ]) { $1 }
        func tick(_ seconds: TimeInterval) { clock += seconds; gauge["UpdateTime"] = Int(clock) - 5 }
        var fullReads = 0, quickReads = 0
        let historyFile = folder("recorder").appendingPathComponent("battery-history.bin")
        let recorder = BatteryHistory(isPresent: true, directory: folder("recorder"), read: { keys in
            if keys == ["UpdateTime"] { quickReads += 1 } else if keys == Record.registryKeys { fullReads += 1 }
            return gauge
        }, clock: { clock })
        recorder.start()
        recorder.recordNow()
        wait { recorder.latest != nil }
        check(fullReads == 1 && quickReads == 1 && recorder.latest?.time == UInt32(clock) - 5 && recorder.snapshots.count == 1,
              "Launch records at once; a repeated message reads one key and records nothing")
        for _ in 1...9 { tick(60); recorder.recordNow() }
        check(fullReads == 10 && !files.fileExists(atPath: historyFile.path), "Samples batch in memory for ten minutes")
        tick(60); recorder.recordNow()
        check(size(historyFile) == 8 + 11 * 28, "The ten-minute flush appends the batch")
        check(abs((recorder.timeToReach(85) ?? 0) - 3600) < 1e-6 && recorder.timeToEmpty() == nil, "Live estimates use recent samples")
        let today = recorder.todayStats(limit: 80)
        check(abs(today.wallEnergy - 35.0 * 600 / 3600) < 1e-9 && today.covered == 600 && today.onBattery == 0, "Today's stats")
        let quick = quickReads
        recorder.runWatchdog()
        check(fullReads == 11 && quickReads == quick, "The watchdog stays idle while samples are fresh")
        clock += 200; recorder.runWatchdog()
        check(fullReads == 11 && quickReads == quick + 1, "A stale history makes the watchdog check the gauge")
        gauge["UpdateTime"] = Int(clock) - 5; recorder.runWatchdog()
        check(fullReads == 12 && recorder.timeToReach(85) == nil, "It records what the messages missed; a gap resets the average")
        tick(86400); gauge["CycleCount"] = 42; recorder.recordNow()
        check(recorder.snapshots.count == 2 && recorder.snapshots.last?.cycleCount == 42, "One snapshot per day")
        check(size(historyFile) == 8 + 13 * 28, "The daily compaction keeps recent records and writes pending ones")
        tick(60); recorder.recordNow(); recorder.flush()
        check(size(historyFile) == 8 + 14 * 28, "Termination writes the rest")
        let relaunched = BatteryHistory(isPresent: true, directory: folder("recorder"), read: { _ in gauge }, clock: { clock })
        relaunched.start(); relaunched.recordNow()
        wait { relaunched.latest != nil }
        let stored = relaunched.series(.percent, from: at(clock - 3 * 86400), to: at(clock), maxPoints: 10_000).flatMap { $0 }
        check(stored.reduce(0) { $0 + $1.count } == 14 && relaunched.snapshots.count == 2 && relaunched.latest?.time == UInt32(clock) - 5,
              "A relaunch keeps history and snapshots without duplicating the current reading")

        // No battery: nothing is read, scheduled or written.
        var desktopReads = 0
        let desktop = BatteryHistory(isPresent: false, directory: folder("desktop"), read: { _ in desktopReads += 1; return gauge },
                                     clock: { clock })
        desktop.start(); desktop.recordNow(); desktop.runWatchdog(); desktop.flush()
        check(desktopReads == 0 && !files.fileExists(atPath: folder("desktop").path) && desktop.latest == nil && desktop.snapshots.isEmpty
              && desktop.series(.percent, from: at(0), to: at(clock), maxPoints: 100).isEmpty
              && desktop.todayStats(limit: 80) == BatteryDayStats() && desktop.timeToEmpty() == nil,
              "Macs without a battery record and write nothing")
        let unreadable = BatteryHistory(isPresent: true, directory: folder("unreadable"), read: { _ in nil }, clock: { clock })
        unreadable.start(); unreadable.recordNow(); unreadable.flush()
        check(!files.fileExists(atPath: folder("unreadable").path) && unreadable.snapshots.isEmpty, "An unreadable gauge writes nothing")

        // Footprint and cost.
        let month = BatteryHistoryStore(directory: folder("month"))
        month.load(now: base)
        for m in 0..<(30 * 1440) { month.append(sample(base + Double(m) * 60)) }
        month.flush(now: base)
        let monthReloaded = BatteryHistoryStore(directory: folder("month"))
        monthReloaded.load(now: base + 30 * 86400 - 60)
        let count = monthReloaded.records.count, stride = MemoryLayout<Record>.stride, capacity = monthReloaded.records.capacity
        check(count == 43_200, "30 days of minutes stay within retention")
        print("Battery history footprint (measured): \(count) records × \(stride) B = \(count * stride) B; array capacity \(capacity) "
              + "= \(capacity * stride) B; file \(size(monthReloaded.historyURL)) B, \(bytesPerDay) B per day")
        if BatteryReader.isPresent {
            let reader = BatteryReader()
            var full: [UInt64] = [], quick: [UInt64] = [], live: Record?
            for _ in 0..<200 {
                let a = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                if let registry = reader.read(Record.registryKeys), let record = Record(registry: registry, now: Date().timeIntervalSince1970) {
                    live = record; _ = PackedFile.encode([record], header: false)
                }
                let b = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                _ = reader.read(["UpdateTime"])
                let c = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                full.append(b - a); quick.append(c - b)
            }
            func median(_ values: [UInt64]) -> Double { Double(values.sorted()[values.count / 2]) / 1000 }
            check((live?.rawMax ?? 0) > 0 && (live?.percent ?? 101) <= 100, "The live gauge decodes into a history record")
            print(String(format: "Battery history cost (measured, median of 200): %.1f µs CPU per sample+encode, %.1f µs per repeated message",
                         median(full), median(quick)))
        } else {
            print("Battery history cost: no battery on this Mac, live read skipped")
        }
    }
}
