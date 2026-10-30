import AppKit
import Combine

final class ActivityState: ObservableObject {
    @Published var panelVisible = false
    @Published var settingsVisible = false
}

final class SamplingCoordinator {
    private let monitor: Monitor, net: NetSampler, proc: ProcSampler, netProc: NetProcSampler
    private let engine: Engine, store: ConfigStore, activity: ActivityState
    private let resources: ResourceSampler?
    private let battery: BatterySampler?
    private var bag = Set<AnyCancellable>()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displayAsleep = false, systemAsleep = false, sessionInactive = false

    init(monitor: Monitor, net: NetSampler, proc: ProcSampler, netProc: NetProcSampler,
         engine: Engine, store: ConfigStore, activity: ActivityState, resources: ResourceSampler? = nil,
         battery: BatterySampler? = nil) {
        self.monitor = monitor; self.net = net; self.proc = proc; self.netProc = netProc
        self.engine = engine; self.store = store; self.activity = activity; self.resources = resources
        self.battery = battery
        Publishers.Merge(store.objectWillChange, activity.objectWillChange)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.apply() }.store(in: &bag)
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemAsleep = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        observe(.default, .NSProcessInfoPowerStateDidChange) { _ in }
        apply()
    }
    deinit { for (center, token) in observers { center.removeObserver(token) } }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, mutation: @escaping (SamplingCoordinator) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; mutation(self); self.apply()
        }
        observers.append((center, token))
    }
    private func apply() {
        let policy = SamplingPolicy(config: store.config, panelVisible: activity.panelVisible,
            settingsVisible: activity.settingsVisible, displayAsleep: displayAsleep || sessionInactive,
            systemAsleep: systemAsleep, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        monitor.setSamplingInterval(policy.sensors, controlInterval: policy.controlSensors)
        net.setSamplingInterval(policy.network)
        proc.windowSeconds = store.config.cpuWindow.seconds
        proc.setSamplingInterval(policy.processes)
        let awake = !displayAsleep && !sessionInactive && !systemAsleep
        resources?.setSamplingInterval(activity.panelVisible && awake ? 10 : nil)
        // Battery readings are display-only: Settings gets a faster cadence, a
        // panel without the battery section none at all.
        battery?.setSamplingInterval(!awake ? nil : activity.settingsVisible ? 5
            : activity.panelVisible && store.config.showBatteryPanel ? 10 : nil)
        netProc.suspended = displayAsleep || sessionInactive || systemAsleep
        engine.setSuspended(systemAsleep)
    }
}
