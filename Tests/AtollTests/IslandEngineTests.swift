import Testing
import Foundation
import SwiftUI
@testable import Atoll

@Suite("Island engine: spring solver")
struct SpringSolverTests {
    static let tokens: [SpringToken] = [Motion.Token.open, Motion.Token.close, Motion.Token.morph, Motion.Token.split, Motion.Token.hover]

    /// The solver must draw the same curve SwiftUI animates with, or the engine's island and SwiftUI's content drift apart.
    @Test(arguments: tokens)
    func matchesSwiftUISpring(_ token: SpringToken) {
        let solver = SpringSolver(token)
        let travel = 400.0
        var worst = 0.0
        for i in 0...240 {
            let t = Double(i) / 240
            let swiftUI = token.spring.value(target: travel, time: t)
            let ours = MotionCurve.spring(solver).evaluate(from: 0, to: travel, v0: 0, at: t).value
            worst = max(worst, abs(swiftUI - ours))
        }
        #expect(worst < 0.25, "worst \(worst) pt for \(token)")
    }

    @Test(arguments: tokens)
    func matchesSwiftUIWithVelocity(_ token: SpringToken) {
        let solver = SpringSolver(token)
        var worst = 0.0
        for i in 0...240 {
            let t = Double(i) / 240
            let swiftUI = token.spring.value(target: 120.0, initialVelocity: 900.0, time: t)
            let ours = MotionCurve.spring(solver).evaluate(from: 0, to: 120, v0: 900, at: t).value
            worst = max(worst, abs(swiftUI - ours))
        }
        #expect(worst < 0.25, "worst \(worst) pt for \(token)")
    }

    @Test func coefficientsFollowResponseAndDamping() {
        // m = 1: k = (2π/response)², c = 4πζ/response (the table in the engine design).
        let open = SpringSolver(Motion.Token.open)
        #expect(abs(open.stiffness - 438.6) < 0.1)
        #expect(abs(open.dampingCoefficient - 33.51) < 0.01)
        let close = SpringSolver(Motion.Token.close)
        #expect(abs(close.stiffness - 584.0) < 0.1)
        #expect(abs(close.dampingCoefficient - 48.33) < 0.01)
    }

    @Test func underdampedOvershootsCriticalDoesNot() {
        let open = MotionCurve.spring(SpringSolver(Motion.Token.open))
        let close = MotionCurve.spring(SpringSolver(Motion.Token.close))
        var openPeak = 0.0, closePeak = 0.0
        for i in 0...600 {
            let t = Double(i) / 600
            openPeak = max(openPeak, open.evaluate(from: 0, to: 100, v0: 0, at: t).value)
            closePeak = max(closePeak, close.evaluate(from: 0, to: 100, v0: 0, at: t).value)
        }
        #expect(openPeak > 100.5)
        #expect(closePeak <= 100.0001)
    }

    /// Velocity is the true derivative of position (it carries an interrupted morph into the next one).
    @Test(arguments: tokens)
    func velocityIsTheDerivative(_ token: SpringToken) {
        let curve = MotionCurve.spring(SpringSolver(token))
        let h = 1e-5
        for t in stride(from: 0.01, through: 0.6, by: 0.05) {
            let a = curve.evaluate(from: 30, to: 300, v0: -200, at: t - h).value
            let b = curve.evaluate(from: 30, to: 300, v0: -200, at: t + h).value
            let v = curve.evaluate(from: 30, to: 300, v0: -200, at: t).velocity
            #expect(abs((b - a) / (2 * h) - v) < 0.01)
        }
    }

    /// Retargeting mid-flight from the solver's exact state continues position and velocity with no jump.
    @Test func retargetIsContinuous() {
        let curve = MotionCurve.spring(SpringSolver(Motion.Token.open))
        let cut = 0.09
        let mid = curve.evaluate(from: 32, to: 180, v0: 0, at: cut)
        let next = MotionCurve.spring(SpringSolver(Motion.Token.close))
        let start = next.evaluate(from: mid.value, to: 32, v0: mid.velocity, at: 0)
        #expect(abs(start.value - mid.value) < 1e-9)
        #expect(abs(start.velocity - mid.velocity) < 1e-9)
        // A millisecond on, the new curve continues along the old slope (no kink): only the new pull bends it.
        let dt = 0.001
        let new = next.evaluate(from: mid.value, to: 32, v0: mid.velocity, at: dt).value
        #expect(abs(new - (mid.value + mid.velocity * dt)) < 0.1)
    }

    @Test func settlesWithinTheEpsilon() {
        for token in Self.tokens {
            let solver = SpringSolver(token)
            let t = solver.settlingTime(x0: -300, v0: 0, epsilon: 0.05)
            #expect(t > 0.1 && t < 2, "\(token) settles in \(t) s")
            for i in 0..<100 {
                let x = solver.state(x0: -300, v0: 0, at: t + Double(i) / 100).x
                #expect(abs(x) < 0.05)
            }
        }
        #expect(SpringSolver(Motion.Token.open).settlingTime(x0: 0, v0: 0, epsilon: 0.05) == 0)
    }

    @Test func reduceMotionEasesInDuration() {
        let ease = MotionCurve(Motion.Token.open, reduceMotion: true)
        #expect(ease == .ease(duration: 0.2))
        #expect(abs(ease.evaluate(from: 0, to: 10, v0: 0, at: 0.1).value - 5) < 0.01)
        #expect(ease.evaluate(from: 0, to: 10, v0: 0, at: 0.25).value == 10)
        #expect(ease.duration(from: 0, to: 10, v0: 0, epsilon: 0.05) == 0.2)
    }
}
