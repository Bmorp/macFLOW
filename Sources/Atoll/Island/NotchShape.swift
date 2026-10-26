import SwiftUI

/// Everything that describes the island's silhouette at one moment.
struct IslandSpec: Equatable {
    var size: CGSize
    /// Concave curve where the island grows out of the top edge.
    var shoulder: CGFloat
    /// Bottom corner radius (drawn as a continuous corner).
    var corner: CGFloat
}

/// The island silhouette: the top edge runs wider than the body and curves down into it,
/// so the island reads as part of the bezel rather than a box beneath it. Both radii animate,
/// and the frame size animates with them, so every state morphs as one shape.
struct IslandShape: Shape {
    var shoulder: CGFloat
    var corner: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, corner) }
        set {
            shoulder = newValue.first
            corner = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Self.build(in: rect, shoulder: shoulder, corner: corner, closed: true)
    }

    /// The outline without the top edge and shoulders — where the rim light lives.
    static func outline(in rect: CGRect, shoulder: CGFloat, corner: CGFloat) -> Path {
        build(in: rect, shoulder: shoulder, corner: corner, closed: false)
    }

    private static func build(in rect: CGRect, shoulder: CGFloat, corner: CGFloat, closed: Bool) -> Path {
        let w = rect.width, h = rect.height
        let s = max(0, min(shoulder, w / 4, h / 2))
        // Continuous corner: the curve starts earlier than a circular arc and eases in.
        let reach = max(0, min(corner * 1.25, h - s, (w - 2 * s) / 2))
        let k: CGFloat = 0.32
        let x0 = rect.minX, y0 = rect.minY
        var p = Path()
        if closed {
            p.move(to: CGPoint(x: x0, y: y0))
            p.addCurve(to: CGPoint(x: x0 + s, y: y0 + s),
                       control1: CGPoint(x: x0 + s * 0.62, y: y0),
                       control2: CGPoint(x: x0 + s, y: y0 + s * 0.38))
        } else {
            p.move(to: CGPoint(x: x0 + s, y: y0 + s))
        }
        p.addLine(to: CGPoint(x: x0 + s, y: y0 + h - reach))
        p.addCurve(to: CGPoint(x: x0 + s + reach, y: y0 + h),
                   control1: CGPoint(x: x0 + s, y: y0 + h - reach * k),
                   control2: CGPoint(x: x0 + s + reach * k, y: y0 + h))
        p.addLine(to: CGPoint(x: x0 + w - s - reach, y: y0 + h))
        p.addCurve(to: CGPoint(x: x0 + w - s, y: y0 + h - reach),
                   control1: CGPoint(x: x0 + w - s - reach * k, y: y0 + h),
                   control2: CGPoint(x: x0 + w - s, y: y0 + h - reach * k))
        p.addLine(to: CGPoint(x: x0 + w - s, y: y0 + s))
        if closed {
            p.addCurve(to: CGPoint(x: x0 + w, y: y0),
                       control1: CGPoint(x: x0 + w - s, y: y0 + s * 0.38),
                       control2: CGPoint(x: x0 + w - s * 0.62, y: y0))
            p.closeSubpath()
        }
        return p
    }
}

/// Kept for call sites that only need the silhouette.
typealias NotchShape = IslandShape

/// The rim outline as a shape, so it can be stroked and trimmed with the same animation.
struct IslandOutline: Shape {
    var shoulder: CGFloat
    var corner: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, corner) }
        set { shoulder = newValue.first; corner = newValue.second }
    }
    func path(in rect: CGRect) -> Path { IslandShape.outline(in: rect, shoulder: shoulder, corner: corner) }
}

/// A short highlight that travels once around the rim as the island opens.
struct RimSweep: Shape {
    var shoulder: CGFloat
    var corner: CGFloat
    var progress: CGFloat
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(progress, AnimatablePair(shoulder, corner)) }
        set { progress = newValue.first; shoulder = newValue.second.first; corner = newValue.second.second }
    }
    func path(in rect: CGRect) -> Path {
        let span: CGFloat = 0.22
        let to = min(1, progress * (1 + span))
        let from = max(0, to - span)
        guard to > from else { return Path() }
        return IslandShape.outline(in: rect, shoulder: shoulder, corner: corner).trimmedPath(from: from, to: to)
    }
}

/// How the rim light is coloured.
enum RimStyle: Equatable {
    case tint(Color)
    /// The multicolour glow used for search.
    case spectrum
}

/// A neutral hairline along the island's lower edge (colour lives inside, as ContentLight).
/// It fades out toward the top so the island still melts into the bezel.
///
/// Built from stacked strokes and a vertical gradient — no blur, no mask — so it costs almost nothing
/// per frame while the shape animates.
struct RimLight: View {
    let spec: IslandSpec
    let notchHeight: CGFloat
    let style: RimStyle
    let strength: Double
    let sweep: CGFloat

    var body: some View {
        let outline = IslandOutline(shoulder: spec.shoulder, corner: spec.corner)
        let h = max(spec.size.height, 1)
        let fadeStart = min(0.9, notchHeight * 0.5 / h)
        let fadeEnd = min(1, max(fadeStart + 0.02, (notchHeight + 16) / h))
        // A single neutral hairline — just enough edge to read on a dark wallpaper — faded toward the top by an image
        // mask (a gradient stroke was rasterised on the CPU every frame of every open).
        outline.stroke(Color.white.opacity(Access.increaseContrast ? 0.32 : 0.13), lineWidth: 1)
            .frame(width: spec.size.width, height: spec.size.height)
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: h * fadeStart)
                    Image(nsImage: Glow.rising).resizable().frame(height: max(1, h * (fadeEnd - fadeStart)))
                    Color.white
                }
            }
        .opacity(strength)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }


    /// Transparent near the top, full colour from just below the notch down.
    private func shading(_ start: CGFloat, _ end: CGFloat, _ alpha: Double) -> LinearGradient {
        let base: [Color] = [.white, .white]
        return LinearGradient(stops: [.init(color: base[0].opacity(0), location: 0),
                                      .init(color: base[0].opacity(0), location: start),
                                      .init(color: base[0].opacity(alpha), location: end),
                                      .init(color: base[1].opacity(alpha), location: 1)],
                              startPoint: .top, endPoint: .bottom)
    }
}
