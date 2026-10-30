import AppKit
import QuartzCore

/// A view that is only a Core Animation layer tree the engine owns (layer-hosting): AppKit never touches its
/// sublayers' geometry, and it never takes clicks. The root is flipped so the island hangs from y = 0.
final class EngineLayerView: NSView {
    let root = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.isGeometryFlipped = true
        root.masksToBounds = false
        root.delegate = NoActions.shared
        layer = root
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }
}

/// Layer-backed container for the two content hosts. Its mask is a silhouette the engine animates, so content
/// is clipped by the same shape that's drawn — exactly, every frame, with no main-thread work.
final class ContentClipView: NSView {
    let mask = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        mask.isGeometryFlipped = true
        mask.delegate = NoActions.shared
        layer?.mask = mask
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        CATransaction.commit()
    }
}

/// Turns off implicit animations for layers the engine sets directly (it animates them explicitly or not at all).
final class NoActions: NSObject, CALayerDelegate {
    static let shared = NoActions()
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

/// The silhouette as native layers: a black body with continuous bottom corners (drawn analytically by the GPU)
/// and two small concave shoulders. Used twice: once filled on screen, once as the content's mask.
final class SilhouetteLayers {
    let root = CALayer()
    let body = CALayer()
    let left = CAShapeLayer()
    let right = CAShapeLayer()

    init(color: CGColor) {
        for l in [root, body, left, right] as [CALayer] { l.delegate = NoActions.shared }
        body.backgroundColor = color
        body.cornerCurve = .continuous
        // Flipped geometry: y grows downward, so the bottom corners are the max-Y ones.
        body.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        for s in [left, right] {
            s.fillColor = color
            s.strokeColor = nil
            s.bounds = .zero
        }
        root.addSublayer(left)
        root.addSublayer(right)
        root.addSublayer(body)
    }

    /// Sets the silhouette directly (no animation).
    func apply(_ g: IslandOutlineGeometry) {
        body.bounds = CGRect(origin: .zero, size: g.body.size)
        body.position = CGPoint(x: g.body.midX, y: g.body.midY)
        body.cornerRadius = g.cornerRadius
        left.position = CGPoint(x: g.body.minX, y: 0)
        right.position = CGPoint(x: g.body.maxX, y: 0)
        left.path = IslandOutlineGeometry.shoulderPath(g.shoulder, right: false)
        right.path = IslandOutlineGeometry.shoulderPath(g.shoulder, right: true)
    }

    /// Adds the baked keyframes for a run of outlines (and sets the model to the last one).
    func animate(_ outlines: [IslandOutlineGeometry], bake: Bake) {
        guard let last = outlines.last else { return }
        apply(last)
        bake.add(body, "bounds", outlines.map { NSValue(rect: CGRect(origin: .zero, size: $0.body.size)) })
        bake.add(body, "position", outlines.map { NSValue(point: CGPoint(x: $0.body.midX, y: $0.body.midY)) })
        bake.add(body, "cornerRadius", outlines.map { $0.cornerRadius as NSNumber })
        bake.add(left, "position", outlines.map { NSValue(point: CGPoint(x: $0.body.minX, y: 0)) })
        bake.add(right, "position", outlines.map { NSValue(point: CGPoint(x: $0.body.maxX, y: 0)) })
        // The shoulder only changes radius between the compact and open states; skip its paths when it holds still.
        if outlines.contains(where: { abs($0.shoulder - last.shoulder) > 0.01 }) {
            bake.add(left, "path", outlines.map { IslandOutlineGeometry.shoulderPath($0.shoulder, right: false) })
            bake.add(right, "path", outlines.map { IslandOutlineGeometry.shoulderPath($0.shoulder, right: true) })
        } else {
            left.removeAnimation(forKey: "path")
            right.removeAnimation(forKey: "path")
        }
    }

    func stop() {
        for l in [body, left, right] as [CALayer] { l.removeAllAnimations() }
    }
}

/// One transition's keyframes: evenly spaced samples over `duration`, all added in one transaction with the
/// same clock, so every layer of the island moves in lockstep.
struct Bake {
    let duration: CFTimeInterval
    let frameRate: CAFrameRateRange

    func add(_ layer: CALayer, _ keyPath: String, _ values: [Any], key: String? = nil) {
        guard values.count > 1 else { return }
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.duration = duration
        a.calculationMode = .linear
        a.isRemovedOnCompletion = true
        a.preferredFrameRateRange = frameRate
        layer.add(a, forKey: key ?? keyPath)
    }

    /// Holds a value until `time`, then lets the model value show: the frame-exact hand-over between hosts.
    func hold(_ layer: CALayer, _ keyPath: String, value: Any, until time: CFTimeInterval, key: String) {
        guard time > 0 else { layer.removeAnimation(forKey: key); return }
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = value
        a.toValue = value
        a.duration = time
        a.isRemovedOnCompletion = true
        layer.add(a, forKey: key)
    }
}
