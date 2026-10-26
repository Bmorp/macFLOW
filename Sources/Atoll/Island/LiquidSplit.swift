import SwiftUI

/// The minimal-presentation bubble, drawn as a metaball so it pulls away from the island
/// like liquid when a second activity starts, and melts back in when it ends.
///
/// Technique: shapes are blurred, then alpha-thresholded. Where two blurred shapes overlap,
/// their combined alpha crosses the threshold and a smooth bridge appears.
struct LiquidSplit: View, Animatable {
    /// Width of the compact island including its flares.
    var islandWidth: CGFloat
    var height: CGFloat
    var diameter: CGFloat
    /// Offset of the bubble's resting centre from the island centre.
    var restOffset: CGFloat
    /// 0 = hidden inside the island, 1 = fully detached.
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            guard progress > 0.001 else { return }
            let midX = size.width / 2
            let bodyRight = midX + islandWidth / 2 - IslandModel.compactFlare
            let startX = bodyRight - diameter / 2 - 2
            let restX = midX + restOffset
            let cx = startX + (restX - startX) * progress
            let d = diameter * (0.55 + 0.45 * min(1, progress * 1.4))

            ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
            ctx.addFilter(.blur(radius: Access.reduceMotion ? 0.5 : 5))
            ctx.drawLayer { layer in
                // The island's trailing end, so the bubble has something to pull away from.
                layer.fill(Path(roundedRect: CGRect(x: bodyRight - 34, y: -24, width: 34, height: height + 22),
                                cornerRadius: 10), with: .color(.black))
                // The bubble hangs from the top edge, like a small notch.
                layer.fill(Path(roundedRect: CGRect(x: cx - d / 2, y: -24, width: d, height: (height - (diameter - d) / 2) + 24),
                                cornerRadius: d / 2), with: .color(.black))
                // A sliver along the screen edge gives the bubble the hardware notch's soft fillets.
                layer.fill(Path(CGRect(x: cx - d / 2 - 5, y: -24, width: d + 10, height: 26)), with: .color(.black))
            }
        }
        .allowsHitTesting(false)
        .opacity(Access.reduceMotion ? Double(progress) : 1)
    }
}
