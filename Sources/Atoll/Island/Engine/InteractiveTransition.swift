import CoreGraphics
import Foundation

/// The rules for a drag the island follows with the finger (Island Engine 2.0 › 1:1 gestures). Everything here is
/// plain arithmetic, so it's testable without a trackpad; `IslandController` feeds it scroll events and
/// `IslandEngine` draws the result.
enum InteractiveTransition {
    /// What a drag is heading for.
    enum Kind: Equatable {
        /// The closed island pulled down open.
        case pullOpen
        /// Home pulled down into the sheet.
        case toSheet
        /// The sheet pushed back up to Home.
        case toHome
        /// An open island pushed up closed.
        case close
        /// Sideways between places; `direction` is +1 for the next one (fingers moving left), −1 for the last.
        case tabs(direction: Int)

        var isTabs: Bool { if case .tabs = self { return true } else { return false } }
    }

    /// How far past its end a drag may show: a tenth of the way again, however far the finger goes.
    static let stretch = 0.12

    /// Rubber-banded progress: 1:1 inside 0…1, and past either end the island keeps following but with growing
    /// resistance, f(x) = (1 − 1/(0.55·x/d + 1))·d with d = `stretch`.
    static func band(_ p: Double) -> Double {
        func resist(_ over: Double) -> Double { (1 - 1 / (0.55 * over / stretch + 1)) * stretch }
        if p < 0 { return -resist(-p) }
        if p > 1 { return 1 + resist(p - 1) }
        return p
    }

    /// The sideways offset of content following a finger that has moved `travel` points: it follows, then resists.
    static func slide(_ travel: Double, limit: Double = 40) -> Double {
        let over = abs(travel)
        let shown = (1 - 1 / (0.55 * over / limit + 1)) * limit
        return travel < 0 ? -shown : shown
    }

    /// Whether letting go now completes the move: the finger's progress plus half a second of its velocity passes
    /// the halfway mark (the rule UIKit's interactive transitions use), and it travelled enough to be a decision.
    static func completes(progress p: Double, velocity v: Double, travel: Double, minimumTravel: Double = 10) -> Bool {
        guard travel >= minimumTravel else { return false }
        return min(1, max(0, p)) + 0.499 * v > 0.5
    }

    /// Where the "this will complete" haptic arms and re-arms: crossing halfway fires it once; the finger has to
    /// back off a tenth before it can fire again.
    struct Detent {
        private(set) var armed = false
        private(set) var fired = false

        /// Returns true on the update that crosses the line.
        mutating func update(progress p: Double) -> Bool {
            if !armed, p >= 0.5 {
                armed = true
                fired = true
                return true
            }
            if armed, p < 0.4 { armed = false }
            return false
        }
    }
}

/// Finger velocity from the last 100 ms of scroll events: the least-squares slope of position over event time.
/// It's zero when the fingers stopped before lifting (the last sample is more than 50 ms old at release).
struct VelocityTracker {
    private var samples: [(t: TimeInterval, x: Double)] = []

    mutating func reset() { samples.removeAll(keepingCapacity: true) }

    mutating func add(_ x: Double, at t: TimeInterval) {
        samples.append((t, x))
        while let first = samples.first, t - first.t > 0.1 { samples.removeFirst() }
    }

    /// Units per second at `time` (the release's event time).
    func velocity(at time: TimeInterval) -> Double {
        guard samples.count >= 2, let last = samples.last, time - last.t <= 0.05 else { return 0 }
        let n = Double(samples.count)
        let t0 = samples[0].t
        var st = 0.0, sx = 0.0, stt = 0.0, stx = 0.0
        for s in samples {
            let t = s.t - t0
            st += t; sx += s.x; stt += t * t; stx += t * s.x
        }
        let denominator = n * stt - st * st
        guard abs(denominator) > 1e-12 else { return 0 }
        return (n * stx - st * sx) / denominator
    }
}
