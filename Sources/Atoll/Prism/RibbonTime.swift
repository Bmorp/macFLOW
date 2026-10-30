import SwiftUI
import AppKit

/// The time as Ribbon numerals: SF Pro's figures cut into vertical glass strips that catch a cool light from above
/// and bend the wallpaper behind them. When a minute turns, the changing digits flow into the next ones strip by
/// strip. StandBy's Prism face, laid out exactly where the other faces put the time.
struct RibbonTime: View {
    let hour: String
    let minute: String
    let size: CGSize
    /// The wallpaper, blurred (nil on black or at night).
    let frost: CGImage?
    var night = false
    /// Tints the light (white: steel to white).
    var accent: Color = .white
    @ObservedObject private var conditions = PrismConditions.shared

    /// Whether ribbons can draw here at all; otherwise the caller shows another face.
    static var available: Bool { PrismRenderer.shared != nil }

    var body: some View {
        RibbonSurface(scene: RibbonScene(
            lead: hour, trail: minute, fontSize: size.height * ClockLayout.timeSize, canvas: size,
            layout: CGRect(origin: .zero, size: size), style: .standBy, tint: RibbonTint.of(accent),
            night: night, frost: night ? nil : frost, env: conditions.current), maxFrameRate: 120)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
    }
}

/// Ribbon numerals for a short count ("24:59") at a given size, for the island's expanded timer page: drawn over
/// black, 60 Hz at most. Sizes itself to the figures.
struct RibbonCount: View {
    let lead: String
    let trail: String
    let fontSize: CGFloat
    @ObservedObject private var conditions = PrismConditions.shared

    var body: some View {
        let box = Self.size(lead: lead, trail: trail, fontSize: fontSize)
        var style = PrismStyle.island
        // Fine enough to read as strips at this size, never under three device pixels.
        style.pitch = max(1.5, fontSize / 24)
        style.depth = 0
        // TimeGlyphs puts the cap height's middle at 38.5 % of the rect it's given; centre it in this frame.
        let layout = CGRect(x: 0, y: box.height / 2 - box.height * ClockLayout.timeY, width: box.width, height: box.height)
        return RibbonSurface(scene: RibbonScene(lead: lead, trail: trail, fontSize: fontSize, canvas: box, layout: layout,
                                                style: style, env: conditions.current), maxFrameRate: 60)
            .frame(width: box.width, height: box.height)
            .accessibilityElement()
            .accessibilityLabel("\(lead):\(trail)")
    }

    /// The figures' width (tabular, so it doesn't change as they count) and the cap height, with a strip of margin.
    static func size(lead: String, trail: String, fontSize: CGFloat) -> CGSize {
        let f = TimeGlyphs.font(fontSize), small = TimeGlyphs.font(fontSize * 0.72)
        let w = TimeGlyphs.outline(lead, f).1 + TimeGlyphs.outline(":", small).1 + TimeGlyphs.outline(trail, f).1 + fontSize * 0.04
        return CGSize(width: ceil(w + fontSize * 0.12), height: ceil(CTFontGetCapHeight(f) + fontSize * 0.2))
    }
}

enum RibbonTint {
    /// White leaves the light alone; any other accent tints it by half.
    static func of(_ color: Color) -> SIMD4<Float> {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return SIMD4(1, 1, 1, 0) }
        let white = c.saturationComponent < 0.08
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), white ? 0 : 0.5)
    }
}

/// A ribbon stage in SwiftUI. Live, it's a `CAMetalLayer` driven off the main thread; in offscreen renders (which
/// can't draw Metal layers) it's the same scene drawn once on the GPU and shown as a picture.
private struct RibbonSurface: View {
    let scene: RibbonScene
    let maxFrameRate: Float

    var body: some View {
        if RenderMode.snapshot {
            RibbonStill(scene: scene)
        } else {
            RibbonStageHost(scene: scene, maxFrameRate: maxFrameRate)
        }
    }
}

private struct RibbonStill: View {
    let scene: RibbonScene
    @Environment(\.displayScale) private var scale

    var body: some View {
        if let image = RibbonStillCache.image(scene, scale: scale) {
            Image(decorative: image, scale: scale)
        }
    }
}

@MainActor
private enum RibbonStillCache {
    private static var last: (RibbonScene, CGFloat, CGImage)?

    static func image(_ scene: RibbonScene, scale: CGFloat) -> CGImage? {
        if let last, last.0 == scene, last.1 == scale { return last.2 }
        guard let img = PrismRenderer.shared?.still(scene, scale: scale) else { return nil }
        last = (scene, scale, img)
        return img
    }
}

private struct RibbonStageHost: NSViewRepresentable {
    let scene: RibbonScene
    let maxFrameRate: Float

    func makeNSView(context: Context) -> PrismStageView {
        PrismStageView(maxFrameRate: maxFrameRate)
    }

    func updateNSView(_ v: PrismStageView, context: Context) {
        v.show(scene)
    }

    static func dismantleNSView(_ v: PrismStageView, coordinator: ()) {
        v.stage?.suspend()
    }
}

/// Hosts a stage's Metal layer. Hands the scene to the render thread when it changes; nothing else on the main thread.
final class PrismStageView: NSView {
    let stage: PrismStage?
    private var scene: RibbonScene?

    init(maxFrameRate: Float) {
        stage = PrismRenderer.shared.map { PrismStage(renderer: $0, maxFrameRate: maxFrameRate) }
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { stage?.layer ?? CALayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func show(_ next: RibbonScene) {
        guard next != scene else { return }
        scene = next
        guard window != nil else { return }
        stage?.show(next)
    }

    override func layout() {
        super.layout()
        resizeDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeDrawable()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stage?.suspend()
        } else {
            resizeDrawable()
            if let scene { stage?.show(scene) }
        }
    }

    private func resizeDrawable() {
        guard let stage, let window else { return }
        let scale = window.backingScaleFactor
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0, stage.layer.drawableSize != size || stage.layer.contentsScale != scale else { return }
        stage.layer.contentsScale = scale
        stage.layer.drawableSize = size
        // A new size needs a new frame even if nothing else changed.
        if let scene { stage.show(scene) }
    }
}
