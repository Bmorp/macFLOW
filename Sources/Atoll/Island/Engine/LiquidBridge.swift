import AppKit
import QuartzCore

/// The liquid neck between the closed island and its bubble (the second live activity), drawn in Core Animation.
///
/// The SwiftUI `LiquidSplit` blurs the shapes and thresholds them, every frame, on the main thread's behalf. This
/// does the same job once: it fits a smooth-min distance field around the island's trailing end and the bubble,
/// reads the silhouette's lower edge column by column, and bakes the whole spring as one `CAShapeLayer` path
/// animation. Every sample has the same number of points, so the render server interpolates between them, and the
/// main thread isn't involved again until the next change. `LiquidSplit` stays for snapshots, which can't draw layers.
@MainActor
final class LiquidBridge {
    let layer = CAShapeLayer()

    /// Everything the shape depends on besides how far the bubble has pulled away.
    struct Params: Equatable {
        var centerX: CGFloat
        var islandWidth: CGFloat
        var height: CGFloat
        var diameter: CGFloat
        var restOffset: CGFloat
        /// How softly the shapes melt together, in points (the blur the canvas used); small under Reduce Motion.
        var softness: CGFloat
    }

    private var params: Params?
    private var shownTarget = 0.0
    private var visible = false
    private var flight: (from: Double, velocity: Double, curve: MotionCurve, begin: CFTimeInterval, duration: Double, to: Double)?

    init() {
        layer.delegate = NoActions.shared
        layer.fillColor = NSColor.black.cgColor
        layer.strokeColor = nil
        layer.fillRule = .nonZero
    }

    /// Where the pull is at `time` (and how fast it's changing).
    private func state(at time: CFTimeInterval) -> (Double, Double) {
        guard let f = flight else { return (shownTarget, 0) }
        let t = time - f.begin
        guard t < f.duration else { return (f.to, 0) }
        let r = f.curve.evaluate(from: f.from, to: f.to, v0: f.velocity, at: max(0, t))
        return (r.value, r.velocity)
    }

    /// Moves the bridge to `target` (0 = bubble tucked into the island, 1 = detached). `delay` holds the start,
    /// as the legacy canvas's `.delay` did when the island has just closed. `token` nil jumps.
    func update(_ p: Params, target: Double, visible nowVisible: Bool, token: SpringToken?, delay: Double,
                reduceMotion: Bool, now: CFTimeInterval, frameRate: CAFrameRateRange) {
        let changedParams = p != params
        let changedTarget = target != shownTarget || nowVisible != visible
        guard changedParams || changedTarget || params == nil else { return }
        let first = params == nil
        let (x, v) = state(at: now)
        params = p
        visible = nowVisible
        let from = first ? target : x
        shownTarget = target

        guard let token, !first, from != target || v != 0, p.height > 0 else {
            flight = nil
            apply(progress: target, p, reduceMotion: reduceMotion)
            return
        }
        let curve = MotionCurve(token, reduceMotion: reduceMotion)
        let eps = 0.002
        let length = curve.duration(from: from, to: target, v0: v, epsilon: eps)
        guard length > 0 else {
            flight = nil
            apply(progress: target, p, reduceMotion: reduceMotion)
            return
        }
        let rate = 60.0
        let n = max(2, Int((length * rate).rounded(.up)) + 1)
        let total = Double(n - 1) / rate
        let begin = now + delay
        flight = (from, v, curve, begin, total, target)

        var values: [CGPath] = []
        var opacities: [Float] = []
        values.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) / rate
            let progress = i == n - 1 ? target : curve.evaluate(from: from, to: target, v0: v, at: t).value
            values.append(Self.path(progress: progress, p))
            opacities.append(Self.opacity(progress, reduceMotion: reduceMotion))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.path = values[n - 1]
        layer.opacity = opacities[n - 1]
        layer.add(animation("path", values, total, delay: delay, rate: frameRate), forKey: "bridge.path")
        if reduceMotion {
            layer.add(animation("opacity", opacities.map { $0 as NSNumber }, total, delay: delay, rate: frameRate), forKey: "bridge.opacity")
        } else {
            layer.removeAnimation(forKey: "bridge.opacity")
        }
        CATransaction.commit()
    }

    private func animation(_ keyPath: String, _ values: [Any], _ duration: CFTimeInterval, delay: Double, rate: CAFrameRateRange) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.duration = duration
        a.calculationMode = .linear
        if delay > 0 { a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay }
        // While it waits, show where it starts rather than where it ends.
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        a.preferredFrameRateRange = rate
        return a
    }

    private func apply(progress: Double, _ p: Params, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "bridge.path")
        layer.removeAnimation(forKey: "bridge.opacity")
        layer.path = Self.path(progress: progress, p)
        layer.opacity = Self.opacity(progress, reduceMotion: reduceMotion)
        CATransaction.commit()
    }

    private static func opacity(_ progress: Double, reduceMotion: Bool) -> Float {
        reduceMotion ? Float(min(1, max(0, progress))) : 1
    }

    // MARK: - Geometry

    /// Signed distance to a rounded rectangle (negative inside).
    private static func distance(_ x: CGFloat, _ y: CGFloat, _ r: CGRect, radius: CGFloat) -> CGFloat {
        let qx = abs(x - r.midX) - (r.width / 2 - radius)
        let qy = abs(y - r.midY) - (r.height / 2 - radius)
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
    }

    /// The silhouette for a pull of `progress`: a polygon along the top edge (above the screen) and down along the
    /// lower edge, one point per column, always the same number of points.
    static func path(progress rawProgress: Double, _ p: Params) -> CGPath {
        let progress = CGFloat(min(1, max(0, rawProgress)))
        // The same shapes the canvas drew: the island's trailing end, the bubble, and the sliver along the screen edge.
        let top: CGFloat = -24
        let bodyRight = p.centerX + p.islandWidth / 2 - IslandModel.compactFlare
        let startX = bodyRight - p.diameter / 2 - 2
        let restX = p.centerX + p.restOffset
        let cx = startX + (restX - startX) * progress
        let d = p.diameter * (0.55 + 0.45 * min(1, progress * 1.4))
        let end = CGRect(x: bodyRight - 34, y: top, width: 34, height: p.height + 22)
        let bubble = CGRect(x: cx - d / 2, y: top, width: d, height: (p.height - (p.diameter - d) / 2) - top)
        let sliver = CGRect(x: cx - d / 2 - 5, y: top, width: d + 10, height: 26)

        let k = max(p.softness, 0.5)
        // The sliver is only two points tall: the canvas's blur-and-threshold threw it away and kept just its fillets,
        // so it counts here as a field that never quite reaches the surface (+3).
        // Polynomial smooth-min: a fillet where two surfaces are within k of each other.
        func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let h = max(k - abs(a - b), 0) / k
            return min(a, b) - h * h * k * 0.25
        }
        func field(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            blend(distance(x, y, end, radius: 10),
                  blend(distance(x, y, bubble, radius: d / 2), distance(x, y, sliver, radius: 0) + 3))
        }

        let x0 = end.minX
        let x1 = restX + p.diameter / 2 + 6
        let columns = max(2, Int((x1 - x0).rounded(.up)))
        let floorY = p.height + 24
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: top))
        for i in 0...columns {
            let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(columns)
            var bottom = top
            if field(x, 0) <= 0 {
                if field(x, floorY) <= 0 {
                    bottom = floorY
                } else {
                    var lo: CGFloat = 0, hi = floorY
                    for _ in 0..<9 {
                        let mid = (lo + hi) / 2
                        if field(x, mid) <= 0 { lo = mid } else { hi = mid }
                    }
                    bottom = (lo + hi) / 2
                }
            }
            path.addLine(to: CGPoint(x: x, y: bottom))
        }
        path.addLine(to: CGPoint(x: x1, y: top))
        path.closeSubpath()
        return path
    }
}
