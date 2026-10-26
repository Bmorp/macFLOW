import SwiftUI
import AppKit
import QuartzCore

// Looping decorations — the live dot, Claude's thinking dots, the waveform, the spinner, a scrolling title —
// drawn as Core Animation layers. A SwiftUI loop (`repeatForever`, `TimelineView(.animation)`) re-runs the
// view graph, lays out the hosting view and re-renders the island on the main thread every display frame,
// for as long as it lives — including while the island is closed, which is most of the day. A CA loop is
// handed to the system's render server once and costs Atoll nothing per frame. Each one also stops entirely
// while its presentation is kept built but out of sight (`islandShowing`).
//
// Offscreen renders (`RenderMode.snapshot`) can't draw platform views, so each piece keeps a still SwiftUI
// drawing for them.

/// A layer-only view that never takes clicks and keeps its loops running only while asked to.
class LoopLayerView: NSView {
    var running = false {
        didSet { if running != oldValue { applyRunning() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        CATransaction.commit()
        applyRunning()
    }

    /// Size and place sublayers for `bounds` (implicit animations are off).
    func layoutLayers() {}
    /// Add or remove the loops to match `running`. Must be idempotent.
    func applyRunning() {}

    static func loop(_ keyPath: String, values: [Any], duration: CFTimeInterval, offset: CFTimeInterval = 0) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.duration = duration
        a.repeatCount = .infinity
        a.calculationMode = .linear
        a.timeOffset = offset
        a.isRemovedOnCompletion = false
        return a
    }
}

// MARK: - Live dot

/// A dot that breathes while something is live. Still under Reduce Motion.
struct LiveDot: View {
    var color: Color
    var size: CGFloat = 6
    @Environment(\.islandShowing) private var showing

    var body: some View {
        Group {
            if RenderMode.snapshot || Access.reduceMotion {
                Circle().fill(color).frame(width: size, height: size)
            } else {
                // The halo grows to 2.4×: the view is drawn larger and laid out at the dot's size.
                let canvas = size * 2.6
                PulseRepresentable(color: NSColor(color), running: showing)
                    .frame(width: canvas, height: canvas)
                    .padding(-(canvas - size) / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PulseRepresentable: NSViewRepresentable {
    let color: NSColor
    let running: Bool
    func makeNSView(context: Context) -> PulseView { PulseView() }
    func updateNSView(_ v: PulseView, context: Context) {
        v.color = color
        v.running = running
    }
}

final class PulseView: LoopLayerView {
    private let dot = CALayer()
    private let halo = CALayer()
    var color: NSColor = .white {
        didSet {
            guard color != oldValue else { return }
            dot.backgroundColor = color.cgColor
            halo.backgroundColor = color.withAlphaComponent(color.alphaComponent * 0.5).cgColor
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        halo.opacity = 0
        layer?.addSublayer(halo)
        layer?.addSublayer(dot)
        dot.backgroundColor = color.cgColor
        halo.backgroundColor = color.withAlphaComponent(0.5).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutLayers() {
        let d = min(bounds.width, bounds.height) / 2.6
        let r = CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        for l in [dot, halo] {
            l.frame = r
            l.cornerRadius = d / 2
        }
    }

    override func applyRunning() {
        if running {
            guard halo.animation(forKey: "pulse") == nil else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 2.4
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.6
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            halo.add(group, forKey: "pulse")
        } else {
            halo.removeAnimation(forKey: "pulse")
        }
    }
}

// MARK: - Thinking dots

/// Thinking: three dots of different sizes that breathe in turn — scale only, no fade.
struct ThinkingDots: View {
    var size: CGFloat = 22
    var color: Color = BrainStyle.dots
    @Environment(\.islandShowing) private var showing

    /// Centre (unit, top-left origin), radius (fraction of half the width) and phase of each dot.
    static let dots: [(CGPoint, CGFloat, Double)] = [
        (CGPoint(x: 0.22, y: 0.62), 0.20, 0.0),
        (CGPoint(x: 0.62, y: 0.36), 0.30, 0.33),
        (CGPoint(x: 0.50, y: 0.82), 0.17, 0.66),
    ]

    var body: some View {
        Group {
            if RenderMode.snapshot || Access.reduceMotion {
                Canvas { g, s in
                    for (p, r, _) in Self.dots {
                        let radius = r * s.width / 2
                        let c = CGPoint(x: p.x * s.width, y: p.y * s.height)
                        g.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                               with: .color(color))
                    }
                }
            } else {
                ThinkingRepresentable(color: NSColor(color), running: showing)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityLabel("Thinking")
    }
}

private struct ThinkingRepresentable: NSViewRepresentable {
    let color: NSColor
    let running: Bool
    func makeNSView(context: Context) -> ThinkingView { ThinkingView() }
    func updateNSView(_ v: ThinkingView, context: Context) {
        v.color = color
        v.running = running
    }
}

final class ThinkingView: LoopLayerView {
    private let layers = ThinkingDots.dots.map { _ in CALayer() }
    var color: NSColor = .white {
        didSet { if color != oldValue { layers.forEach { $0.backgroundColor = color.cgColor } } }
    }

    /// One breath: 0.5 s, between 78 % and full size, sampled from the same sine the SwiftUI version drew.
    private static let period: CFTimeInterval = 1.2 / 2.4
    private static let breath: [NSNumber] = (0...24).map { i in
        let x = Double(i) / 24 * 2 * .pi
        return NSNumber(value: 0.78 + 0.22 * (0.5 + 0.5 * sin(x)))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for l in layers {
            l.backgroundColor = color.cgColor
            layer?.addSublayer(l)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutLayers() {
        let s = bounds.size
        for (l, (p, r, _)) in zip(layers, ThinkingDots.dots) {
            let d = r * s.width
            l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            l.cornerRadius = d / 2
            l.position = CGPoint(x: p.x * s.width, y: (1 - p.y) * s.height)   // layers are y-up
        }
    }

    override func applyRunning() {
        for (l, (_, _, phase)) in zip(layers, ThinkingDots.dots) {
            if running {
                guard l.animation(forKey: "breathe") == nil else { continue }
                // sin((t·2.4 − phase)·2π/1.2): each dot runs phase/2.4 s behind the first.
                let offset = (Self.period - (phase / 2.4).truncatingRemainder(dividingBy: Self.period))
                l.add(Self.loop("transform.scale", values: Self.breath, duration: Self.period, offset: offset), forKey: "breathe")
            } else {
                l.removeAnimation(forKey: "breathe")
            }
        }
    }
}

// MARK: - Waveform

/// Audio waveform bars. Static under Reduce Motion, and while not live or out of sight.
struct Waveform: View {
    var tint: Color
    var active: Bool
    var bars = 4
    var height: CGFloat = 14
    var barWidth: CGFloat = 3
    @Environment(\.islandShowing) private var showing

    static let restLevels: [Double] = [0.45, 0.8, 0.6, 0.9, 0.5]

    var body: some View {
        let spacing = barWidth * 0.8
        let width = CGFloat(bars) * barWidth + CGFloat(bars - 1) * spacing
        Group {
            if RenderMode.snapshot || Access.reduceMotion {
                Canvas { g, size in
                    for i in 0..<bars {
                        let h = max(barWidth, size.height * Self.restLevels[i % 5])
                        let rect = CGRect(x: CGFloat(i) * (barWidth + spacing), y: (size.height - h) / 2, width: barWidth, height: h)
                        g.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(tint))
                    }
                }
            } else {
                WaveformRepresentable(color: NSColor(tint), bars: bars, barWidth: barWidth, running: active && showing)
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WaveformRepresentable: NSViewRepresentable {
    let color: NSColor
    let bars: Int
    let barWidth: CGFloat
    let running: Bool
    func makeNSView(context: Context) -> WaveformView { WaveformView() }
    func updateNSView(_ v: WaveformView, context: Context) {
        v.configure(bars: bars, barWidth: barWidth, color: color)
        v.running = running
    }
}

final class WaveformView: LoopLayerView {
    private var barLayers: [CALayer] = []
    private var barWidth: CGFloat = 3
    private var color: NSColor = .white
    private var laidOutHeight: CGFloat = -1

    /// The loop: 12 s, every frequency a whole number of cycles in it, so it repeats without a seam.
    /// Close to the SwiftUI version's |sin(t·(2.1 + 0.6i) + φ) · cos(t·1.15 + 0.6φ)|.
    private static let loopDuration: CFTimeInterval = 12
    private static let samples = 240
    private static let cycles: [Double] = [4, 5, 6, 7, 9]

    func configure(bars: Int, barWidth: CGFloat, color: NSColor) {
        if bars != barLayers.count {
            barLayers.forEach { $0.removeFromSuperlayer() }
            barLayers = (0..<bars).map { _ in CALayer() }
            barLayers.forEach { layer?.addSublayer($0) }
            laidOutHeight = -1
            needsLayout = true
        }
        if barWidth != self.barWidth {
            self.barWidth = barWidth
            laidOutHeight = -1
            needsLayout = true
        }
        if color != self.color || barLayers.first?.backgroundColor == nil {
            self.color = color
            barLayers.forEach { $0.backgroundColor = color.cgColor }
        }
    }

    override func layoutLayers() {
        let spacing = barWidth * 0.8
        for (i, l) in barLayers.enumerated() {
            let h = max(barWidth, bounds.height * Waveform.restLevels[i % 5])
            l.bounds = CGRect(x: 0, y: 0, width: barWidth, height: h)
            l.position = CGPoint(x: CGFloat(i) * (barWidth + spacing) + barWidth / 2, y: bounds.midY)
            l.cornerRadius = barWidth / 2
        }
        if bounds.height != laidOutHeight {
            // Keyframes are in points: rebuild them for the new height.
            laidOutHeight = bounds.height
            barLayers.forEach { $0.removeAnimation(forKey: "level") }
        }
    }

    override func applyRunning() {
        let h = bounds.height
        guard h > 0 else { return }
        for (i, l) in barLayers.enumerated() {
            if running {
                guard l.animation(forKey: "level") == nil else { continue }
                l.add(Self.loop("bounds.size.height", values: Self.levels(bar: i, height: h, width: barWidth),
                                duration: Self.loopDuration), forKey: "level")
            } else {
                l.removeAnimation(forKey: "level")
            }
        }
    }

    private static func levels(bar i: Int, height: CGFloat, width: CGFloat) -> [NSNumber] {
        let phase = Double(i) * 1.9
        let w = 2 * Double.pi / loopDuration
        let fast = cycles[i % cycles.count] * w
        let slow = 2 * w
        return (0...samples).map { k in
            let t = Double(k) / Double(samples) * loopDuration
            let level = 0.3 + 0.7 * abs(sin(t * fast + phase) * cos(t * slow + phase * 0.6))
            return NSNumber(value: Double(max(width, height * level)))
        }
    }
}

// MARK: - Spinner

/// The indeterminate quarter-arc of a progress ring, turning once a second.
struct SpinnerArc: View {
    var tint: Color
    var lineWidth: CGFloat
    @Environment(\.islandShowing) private var showing

    var body: some View {
        if RenderMode.snapshot || Access.reduceMotion {
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        } else {
            SpinnerRepresentable(color: NSColor(tint), lineWidth: lineWidth, running: showing)
                .allowsHitTesting(false)
        }
    }
}

private struct SpinnerRepresentable: NSViewRepresentable {
    let color: NSColor
    let lineWidth: CGFloat
    let running: Bool
    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }
    func updateNSView(_ v: SpinnerView, context: Context) {
        v.arc.strokeColor = color.cgColor
        if v.arc.lineWidth != lineWidth {
            v.arc.lineWidth = lineWidth
            v.needsLayout = true
        }
        v.running = running
    }
}

final class SpinnerView: LoopLayerView {
    let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeEnd = 0.25
        layer?.addSublayer(arc)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutLayers() {
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds, transform: nil)
    }

    override func applyRunning() {
        if running {
            guard arc.animation(forKey: "spin") == nil else { return }
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -2 * Double.pi
            a.duration = 1
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            arc.add(a, forKey: "spin")
        } else {
            arc.removeAnimation(forKey: "spin")
        }
    }
}

// MARK: - Marquee strip

/// A pre-rendered line of text (drawn twice, a gap apart) that Core Animation scrolls: hold, then slide
/// exactly one copy's width so the second copy lands where the first started, and repeat.
struct MarqueeStrip: NSViewRepresentable {
    let image: CGImage?
    let scale: CGFloat
    /// One copy plus the gap, in points.
    let distance: CGFloat
    let speed: Double
    let pause: Double
    let running: Bool

    func makeNSView(context: Context) -> MarqueeStripView { MarqueeStripView() }
    func updateNSView(_ v: MarqueeStripView, context: Context) {
        v.update(image: image, scale: scale, distance: distance, speed: speed, pause: pause)
        v.running = running
    }
}

final class MarqueeStripView: LoopLayerView {
    private let strip = CALayer()
    private let fade = CAGradientLayer()
    private var image: CGImage?
    private var distance: CGFloat = 0
    private var speed: Double = 24
    private var pause: Double = 2.2

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        strip.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(strip)
        // Fade the trailing tenth, as the SwiftUI version's mask did.
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.9, 1]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = fade
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(image: CGImage?, scale: CGFloat, distance: CGFloat, speed: Double, pause: Double) {
        guard image !== self.image || distance != self.distance else { return }
        self.image = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.contents = image
        strip.contentsScale = scale
        if let image {
            strip.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        }
        CATransaction.commit()
        self.distance = distance
        self.speed = speed
        self.pause = pause
        strip.removeAnimation(forKey: "scroll")
        needsLayout = true
    }

    override func layoutLayers() {
        layer?.mask?.frame = bounds
        strip.position = CGPoint(x: 0, y: bounds.midY)
    }

    override func applyRunning() {
        if running, distance > 0, image != nil {
            guard strip.animation(forKey: "scroll") == nil else { return }
            let travel = Double(distance) / speed
            let total = pause + travel
            let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
            a.values = [0, 0, -distance]
            a.keyTimes = [0, NSNumber(value: pause / total), 1]
            a.duration = total
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            strip.add(a, forKey: "scroll")
        } else {
            strip.removeAnimation(forKey: "scroll")
        }
    }
}
