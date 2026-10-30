import CoreGraphics
import QuartzCore

/// Every value of the island that moves, at one moment. The engine springs all of them together, so the
/// silhouette, its rim, its light and the content inside can't drift apart.
struct IslandFrame: Equatable {
    var width: Double
    var height: Double
    /// Concave curve where the island grows out of the top edge (before clamping).
    var shoulder: Double
    /// Bottom corner radius, as `IslandShape` takes it (before clamping).
    var corner: Double
    /// The content's sideways offset when moving between places (DESIGN.md › 5.2: the new place slides in).
    var slide: Double
    /// Rim strength, 0…1.
    var rim: Double
    /// Content light, 0…1 (on while open).
    var light: Double

    static let channels = 7

    subscript(i: Int) -> Double {
        get {
            switch i {
            case 0: width
            case 1: height
            case 2: shoulder
            case 3: corner
            case 4: slide
            case 5: rim
            default: light
            }
        }
        set {
            switch i {
            case 0: width = newValue
            case 1: height = newValue
            case 2: shoulder = newValue
            case 3: corner = newValue
            case 4: slide = newValue
            case 5: rim = newValue
            default: light = newValue
            }
        }
    }

    /// How close counts as settled, per channel: a twentieth of a point, a thousandth of a fraction.
    static let epsilon: [Double] = [0.05, 0.05, 0.05, 0.05, 0.05, 0.002, 0.002]

    static let zero = IslandFrame(width: 0, height: 0, shoulder: 0, corner: 0, slide: 0, rim: 0, light: 0)

    var size: CGSize { CGSize(width: width, height: height) }
}

/// The silhouette for one frame, resolved exactly as `IslandShape.build` resolves it (same clamps), in the panel's
/// top-down coordinates with the island hanging from y = 0 around `centerX`.
struct IslandOutlineGeometry: Equatable {
    /// The body: the island minus its shoulders. Bottom corners only.
    let body: CGRect
    /// Core Animation's continuous-corner radius that best fits `IslandShape`'s corner curve
    /// (its corner spans 1.25 × the radius with a 0.32 handle; CA's continuous corner spans ≈ 1.53 × its radius).
    /// Fitted by least worst-case distance: 1.04 × the shape's radius, within 0.55 pt at the 30-pt open corner.
    let cornerRadius: CGFloat
    /// Clamped shoulder radius.
    let shoulder: CGFloat

    static let cornerFit: CGFloat = 1.04

    init(_ f: IslandFrame, centerX: CGFloat) {
        let w = CGFloat(max(0, f.width)), h = CGFloat(max(0, f.height))
        let s = max(0, min(CGFloat(f.shoulder), w / 4, h / 2))
        let reach = max(0, min(CGFloat(f.corner) * 1.25, h - s, (w - 2 * s) / 2))
        shoulder = s
        body = CGRect(x: centerX - w / 2 + s, y: 0, width: max(0, w - 2 * s), height: h)
        cornerRadius = reach / 1.25 * Self.cornerFit
    }

    /// The concave fillet joining the top edge to the body's left side, in coordinates whose origin is the body's
    /// top-left corner (mirror x for the right). It runs 1 pt into the body so the two never show a hairline seam.
    static func shoulderPath(_ s: CGFloat, right: Bool) -> CGPath {
        let m: CGFloat = right ? -1 : 1
        let p = CGMutablePath()
        guard s > 0.01 else { return p }
        p.move(to: CGPoint(x: -s * m, y: 0))
        p.addCurve(to: CGPoint(x: 0, y: s), control1: CGPoint(x: -s * 0.38 * m, y: 0), control2: CGPoint(x: 0, y: s * 0.38))
        p.addLine(to: CGPoint(x: 1 * m, y: s))
        p.addLine(to: CGPoint(x: 1 * m, y: 0))
        p.closeSubpath()
        return p
    }
}

enum IslandGeometry {
    /// How much of its own size the content shows inside a shape of `live` size: the smaller of the two ratios,
    /// never above 1 (DESIGN.md › 6.3.1). The same rule `IslandPresentation` applies in SwiftUI.
    static func zoom(live: CGSize, target: CGSize) -> CGFloat {
        IslandPresentation.zoom(live: live, target: target)
    }

    /// The content light's two layers (ContentLight's geometry), in panel coordinates.
    static func light(_ f: IslandFrame, centerX: CGFloat) -> (radial: CGRect, rising: CGRect) {
        let w = CGFloat(max(0, f.width)), h = CGFloat(max(0, f.height))
        let x0 = centerX - w / 2
        let d = max(w, h) * 1.24
        let c = CGPoint(x: x0 + w * 0.12, y: h * 1.05)
        return (CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d), CGRect(x: x0, y: h / 2, width: w, height: h / 2))
    }

    /// Scale `s` about `pivot` then shift `dx`, for a layer whose own geometry AppKit owns: `pivot` is given in the
    /// layer's own coordinates and the anchor is read from the layer, so the model transform can stay identity.
    static func scale(_ s: CGFloat, about pivot: CGPoint, anchor: CGPoint, dx: CGFloat) -> CATransform3D {
        // Transforms apply about the anchor: move the pivot onto it, scale, move back, then slide.
        let d = CGPoint(x: pivot.x - anchor.x, y: pivot.y - anchor.y)
        var t = CATransform3DMakeTranslation(d.x + dx, d.y, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -d.x, -d.y, 0)
    }
}
