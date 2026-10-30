import SwiftUI

extension View {
    /// Shows this view through Prism's fluted glass: vertical lens strips that bend, light and (at their edges) split
    /// what's behind them. For hero moments only, and for pictures and light (a cover, a backdrop, a glow): like real
    /// reeded glass it scrambles fine detail, so put text above it, not under it. The effect is static — it renders
    /// when the view changes, not per frame — so a surface that morphs (the island) costs nothing while it moves.
    ///
    /// Falls back on its own: Reduce Transparency shades the strips over the view without looking through it, Increase
    /// Contrast keeps what's behind the glass legible, a hot Mac or a missing shader library draws the view as it is.
    func prism(_ style: PrismStyle, active: Bool = true) -> some View {
        modifier(PrismModifier(style: style, active: active))
    }
}

private struct PrismModifier: ViewModifier {
    let style: PrismStyle
    let active: Bool
    @ObservedObject private var conditions = PrismConditions.shared

    @ViewBuilder func body(content: Content) -> some View {
        if let lib = PrismLibrary.shared?.effects {
            let env = conditions.current
            let on = active && env.tier > .flat
            let s = env.increaseContrast ? PrismEffect.legible(style) : style
            // Both effects stay in the tree and are switched on or off, so a change of conditions never rebuilds
            // the content underneath.
            content
                .layerEffect(PrismEffect.flutes(lib, s, dispersion: env.dispersion), maxSampleOffset: PrismEffect.maxOffset(s),
                             isEnabled: on && env.samplesBehind)
                .colorEffect(PrismEffect.solid(lib, s), isEnabled: on && !env.samplesBehind)
        } else {
            content
        }
    }
}

/// The shaders behind `View.prism`, with their arguments in one place (the modifier, the prewarm and the benchmark
/// all build them here).
enum PrismEffect {
    static func flutes(_ lib: ShaderLibrary, _ s: PrismStyle, dispersion: Bool = true, tint: Color = .white) -> Shader {
        lib.prismFlutes(.boundingRect, .float(s.pitch), .float(s.lens), .float(s.magnify), .float(s.depth),
                        .float(dispersion ? s.disperse : 0), .float(s.specular), .float(s.sparks),
                        .float(Float(s.seed % 65536)), .color(tint))
    }

    static func solid(_ lib: ShaderLibrary, _ s: PrismStyle, tint: Color = .white) -> Shader {
        lib.prismSolid(.boundingRect, .float(s.pitch), .float(s.lens), .float(s.specular), .color(tint))
    }

    /// How far a strip reaches for what it shows: half its magnified width plus the shift along its tilt.
    static func maxOffset(_ s: PrismStyle) -> CGSize {
        CGSize(width: ceil(s.pitch * (abs(s.magnify) * 0.5 + 0.5) + s.depth + 1), height: 0)
    }

    /// Increase Contrast: the same strips, but what's behind them stays readable (no magnifying, a shallow shift, no
    /// colour fringes).
    static func legible(_ s: PrismStyle) -> PrismStyle {
        var l = s
        l.magnify = 1
        l.depth = s.depth * 0.4
        l.disperse = 0
        return l
    }
}

/// Draws every Prism effect once, invisibly, so macOS 14 compiles them before the first hero moment needs one.
/// Put it inside an existing prewarm (it's a few points of nothing).
struct PrismWarmup: View {
    var body: some View {
        if let lib = PrismLibrary.shared?.effects {
            // One draw per function compiles it; the styles differ only in arguments.
            ZStack {
                Color.white.frame(width: 8, height: 8)
                    .layerEffect(PrismEffect.flutes(lib, .island), maxSampleOffset: PrismEffect.maxOffset(.island))
                Color.white.frame(width: 8, height: 8)
                    .colorEffect(PrismEffect.solid(lib, .island))
            }
            .opacity(0.001)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
