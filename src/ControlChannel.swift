import Foundation

enum ControlPlan {
    case automatic
    case manual(rpms: [Int], validUntil: TimeInterval)
}

// The C socket is used only on this queue. At most one command batch is in
// flight and one latest intention is pending; obsolete slider updates cannot
// build up a backlog. All public entry points and completions use the main queue.
final class ControlChannel {
    private let queue = DispatchQueue(label: "com.omnistats.control", qos: .userInitiated)
    private let worker: Worker
    init(now: @escaping () -> TimeInterval = sampleTime) { worker = Worker(now: now) }
    private var inFlight = false
    private var pending: (ControlPlan, (Bool) -> Void)?
    private var statusInFlight = false

    func submit(_ plan: ControlPlan, completion: @escaping (Bool) -> Void) {
        pending = (plan, completion)
        runPending()
    }
    private func runPending() {
        guard !inFlight, let (plan, completion) = pending else { return }
        pending = nil; inFlight = true
        queue.async { [weak self, worker] in
            let result = worker.apply(plan)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                completion(result)
                self.runPending()
            }
        }
    }
    func poll(completion: @escaping (Bool, Int) -> Void) {
        guard !statusInFlight else { return }
        statusInFlight = true
        queue.async { [weak self] in
            let available = cb_ctl_available() == 1
            let version = available ? Int(cb_ctl_version()) : 0
            DispatchQueue.main.async { [weak self] in
                self?.statusInFlight = false
                completion(available, version)
            }
        }
    }
    func disconnect(completion: @escaping () -> Void) {
        pending = nil
        queue.async { [worker] in
            _ = worker.revert()
            cb_ctl_disconnect()
            DispatchQueue.main.async(execute: completion)
        }
    }
    func shutdown() {
        pending = nil
        queue.sync { [worker] in _ = worker.revert(); cb_ctl_disconnect() }
    }

    private final class Worker {
        private let now: () -> TimeInterval
        init(now: @escaping () -> TimeInterval) { self.now = now }
        private var lastSuccess: TimeInterval = 0
        private var lastRPMs: [Int]?
        private var connection: UInt64 = 0
        private var automaticConfirmed = false

        func revert() -> Bool {
            lastRPMs = nil
            automaticConfirmed = cb_ctl_auto_all() == 0
            return automaticConfirmed
        }
        func apply(_ plan: ControlPlan) -> Bool {
            switch plan {
            case .automatic:
                return automaticConfirmed || revert()
            case let .manual(rpms, validUntil):
                guard now() <= validUntil, !rpms.isEmpty else { return revert() }
                automaticConfirmed = false
                // A stalled app may outlive the helper watchdog on the same socket.
                // Reapply targets after a gap instead of heartbeating firmware auto.
                if lastRPMs == rpms, now() - lastSuccess < 6,
                   cb_ctl_heartbeat() == 0, connection == cb_ctl_connection_id(), now() <= validUntil {
                    lastSuccess = now(); return true
                }
                var batchConnection: UInt64?
                for (fan, rpm) in rpms.enumerated() {
                    guard now() <= validUntil, cb_ctl_set(Int32(fan), Int32(rpm)) >= 0 else {
                        _ = revert(); cb_ctl_disconnect(); return false
                    }
                    let current = cb_ctl_connection_id()
                    if let previous = batchConnection, previous != current {
                        _ = revert(); cb_ctl_disconnect(); return false
                    }
                    batchConnection = current
                }
                lastRPMs = rpms; connection = cb_ctl_connection_id(); lastSuccess = now()
                return true
            }
        }
    }
}
