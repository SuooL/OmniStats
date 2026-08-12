import Foundation

// A single timestamped scalar reading.
struct TimedSample {
    let t: CFAbsoluteTime
    let v: Double
}

// A rolling time-series buffer for one metric.
//
// Samplers call `record` on their native cadence; the buffer keeps at most
// `retention` seconds of history and (optionally) coalesces samples closer than
// `minInterval` so a fast sampler doesn't bloat a long window. Chart views pull a
// slice via `window(seconds:)`. Values are plain Doubles (°C, percent, bytes/sec)
// so a single buffer type serves temperature, fan%, and network rate alike.
final class MetricSeries {
    private(set) var samples: [TimedSample] = []
    let retention: Double            // seconds of history to keep
    private let minInterval: Double  // min seconds between stored points (0 = store every call)
    private var lastStored: CFAbsoluteTime = 0

    init(retention: Double, minInterval: Double = 0) {
        self.retention = retention
        self.minInterval = minInterval
    }

    func record(_ v: Double, at t: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard v.isFinite else { return }
        if minInterval > 0, !samples.isEmpty, t - lastStored < minInterval { return }
        samples.append(TimedSample(t: t, v: v))
        lastStored = t
        let cutoff = t - retention
        if let first = samples.first, first.t < cutoff {
            samples.removeAll { $0.t < cutoff }
        }
    }

    /// The samples within the last `seconds` (chronological order).
    func window(_ seconds: Double, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> [TimedSample] {
        let cutoff = now - seconds
        return samples.filter { $0.t >= cutoff }
    }

    var latest: Double? { samples.last?.v }
}
