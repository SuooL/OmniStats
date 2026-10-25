import Foundation

enum RefreshMode: String, Codable, CaseIterable, Identifiable {
    case responsive, balanced, economical
    var id: String { rawValue }
    var title: String { L.t("refresh.\(rawValue)") }
}

// Display sampling is independent of the safety-critical fan-control cadence.
// A nil interval means no timer, rather than a timer that wakes just to return.
struct SamplingPolicy: Equatable {
    let sensors: TimeInterval?
    let network: TimeInterval?
    let processes: TimeInterval?

    init(config: OmniStatsConfig, panelVisible: Bool, settingsVisible: Bool,
         displayAsleep: Bool, systemAsleep: Bool, lowPower: Bool) {
        if systemAsleep { sensors = nil; network = nil; processes = nil; return }
        let mode: RefreshMode = lowPower ? .economical : config.refreshMode
        let visible = !displayAsleep && (panelVisible || settingsVisible)
        let activeControl = config.mode != .auto
        let backgroundSensor: Double = mode == .responsive ? 3 : mode == .balanced ? 5 : 10
        sensors = activeControl || visible ? 2 : displayAsleep ? nil : backgroundSensor
        let showNetwork = !displayAsleep && (config.showNetworkInMenuBar || (panelVisible && config.showNetworkPanel))
        network = showNetwork ? (panelVisible ? 1 : mode == .responsive ? 1 : mode == .balanced ? 2 : 5) : nil
        // Rolling averages still collect in the background. Realtime rankings
        // have no history requirement and can stop when their panel is hidden.
        let showProcesses = !displayAsleep && config.showProcesses
            && (panelVisible || config.cpuWindow != .realtime)
        processes = showProcesses ? (panelVisible ? 2 : mode == .responsive ? 5 : mode == .balanced ? 10 : 15) : nil
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
