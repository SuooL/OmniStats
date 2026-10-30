import AppKit
import Combine

// omnistats:// links, e.g. from a Shortcuts "Open URL" action. Only charge-limit
// actions are reachable this way; nothing a link can trigger drains the battery.
//   omnistats://battery/limit?value=80      omnistats://battery/enable | disable
//   omnistats://battery/topup?enabled=1|0   omnistats://battery/led?mode=system|status|off
//   omnistats://settings/battery
enum AutomationCommand: Equatable {
    case setLimit(Int)
    case enableLimit(Bool)
    case topUp(Bool)
    case led(ChargeLimitSettings.LedMode)
    case openBatterySettings

    init?(url: URL) {
        guard url.scheme?.lowercased() == "omnistats", let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name.lowercased()] = item.value?.lowercased() }
        switch (host, url.path.lowercased()) {
        case ("battery", "/limit"):
            guard let value = query["value"].flatMap({ Int($0) }), ChargeLimitSettings.limitRange.contains(value) else { return nil }
            self = .setLimit(value)
        case ("battery", "/enable"): self = .enableLimit(true)
        case ("battery", "/disable"): self = .enableLimit(false)
        case ("battery", "/topup"):
            switch query["enabled"] ?? "1" {
            case "1", "true", "on": self = .topUp(true)
            case "0", "false", "off": self = .topUp(false)
            default: return nil
            }
        case ("battery", "/led"):
            guard let mode = ChargeLimitSettings.LedMode.allCases.first(where: { "\($0)" == query["mode"] }) else { return nil }
            self = .led(mode)
        case ("settings", "/battery"): self = .openBatterySettings
        default: return nil
        }
    }

    // A partial BSET: the helper keeps every field not named here.
    var helperCommand: String? {
        switch self {
        case .setLimit(let value): return "BSET enabled=1 limit=\(value)"
        case .enableLimit(let enabled): return "BSET enabled=\(enabled ? 1 : 0)"
        case .topUp(let enabled): return "BTOPUP \(enabled ? 1 : 0)"
        case .led(let mode): return "BSET led=\(mode.rawValue)"
        case .openBatterySettings: return nil
        }
    }
}

// A repeating charge action, e.g. "weekdays at 07:00, charge to full".
struct ChargeSchedule: Codable, Equatable, Identifiable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case setLimit, topUp, enable, disable
        var id: String { rawValue }
    }
    var id = UUID()
    var enabled = true
    var weekdays: Set<Int> = Set(1...7)   // Calendar weekdays: 1 = Sunday
    var hour = 7
    var minute = 0
    var action: Action = .topUp
    var limit = 80                       // used by .setLimit

    var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute) && !weekdays.isEmpty
            && weekdays.isSubset(of: 1...7) && ChargeLimitSettings.limitRange.contains(limit)
    }
    var command: AutomationCommand {
        switch action {
        case .setLimit: return .setLimit(limit)
        case .topUp: return .topUp(true)
        case .enable: return .enableLimit(true)
        case .disable: return .enableLimit(false)
        }
    }
}

enum ChargeScheduler {
    // Latest occurrence in (from, to]. Days are walked in the calendar, so DST
    // and time-zone changes keep the wall-clock time.
    static func occurrence(of schedule: ChargeSchedule, after from: Date, upTo to: Date, calendar: Calendar) -> Date? {
        guard schedule.enabled, schedule.isValid, to > from else { return nil }
        let today = calendar.startOfDay(for: to)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let date = calendar.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: day),
                  date <= to else { continue }
            if date <= from { return nil }
            if schedule.weekdays.contains(calendar.component(.weekday, from: date)) { return date }
        }
        return nil
    }
    // Actions that came due since the last check, oldest first. A Mac that slept
    // or was off for longer than `catchUp` skips what it missed before that.
    static func due(_ schedules: [ChargeSchedule], from: Date, to: Date, catchUp: TimeInterval = 12 * 3600,
                    calendar: Calendar) -> [ChargeSchedule] {
        let start = max(from, to.addingTimeInterval(-catchUp))
        return schedules.compactMap { schedule in
            occurrence(of: schedule, after: start, upTo: to, calendar: calendar).map { ($0, schedule) }
        }
        .sorted { $0.0 < $1.0 }.map(\.1)
    }
    static func next(_ schedules: [ChargeSchedule], after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        return schedules.compactMap { schedule -> Date? in
            guard schedule.enabled, schedule.isValid else { return nil }
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                      let date = calendar.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: day),
                      date > now, schedule.weekdays.contains(calendar.component(.weekday, from: date)) else { continue }
                return date
            }
            return nil
        }.min()
    }
}

// Runs due schedules while the app runs: one timer for the next occurrence, and
// a fresh look after wake, clock changes and edits. The last check is persisted
// so a relaunch catches up once instead of repeating or dropping actions.
final class ChargeScheduleRunner {
    static let lastCheckKey = "OmniStats.chargeScheduleLastCheck"
    private let store: ConfigStore
    private let defaults: UserDefaults
    private let run: (AutomationCommand) -> Void
    private let now: () -> Date
    private let calendar: Calendar
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var nextFire: Date?

    init(store: ConfigStore, defaults: UserDefaults = .standard, calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init, run: @escaping (AutomationCommand) -> Void) {
        self.store = store; self.defaults = defaults; self.calendar = calendar; self.now = now; self.run = run
        if defaults.object(forKey: Self.lastCheckKey) == nil { defaults.set(now().timeIntervalSince1970, forKey: Self.lastCheckKey) }
        store.$config.map(\.chargeSchedules).removeDuplicates().dropFirst()
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.check() }.store(in: &bag)
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name) in [(workspace, NSWorkspace.didWakeNotification),
                               (NotificationCenter.default, Notification.Name.NSSystemClockDidChange),
                               (NotificationCenter.default, Notification.Name.NSCalendarDayChanged)] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.check() }))
        }
        check()
    }
    deinit {
        timer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
    }

    func check() {
        let current = now()
        let last = Date(timeIntervalSince1970: defaults.double(forKey: Self.lastCheckKey))
        for schedule in ChargeScheduler.due(store.config.chargeSchedules, from: last, to: current, calendar: calendar) {
            run(schedule.command)
        }
        defaults.set(current.timeIntervalSince1970, forKey: Self.lastCheckKey)
        timer?.invalidate(); timer = nil
        nextFire = ChargeScheduler.next(store.config.chargeSchedules, after: current, calendar: calendar)
        guard let nextFire else { return }
        let timer = Timer(fire: nextFire, interval: 0, repeats: false) { [weak self] _ in self?.check() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
}
