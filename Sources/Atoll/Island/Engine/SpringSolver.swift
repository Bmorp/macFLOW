import Foundation

/// A damped spring, evaluated in closed form at any moment — the same physics as SwiftUI's
/// `.spring(response:dampingFraction:)` (mass 1, stiffness (2π/response)², damping 4πζ/response).
///
/// The island engine bakes every channel of a morph from one of these, so it always knows the shape's exact
/// position *and velocity* at any time: an interrupted morph restarts from there toward its new target with no
/// jump and no kink, which reading Core Animation's presentation layer (position only) can't give.
struct SpringSolver: Hashable, Sendable {
    /// Natural angular frequency ω₀ (rad/s).
    let omega: Double
    /// Damping ratio ζ.
    let zeta: Double

    init(response: Double, damping: Double) {
        omega = 2 * .pi / max(response, 0.001)
        zeta = max(0, damping)
    }

    init(_ token: SpringToken) { self.init(response: token.response, damping: token.damping) }

    var stiffness: Double { omega * omega }
    var dampingCoefficient: Double { 2 * zeta * omega }

    /// Displacement from the target and velocity after `t` seconds, starting `x0` from the target moving at `v0`.
    func state(x0: Double, v0: Double, at t: Double) -> (x: Double, v: Double) {
        guard t > 0 else { return (x0, v0) }
        if zeta < 0.999 {
            let a = zeta * omega
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let b = (v0 + a * x0) / wd
            let e = exp(-a * t), c = cos(wd * t), s = sin(wd * t)
            return (e * (x0 * c + b * s), e * ((b * wd - a * x0) * c - (a * b + x0 * wd) * s))
        } else if zeta <= 1.001 {
            // Critically damped.
            let b = v0 + omega * x0
            let e = exp(-omega * t)
            return ((x0 + b * t) * e, (b - omega * (x0 + b * t)) * e)
        } else {
            let root = (zeta * zeta - 1).squareRoot()
            let r1 = -omega * (zeta - root), r2 = -omega * (zeta + root)
            let c2 = (v0 - r1 * x0) / (r2 - r1), c1 = x0 - c2
            let e1 = exp(r1 * t), e2 = exp(r2 * t)
            return (c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
        }
    }

    /// An upper bound on |displacement| at `t` (the decay envelope), for deciding when a spring has settled.
    func envelope(x0: Double, v0: Double, at t: Double) -> Double {
        if zeta < 0.999 {
            let a = zeta * omega
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let b = (v0 + a * x0) / wd
            return exp(-a * t) * (x0 * x0 + b * b).squareRoot()
        } else if zeta <= 1.001 {
            return (abs(x0) + abs(v0 + omega * x0) * t) * exp(-omega * t)
        } else {
            let root = (zeta * zeta - 1).squareRoot()
            let r1 = -omega * (zeta - root), r2 = -omega * (zeta + root)
            let c2 = (v0 - r1 * x0) / (r2 - r1), c1 = x0 - c2
            return abs(c1) * exp(r1 * t) + abs(c2) * exp(r2 * t)
        }
    }

    /// How long until the motion stays within `epsilon` of the target (velocity included), capped at `limit`.
    func settlingTime(x0: Double, v0: Double, epsilon: Double, limit: Double = 3) -> Double {
        guard abs(x0) > epsilon || abs(v0) > epsilon * omega else { return 0 }
        var t = 0.0
        let step = 1.0 / 240
        while t < limit {
            t += step
            // The velocity term keeps a spring that's passing through the target from counting as settled.
            if envelope(x0: x0, v0: v0, at: t) < epsilon,
               abs(state(x0: x0, v0: v0, at: t).v) < epsilon * omega { return t }
        }
        return limit
    }
}

/// How one move runs: a spring (interruptible, velocity carried through), or under Reduce Motion a short ease.
enum MotionCurve: Hashable, Sendable {
    case spring(SpringSolver)
    /// SwiftUI's `.easeInOut(duration:)`: cubic Bézier (0.42, 0, 0.58, 1).
    case ease(duration: Double)

    init(_ token: SpringToken, reduceMotion: Bool) {
        self = reduceMotion ? .ease(duration: token.reduced) : .spring(SpringSolver(token))
    }

    /// Value and velocity of one channel at `t`, moving from `from` (with velocity `v0`) to `to`.
    func evaluate(from: Double, to: Double, v0: Double, at t: Double) -> (value: Double, velocity: Double) {
        switch self {
        case .spring(let s):
            let st = s.state(x0: from - to, v0: v0, at: t)
            return (to + st.x, st.v)
        case .ease(let d):
            guard d > 0, t < d else { return (to, 0) }
            let (p, dp) = Self.easeInOut(max(0, t) / d)
            return (from + (to - from) * p, (to - from) * dp / d)
        }
    }

    /// How long a channel takes to settle within `epsilon`.
    func duration(from: Double, to: Double, v0: Double, epsilon: Double) -> Double {
        switch self {
        case .spring(let s): s.settlingTime(x0: from - to, v0: v0, epsilon: epsilon)
        case .ease(let d): abs(from - to) > epsilon ? d : 0
        }
    }

    /// Progress and its derivative for SwiftUI's ease-in-out at time fraction `x`.
    static func easeInOut(_ x: Double) -> (Double, Double) {
        // Bézier with P1 = (0.42, 0), P2 = (0.58, 1): solve bx(u) = x by Newton, then read by(u).
        let x1 = 0.42, x2 = 0.58, y1 = 0.0, y2 = 1.0
        func bx(_ u: Double) -> Double { 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u }
        func dbx(_ u: Double) -> Double { 3 * (1 - u) * (1 - u) * x1 + 6 * (1 - u) * u * (x2 - x1) + 3 * u * u * (1 - x2) }
        func by(_ u: Double) -> Double { 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u }
        func dby(_ u: Double) -> Double { 3 * (1 - u) * (1 - u) * y1 + 6 * (1 - u) * u * (y2 - y1) + 3 * u * u * (1 - y2) }
        let x = min(1, max(0, x))
        var u = x
        for _ in 0..<8 {
            let d = dbx(u)
            guard abs(d) > 1e-9 else { break }
            u = min(1, max(0, u - (bx(u) - x) / d))
        }
        let d = dbx(u)
        return (by(u), d > 1e-9 ? dby(u) / d : 0)
    }
}
