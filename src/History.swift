import Foundation

struct TimedSample {
    let t: TimeInterval
    let v: Double
    var cadence: TimeInterval = 2
}

// Amortized prefix eviction and a hard capacity bound long-lived histories.
final class MetricSeries {
    private var storage: [TimedSample] = []
    private var head = 0
    let retention: Double
    private let minInterval: Double
    private let capacity: Int
    var samples: [TimedSample] { Array(storage.dropFirst(head)) }

    init(retention: Double, minInterval: Double = 0, capacity: Int = 3601) {
        self.retention = max(0, retention)
        self.minInterval = max(0, minInterval)
        self.capacity = max(1, capacity)
    }

    func record(_ value: Double, at time: TimeInterval = sampleTime(), cadence: TimeInterval = 2) {
        guard value.isFinite, time.isFinite else { return }
        if let last = storage.last {
            if time < last.t { storage.removeAll(keepingCapacity: true); head = 0 }
            else if time - last.t < minInterval { return }
        }
        storage.append(TimedSample(t: time, v: value, cadence: max(1, cadence)))
        while head < storage.count && storage[head].t < time - retention { head += 1 }
        head = max(head, storage.count - capacity)
        if head >= 512 || head * 2 >= storage.count {
            storage.removeFirst(head); head = 0
        }
    }

    func window(_ seconds: Double, now: TimeInterval = sampleTime()) -> [TimedSample] {
        Array(storage.dropFirst(head).filter { $0.t >= now - seconds && $0.t <= now })
    }
    var latest: Double? { storage.last?.v }
}
