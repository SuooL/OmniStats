import SwiftUI

// Shape-preserving cubic interpolation of measured points. Tangent limiting
// prevents overshoot and invented spikes. Apply separately to each sampled run;
// missing time remains a gap. Neither stored samples nor fan control are changed.
enum SmoothHistory {
    struct Segment {
        let start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint
        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u*u*u*start.x + 3*u*u*t*control1.x + 3*u*t*t*control2.x + t*t*t*end.x,
                           y: u*u*u*start.y + 3*u*u*t*control1.y + 3*u*t*t*control2.y + t*t*t*end.y)
        }
    }
    static func segments(_ input: [CGPoint]) -> [Segment] {
        var points: [CGPoint] = []
        for p in input where p.x.isFinite && p.y.isFinite {
            if let last = points.last, p.x <= last.x { continue }
            points.append(p)
        }
        guard points.count > 1 else { return [] }
        let n = points.count
        let widths = (0..<n-1).map { points[$0+1].x - points[$0].x }
        let slopes = (0..<n-1).map { (points[$0+1].y - points[$0].y) / widths[$0] }
        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]; tangents[n-1] = slopes[n-2]
        if n > 2 {
            for i in 1..<n-1 where slopes[i-1] * slopes[i] > 0 {
                let w1 = 2 * widths[i] + widths[i-1], w2 = widths[i] + 2 * widths[i-1]
                tangents[i] = (w1+w2) / (w1/slopes[i-1] + w2/slopes[i])
            }
        }
        for i in 0..<n-1 {
            if slopes[i] == 0 { tangents[i] = 0; tangents[i+1] = 0; continue }
            let a = tangents[i] / slopes[i], b = tangents[i+1] / slopes[i]
            let norm = hypot(a, b)
            if norm > 3 {
                tangents[i] = 3 / norm * a * slopes[i]
                tangents[i+1] = 3 / norm * b * slopes[i]
            }
        }
        return (0..<n-1).map { i in
            let h = widths[i] / 3
            return Segment(start: points[i], control1: CGPoint(x: points[i].x+h, y: points[i].y+tangents[i]*h),
                           control2: CGPoint(x: points[i+1].x-h, y: points[i+1].y-tangents[i+1]*h), end: points[i+1])
        }
    }
    static func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for s in segments(points) { path.addCurve(to: s.end, control1: s.control1, control2: s.control2) }
        return path
    }
}
