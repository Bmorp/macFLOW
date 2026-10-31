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
        for token in [Motion.Token.open, Motion.Token.close, Motion.Token.morph, Motion.Token.workspace] {
            let s = SpringSolver(token)
            #expect(abs(s.stiffness - pow(2 * .pi / token.response, 2)) < 0.01)
            #expect(abs(s.dampingCoefficient - 4 * .pi * token.damping / token.response) < 0.01)
        }
    }

    /// The brief: no visible bounce. Opening may overshoot by a hair; closing by less than half a point in 100.
    @Test func springsSettleWithoutAVisibleBounce() {
        func peak(_ token: SpringToken) -> Double {
            let curve = MotionCurve.spring(SpringSolver(token))
            return (0...600).map { curve.evaluate(from: 0, to: 100, v0: 0, at: Double($0) / 600).value }.max() ?? 0
        }
        #expect(peak(Motion.Token.open) < 101.5)
        #expect(peak(Motion.Token.close) < 100.5)
        #expect(peak(Motion.Token.workspace) < 101)
        for token in [Motion.Token.open, Motion.Token.close, Motion.Token.morph, Motion.Token.workspace, Motion.Token.hover] {
            #expect((0.82...0.92).contains(token.damping))
        }
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

@Suite("Island engine: geometry")
struct IslandGeometryTests {
    @Test func outlineClampsLikeTheLegacyShape() {
        // A shoulder can't exceed a quarter of the width or half the height; a corner can't outgrow the body.
        let f = IslandFrame(width: 40, height: 20, shoulder: 22, corner: 30, slide: 0, rim: 1, light: 1)
        let g = IslandOutlineGeometry(f, centerX: 100)
        #expect(g.shoulder <= 10)
        #expect(g.body.minX >= 80 && g.body.maxX <= 120)
        #expect(g.cornerRadius <= 20)
    }

    @Test func zoomNeverExceedsOne() {
        #expect(IslandGeometry.zoom(live: CGSize(width: 800, height: 400), target: CGSize(width: 400, height: 200)) == 1)
        let z = IslandGeometry.zoom(live: CGSize(width: 200, height: 200), target: CGSize(width: 400, height: 200))
        #expect(abs(z - 0.5) < 1e-9)
    }

    @Test func mixInterpolatesEveryChannel() {
        let a = IslandFrame(width: 100, height: 30, shoulder: 8, corner: 10, slide: 0, rim: 0, light: 0)
        let b = IslandFrame(width: 500, height: 230, shoulder: 22, corner: 30, slide: 0, rim: 0.85, light: 1)
        let m = IslandFrame.mix(a, b, 0.25)
        #expect(m.width == 200 && m.height == 80 && abs(m.rim - 0.2125) < 1e-9 && m.light == 0.25)
    }
}

@Suite("Island engine: gestures")
struct InteractiveTransitionTests {
    @Test func bandIsOneToOneInsideAndResistsOutside() {
        for p in stride(from: 0.0, through: 1.0, by: 0.1) { #expect(InteractiveTransition.band(p) == p) }
        let a = InteractiveTransition.band(1.2) - 1
        let b = InteractiveTransition.band(2.2) - 1
        #expect(a > 0 && b > a)
        #expect(b < InteractiveTransition.stretch)   // never more than a tenth past the end, however far the finger goes
        #expect(InteractiveTransition.band(-0.5) < 0)
        #expect(InteractiveTransition.band(-0.5) > -InteractiveTransition.stretch)
        // Monotone and continuous across the ends.
        #expect(abs(InteractiveTransition.band(1.0001) - 1.0001) < 1e-3)
    }

    @Test func slideFollowsThenResists() {
        #expect(abs(InteractiveTransition.slide(2)) < 2)
        #expect(InteractiveTransition.slide(-30) < 0)
        #expect(abs(InteractiveTransition.slide(10_000)) < 40)
        #expect(InteractiveTransition.slide(80) > InteractiveTransition.slide(40))
    }

    @Test func completesByPositionOrFlick() {
        // Slowly past halfway completes; slowly short of it doesn't.
        #expect(InteractiveTransition.completes(progress: 0.6, velocity: 0, travel: 90))
        #expect(!InteractiveTransition.completes(progress: 0.4, velocity: 0, travel: 60))
        // A flick completes from the start (but not a twitch).
        #expect(InteractiveTransition.completes(progress: 0.1, velocity: 1.5, travel: 30))
        #expect(!InteractiveTransition.completes(progress: 0.02, velocity: 3, travel: 3))
        // Flicking back while past halfway cancels.
        #expect(!InteractiveTransition.completes(progress: 0.6, velocity: -2, travel: 90))
        // Past the end counts as the end.
        #expect(InteractiveTransition.completes(progress: 1.4, velocity: 0, travel: 200))
    }

    @Test func detentFiresOnceAndRearms() {
        var d = InteractiveTransition.Detent()
        func fires(_ p: Double) -> Bool { d.update(progress: p) }
        #expect(!fires(0.3))
        #expect(fires(0.52))
        #expect(!fires(0.6))          // still past it: no second tick
        #expect(!fires(0.45))         // backing off a little doesn't re-arm
        #expect(!fires(0.55))
        #expect(!fires(0.3))          // backed off enough: re-armed...
        #expect(fires(0.5))           // ...and fires again on the next crossing
        #expect(d.fired)
    }

    @Test func velocityIsTheSlopeOfTheLastHundredMilliseconds() {
        var t = VelocityTracker()
        for i in 0..<20 { t.add(Double(i) * 4, at: 10 + Double(i) * 0.008) }   // 500 points/s
        #expect(abs(t.velocity(at: 10 + 19 * 0.008 + 0.005) - 500) < 1)
        // Fingers that stopped before lifting leave no velocity.
        #expect(t.velocity(at: 10 + 19 * 0.008 + 0.2) == 0)
        // Old movement outside the window doesn't count.
        var u = VelocityTracker()
        u.add(0, at: 0); u.add(500, at: 0.05)           // fast, long ago
        for i in 0..<12 { u.add(500, at: 1 + Double(i) * 0.01) }   // then still
        #expect(abs(u.velocity(at: 1.115)) < 1e-6)
        #expect(VelocityTracker().velocity(at: 0) == 0)
    }
}

@Suite("Island engine: liquid bridge")
@MainActor
struct LiquidBridgeTests {
    static let params = LiquidBridge.Params(centerX: 400, islandWidth: 230, height: 32, diameter: 32, restOffset: 150, softness: 13)

    private func count(_ path: CGPath) -> Int {
        var n = 0
        path.applyWithBlock { _ in n += 1 }
        return n
    }

    @Test func everyPullHasTheSameNumberOfPoints() {
        // Required for the render server to interpolate the keyframes instead of snapping between them.
        let counts = Set(stride(from: 0.0, through: 1.0, by: 0.05).map { count(LiquidBridge.path(progress: $0, Self.params)) })
        #expect(counts.count == 1)
    }

    @Test func theNeckStretchesThenBreaksAsTheBubbleLeaves() {
        let p = Self.params
        let bodyRight = p.centerX + p.islandWidth / 2 - IslandModel.compactFlare
        let between = CGPoint(x: bodyRight + 3, y: 12)   // just beyond the island's end
        let restingBubble = CGPoint(x: p.centerX + p.restOffset, y: 16)
        let tucked = LiquidBridge.path(progress: 0, p)
        let pulling = LiquidBridge.path(progress: 0.5, p)
        let out = LiquidBridge.path(progress: 1, p)
        // Half way out, the bubble is still joined to the island by a neck.
        #expect(pulling.contains(between))
        // Detached, it sits at its rest position with open space between it and the island.
        #expect(out.contains(restingBubble))
        #expect(!out.contains(between))
        // Tucked in, the bubble hides inside the island's end.
        #expect(!tucked.contains(restingBubble))
    }
}
