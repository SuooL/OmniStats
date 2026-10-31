import Foundation

enum RefreshMode: String, Codable, CaseIterable, Identifiable {
    case responsive, balanced, economical
    var id: String { rawValue }
    var title: String { L.t("refresh.\(rawValue)") }
    // Seconds between readings; General shows these exact numbers.
    var intervals: (sensors: TimeInterval, network: TimeInterval, processes: TimeInterval) {
        switch self {
        case .responsive: return (3, 1, 5)
        case .balanced:   return (10, 3, 10)
        case .economical: return (30, 10, 30)
        }
    }
}

// Display sampling is independent of the safety-critical fan-control cadence.
// A nil interval means no timer, rather than a timer that wakes just to return.
struct SamplingPolicy: Equatable {
    let sensors: TimeInterval?
    let network: TimeInterval?
    let processes: TimeInterval?
    let controlSensors: TimeInterval?

    init(config: OmniStatsConfig, panelVisible: Bool, settingsVisible: Bool,
         displayAsleep: Bool, systemAsleep: Bool, lowPower: Bool) {
        if systemAsleep { sensors = nil; network = nil; processes = nil; controlSensors = nil; return }
        let visible = !displayAsleep && (panelVisible || settingsVisible)
        let mode: RefreshMode = visible ? .balanced : lowPower ? .economical : config.refreshMode
        // Only curve control needs fresh temperatures independently of display updates.
        controlSensors = config.mode == .curve ? 2 : nil
        sensors = displayAsleep ? nil : mode.intervals.sensors
        let showNetwork = !displayAsleep && (config.showNetworkInMenuBar || (panelVisible && config.showNetworkPanel))
        network = showNetwork ? mode.intervals.network : nil
        // Rolling averages still collect in the background. Realtime rankings
        // have no history requirement and can stop when their panel is hidden.
        let showProcesses = !displayAsleep && config.showProcesses
            && (panelVisible || config.cpuWindow != .realtime)
        processes = showProcesses ? mode.intervals.processes : nil
    }
}

// Monotonic time prevents clock adjustments from corrupting rates and retention.
private enum SamplingClock {
    static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()
}
func sampleTime() -> TimeInterval { Double(mach_continuous_time()) * SamplingClock.scale }
