import AppKit
import Foundation

@main
struct LogicTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func wait(_ complete: () -> Bool, seconds: Double = 2) {
        let end = Date().addingTimeInterval(seconds)
        while !complete() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(complete(), "Asynchronous operation did not finish")
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        var config = OmniStatsConfig()
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
        let liveResources = ResourceReader().sample()
        check(liveResources.memory != nil && liveResources.disk != nil, "Read-only memory and startup capacity APIs must work")
        print("Resource API smoke test: memory and disk available; GPU available: \(liveResources.gpuPercent != nil)")
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
        resourceSampler.setSamplingInterval(nil)

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
        print("PASS: history interpolation, resource APIs/lifecycle, display/control cadence, policy, validation, weighted averages, bounded histories, network parsing, control reconnect/expiry/failure, fresh-temperature safety, async sensors, persistence")
    }
}
