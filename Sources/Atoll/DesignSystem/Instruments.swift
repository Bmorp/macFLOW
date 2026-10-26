import Combine
import SwiftUI

// Atoll's design kit, "Instruments" (DESIGN.md › Instruments).
//
// The island is a black instrument, not a notification. Each activity is built around the one thing
// that matters about it — the artwork, the time left, the countdown — set large, with everything else
// quiet around it. There are no icon tiles and no coloured rims: colour comes only from content
// (album art, a running clock), and it lives *inside* the black as light, not on the edge as an outline.

extension DS {

    /// Ink: four levels of white on black. Hierarchy comes from these, not from colour.
    enum Ink {
        static let primary = Color.white
        static var secondary: Color { Color.white.opacity(Access.increaseContrast ? 0.78 : 0.58) }
        static var tertiary: Color { Color.white.opacity(Access.increaseContrast ? 0.6 : 0.36) }
        static let hairline = Color.white.opacity(0.09)
        static let well = Color.white.opacity(0.07)
        static let wellHover = Color.white.opacity(0.13)
    }

    /// Type: SF Pro for words, SF Pro Rounded for the numbers an instrument is read by.
    enum Kit {
        /// The figure an instrument is built around: a timer, a countdown, a percentage.
        static func figure(_ size: CGFloat = 40) -> Font {
            .system(size: size, weight: size >= 34 ? .light : .regular, design: .rounded).monospacedDigit()
        }
        static let title = Font.system(size: 15, weight: .semibold)
        static let titleLarge = Font.system(size: 17, weight: .semibold)
        static let meta = Font.system(size: 12, weight: .medium).monospacedDigit()
        /// Small capitals above a title: what this is, where it's from.
        static let eyebrow = Font.system(size: 10, weight: .semibold)
        static let eyebrowTracking: CGFloat = 0.9
        static let unit = Font.system(size: 13, weight: .medium, design: .rounded)
        /// A card's or row's own line: what it is.
        static let body = Font.system(size: 13, weight: .semibold)
        /// The line under it: the why, the when.
        static let caption = Font.system(size: 11, weight: .medium).monospacedDigit()
    }
}

// MARK: - Layout

/// Every open instrument: the notch's height kept clear, then the instrument's own composition with the
/// island's insets. Unlike the old row, it imposes nothing about what goes where.
struct Instrument<Content: View>: View {
    let notch: CGSize
    let width: CGFloat
    var height: CGFloat = DS.Size.rowHeight
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            content
                .padding(.horizontal, IslandModel.expandedFlare + DS.Island.rowLeading + 2)
                .padding(.top, 2)
                .padding(.bottom, 14)
                .frame(height: height)
        }
        .frame(width: width, alignment: .top)
    }
}

// MARK: - Light

/// Content light: colour from what's on show, glowing up from inside the black like a lit display.
/// Two gradients — no blur — so it costs nothing while the island moves.
struct ContentLight: View {
    var color: Color
    /// Where the light comes from, in unit coordinates.
    var origin: UnitPoint = .init(x: 0.12, y: 1.05)
    var strength: Double = 1

    var body: some View {
        GeometryReader { geo in
            // Pre-rendered light (Glow): a live SwiftUI gradient here was re-rasterised on the CPU every frame of every open.
            let d = max(geo.size.width, geo.size.height) * 1.24
            ZStack(alignment: .bottom) {
                Image.glow(Glow.radial)
                    .foregroundStyle(color.opacity(0.26 * strength))
                    .frame(width: d, height: d)
                    .position(x: geo.size.width * origin.x, y: geo.size.height * origin.y)
                Image.glow(Glow.rising)
                    .foregroundStyle(color.opacity(0.05 * strength))
                    .frame(width: geo.size.width, height: geo.size.height / 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Type pieces

/// SMALL CAPITALS that say what an instrument is, with an optional live dot.
struct Eyebrow: View {
    let text: String
    var dot: Color? = nil
    var tint: Color = DS.Ink.tertiary

    var body: some View {
        HStack(spacing: 6) {
            if let dot { LiveDot(color: dot) }
            Text(text.uppercased())
                .font(DS.Kit.eyebrow)
                .tracking(DS.Kit.eyebrowTracking)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

/// The figure an instrument is read by, with an optional small unit after it ("5 min", "62 %").
struct Figure: View {
    let value: String
    var unit: String? = nil
    var size: CGFloat = 40
    var tint: Color = DS.Ink.primary
    var countsDown = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(DS.Kit.figure(size))
                .tracking(size >= 34 ? -0.5 : 0)
                .foregroundStyle(tint)
                .contentTransition(.numericText(countsDown: countsDown))
                .animation(.snappy, value: value)
            if let unit {
                Text(unit).font(DS.Kit.unit).foregroundStyle(DS.Ink.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

// LiveDot lives in LayerMotion.swift (a Core Animation loop).

// MARK: - Progress

/// A hairline of progress across the instrument. Optionally scrubbable, thickening under the pointer.
struct ProgressLine: View {
    var fraction: Double?
    var tint: Color = .white
    var onSeek: ((Double) -> Void)? = nil
    @State private var drag: Double?
    @State private var hover = false

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let f = min(max(drag ?? fraction ?? 0, 0), 1)
            let h: CGFloat = onSeek != nil && (hover || drag != nil) ? 6 : 3
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Ink.well)
                Capsule().fill(tint).frame(width: max(h, w * f))
                    .animation(drag == nil ? .smooth(duration: 0.4) : nil, value: f)
            }
            .frame(height: h)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in if onSeek != nil { drag = min(max(0, g.location.x / w), 1) } }
                .onEnded { _ in if let d = drag { onSeek?(d) }; drag = nil },
                     including: onSeek == nil ? .subviews : .all)
            .onHover { h in withAnimation(Motion.hover) { hover = h } }
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

/// A thin arc around a control: the instrument's dial.
struct Dial<Label: View>: View {
    var fraction: Double
    var tint: Color
    var diameter: CGFloat = 40
    var lineWidth: CGFloat = 2.5
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle().stroke(DS.Ink.well, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.002, min(fraction, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: fraction)
            label
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Controls

/// A control with no chrome until you point at it: just the glyph, then a soft well on hover.
struct Ghost: View {
    let symbol: String
    let label: String
    var size: CGFloat = 15
    var weight: Font.Weight = .semibold
    var tint: Color = DS.Ink.primary
    var hit: CGFloat = 34
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: hit, height: hit)
                .background(Circle().fill(hover ? DS.Ink.well : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The one action an instrument exists for: a white capsule with black type. Never more than one per instrument.
struct Pill: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 15)
            .frame(height: 30)
            .background(Capsule().fill(Color.white.opacity(hover ? 1 : 0.92)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityLabel(title)
    }
}

// MARK: - Immersive music

/// The album's own colours as a living field behind the player, the way Apple Music's Now Playing feels.
/// It's the cover averaged to a few pixels and stretched with smooth interpolation (no blur), drifting slowly
/// while music plays. The top stays black so the island still grows out of the bezel; pausing dims it.
struct ArtField: View {
    @ObservedObject private var media = NowPlayingModel.shared
    @ObservedObject private var light = AmbientLight.shared
    @Environment(\.islandShowing) private var showing
    /// How far down the island the black lasts before the colour comes in (unit height).
    var clearTop: CGFloat = 0.12
    var strength: Double = 1
    /// With nothing playing, the moment's own light (morning, midday, focus, evening, night) instead of black.
    var ambient = false

    var body: some View {
        if ambient, ProcessInfo.processInfo.environment["ATOLL_NO_AMBIENT"] == nil, !(media.palette != nil && media.mode == .track) {
            let image = light.image
            let live = showing && !Access.reduceMotion && !RenderMode.snapshot
            Group {
                if RenderMode.snapshot {
                    Image(nsImage: image).resizable().interpolation(.high).scaleEffect(1.4)
                        .opacity(0.5 * strength)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.55), location: clearTop + 0.18),
                                                     .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
                } else {
                    DriftingField(image: image, moving: live, opacity: 0.5 * strength, clearTop: clearTop)
                }
            }
            .overlay(Image.glow(Glow.fadeRight).foregroundStyle(Color.black.opacity(0.32)).scaleEffect(x: -1, y: 1))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        } else if let palette = media.palette, media.mode == .track {
            let live = media.isPlaying && showing && !Access.reduceMotion && !RenderMode.snapshot
            let opacity = (media.isPlaying ? 0.78 : 0.4) * strength
            Group {
                if RenderMode.snapshot {
                    Image(nsImage: palette).resizable().interpolation(.high).scaleEffect(1.4)
                        .saturation(1.1)
                        .opacity(opacity)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                     .init(color: .black.opacity(0.55), location: clearTop + 0.18),
                                                     .init(color: .black, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                } else {
                    // A platform view: SwiftUI's mask and opacity don't reach its layers, so it fades itself.
                    DriftingField(image: palette, moving: live, opacity: opacity, clearTop: clearTop)
                }
            }
            // Keep type legible: a soft shade over the field, darker on the right where controls and apps sit.
            .overlay(Image.glow(Glow.fadeRight).foregroundStyle(Color.black.opacity(0.38)).scaleEffect(x: -1, y: 1))
            .animation(.easeInOut(duration: 0.6), value: media.isPlaying)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.identity)
        }
    }
}

/// The colour field as a Core Animation layer: its slow drift runs in the system's render server,
/// so a song playing with the island open costs Atoll nothing per frame.
private struct DriftingField: NSViewRepresentable {
    let image: NSImage
    let moving: Bool
    let opacity: Double
    let clearTop: CGFloat

    func makeNSView(context: Context) -> FieldView { FieldView() }

    func updateNSView(_ view: FieldView, context: Context) {
        view.set(image: image)
        view.setMoving(moving)
        view.setFade(opacity: Float(opacity), clearTop: clearTop)
    }

    final class FieldView: NSView {
        private let field = CALayer()
        private var current: NSImage?
        /// Black at the top (so the island still grows out of the bezel), colour toward the bottom.
        private let vertical = CAGradientLayer()
        /// Soft sides: while the island moves, the content is narrower than the shape for a moment, and a hard-edged
        /// field read as a box inside the black.
        private let sides = CAGradientLayer()
        private var clearTop: CGFloat = -1

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            field.magnificationFilter = .linear
            field.contentsGravity = .resize
            field.opacity = 0
            layer?.addSublayer(field)
            sides.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            sides.locations = [0, 0.07, 0.93, 1]
            sides.startPoint = CGPoint(x: 0, y: 0.5)
            sides.endPoint = CGPoint(x: 1, y: 0.5)
            vertical.mask = sides
            layer?.mask = vertical
            addDrift()
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let b = bounds
            field.bounds = CGRect(x: 0, y: 0, width: b.width * 1.5, height: b.height * 1.7)
            field.position = CGPoint(x: b.midX, y: b.midY)
            vertical.frame = b
            sides.frame = b
            CATransaction.commit()
        }

        func setFade(opacity: Float, clearTop: CGFloat) {
            if clearTop != self.clearTop {
                self.clearTop = clearTop
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                // Layers here are y-up: start at the top edge.
                vertical.startPoint = CGPoint(x: 0.5, y: 1)
                vertical.endPoint = CGPoint(x: 0.5, y: 0)
                vertical.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.black.cgColor]
                vertical.locations = [0, NSNumber(value: Double(min(0.95, clearTop + 0.18))), 1]
                CATransaction.commit()
            }
            guard field.opacity != opacity else { return }
            // Playing ↔ paused dims over 0.6 s, as the SwiftUI animation did.
            CATransaction.begin()
            CATransaction.setAnimationDuration(field.opacity == 0 ? 0 : 0.6)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            field.opacity = opacity
            CATransaction.commit()
        }

        func set(image: NSImage) {
            guard image !== current else { return }
            current = image
            let fade = CABasicAnimation(keyPath: "contents")
            fade.duration = 0.6
            field.add(fade, forKey: "contents")
            field.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        func setMoving(_ on: Bool) {
            // Pausing a layer keeps it where it is; resuming continues from there.
            if on, field.speed == 0 {
                let paused = field.timeOffset
                field.speed = 1
                field.timeOffset = 0
                field.beginTime = 0
                field.beginTime = field.convertTime(CACurrentMediaTime(), from: nil) - paused
            } else if !on, field.speed != 0 {
                field.timeOffset = field.convertTime(CACurrentMediaTime(), from: nil)
                field.speed = 0
            }
        }

        private func addDrift() {
            func loop(_ key: String, _ from: Any, _ to: Any, _ duration: Double) {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = from
                a.toValue = to
                a.duration = duration
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                field.add(a, forKey: key)
            }
            loop("transform.rotation.z", -0.1, 0.1, 9)
            loop("transform.translation.x", -26, 26, 11)
            loop("transform.translation.y", -10, 10, 13)
            loop("transform.scale", 1.0, 1.12, 15)
        }
    }
}

/// The cover, lit from beneath by its own colours, a little smaller while paused, as in Apple Music.
struct ImmersiveArtwork: View {
    @ObservedObject private var media = NowPlayingModel.shared
    let size: CGFloat

    var body: some View {
        let paused = media.mode == .track && !media.isPlaying
        ZStack {
            if let palette = media.palette {
                // Glow: the colour field, a touch larger than the cover and offset down: light, not a shadow.
                Image(nsImage: palette).resizable().interpolation(.high)
                    .frame(width: size * 1.18, height: size * 1.18)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
                    .opacity(0.8)
                    .offset(y: size * 0.08)
                    .mask(Image(nsImage: Glow.radial).resizable())
            }
            LeadArtwork()
                .frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .scaleEffect(paused ? 0.9 : 1)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: paused)
    }
}

// MARK: - Closed island light

/// Light rising from behind each side of the closed island, in the content's own colours — the album's two
/// dominant colours, Claude's orange, a timer's amber. The centre (over the camera) stays pure black.
/// Static gradients: clean, and free.
struct CompactAura: View {
    let left: Color
    let right: Color
    let wing: CGFloat
    let notch: CGSize
    var strength: Double = 1

    var body: some View {
        HStack(spacing: 0) {
            glow(left).frame(width: wing + IslandModel.compactFlare)
                .mask(Image(nsImage: Glow.edges).resizable())
            Color.clear.frame(width: notch.width)
            glow(right).frame(width: wing + IslandModel.compactFlare)
                .mask(Image(nsImage: Glow.edges).resizable().scaleEffect(x: -1, y: 1))
        }
        .frame(height: notch.height)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // The light fades toward the camera, and softly at the island's end too (Glow.edges): while the shape is wider
    // than the closed island (an alert shrinking back, the hover swell) a hard outer edge showed as a coloured box.

    private func glow(_ c: Color) -> some View {
        GeometryReader { geo in
            let d = max(geo.size.width, geo.size.height) * 1.7
            ZStack {
                // A wide, low wash from the bottom edge…
                Image.glow(Glow.rising).foregroundStyle(c.opacity(0.22 * strength))
                // …and a brighter core where the content sits.
                Image.glow(Glow.radial).foregroundStyle(c.opacity(0.42 * strength))
                    .frame(width: d, height: d)
                    .position(x: geo.size.width / 2, y: geo.size.height * 1.1)
            }
        }
        .clipped()
    }
}


// MARK: - Ambient light

/// The island's own light when no album lends it colour: it follows the moment. Rendered once per mood into a small
/// image and drifted by the same render-server layer as the album field — so it costs nothing per frame.
@MainActor
final class AmbientLight: ObservableObject {
    static let shared = AmbientLight()

    enum Mood: String { case morning, midday, focus, evening, night }

    @Published private(set) var mood: Mood = .midday
    private var cache: [Mood: NSImage] = [:]
    private var clock: Timer?
    private var phaseWatch: Any?

    init() {
        mood = Self.mood(at: Date(), focusing: false)
        let t = Timer(timeInterval: 300, repeats: true) { _ in MainActor.assumeIsolated { AmbientLight.shared.update() } }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        clock = t
        phaseWatch = FocusTimer.shared.$phase.receive(on: RunLoop.main).sink { _ in AmbientLight.shared.update() }
    }

    func update() {
        let next = Self.mood(at: Date(), focusing: FocusTimer.shared.phase == .running)
        if next != mood { withAnimation(.easeInOut(duration: 1.2)) { mood = next } }
    }

    nonisolated static func mood(at date: Date, focusing: Bool) -> Mood {
        if focusing { return .focus }
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11: return .morning
        case 11..<17: return .midday
        case 17..<22: return .evening
        default: return .night
        }
    }

    var image: NSImage {
        if let i = cache[mood] { return i }
        let i = Self.render(Self.colors(mood))
        cache[mood] = i
        return i
    }

    static func colors(_ m: Mood) -> [NSColor] {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch m {
        case .morning: return [c(0xFF9F6B), c(0xEE6F8E), c(0x8E7CFF)]
        case .midday: return [c(0x4C9BFF), c(0x3FC7B9), c(0x8E7CFF)]
        case .focus: return [c(0xFF7A33), c(0xFFB547), c(0xB8402F)]
        case .evening: return [c(0xD24F97), c(0x5A49D6), c(0xFF8E52)]
        case .night: return [c(0x22306A), c(0x4A3A9E), c(0x23707F)]
        }
    }

    /// Three soft lights on black.
    static func render(_ colors: [NSColor]) -> NSImage {
        let size = NSSize(width: 120, height: 80)
        return NSImage(size: size, flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(r)
            let spots: [(CGPoint, CGFloat)] = [(CGPoint(x: r.width * 0.18, y: r.height * 0.35), r.width * 0.55),
                                               (CGPoint(x: r.width * 0.62, y: r.height * 0.2), r.width * 0.5),
                                               (CGPoint(x: r.width * 0.92, y: r.height * 0.55), r.width * 0.45)]
            ctx.setBlendMode(.screen)
            for (i, (center, radius)) in spots.enumerated() {
                let col = colors[i % colors.count]
                guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: [col.cgColor, col.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) else { continue }
                ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
            }
            return true
        }
    }
}

// MARK: - Depth

/// A touch of depth under the pointer: the view lifts a little toward it and a soft light follows it across the surface,
/// settling back when the pointer leaves. Done with plain 2D transforms: a true 3D rotation pushed Home's layers into
/// an offscreen pass on every transition (6–10 dropped frames switching back to Home, measured).
struct Tilt: ViewModifier {
    var degrees: Double = 6
    var corner: CGFloat = 16
    var shine = true
    /// The view's size, given rather than measured: a GeometryReader here re-laid out the view as Home reappeared.
    var size: CGSize
    @State private var point: CGPoint?

    func body(content: Content) -> some View {
        if Access.reduceMotion || RenderMode.snapshot || ProcessInfo.processInfo.environment["ATOLL_NO_TILT"] != nil {
            content
        } else {
            let p = point ?? .zero
            // How far it leans: a few points for a card, more for artwork — scaled from the old tilt angle.
            let lean = CGFloat(degrees) * 0.6
            content
                .overlay {
                    if shine, let point {
                        RadialGradient(colors: [Color.white.opacity(0.16), .clear], center: UnitPoint(x: point.x + 0.5, y: point.y + 0.5),
                                       startRadius: 0, endRadius: max(size.width, size.height) * 0.7)
                            .blendMode(.plusLighter)
                            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(point == nil ? 1 : 1 + CGFloat(degrees) * 0.004)
                .offset(x: p.x * lean, y: p.y * lean)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        guard size.width > 0, size.height > 0 else { return }
                        let next = CGPoint(x: min(0.5, max(-0.5, loc.x / size.width - 0.5)), y: min(0.5, max(-0.5, loc.y / size.height - 0.5)))
                        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.8)) { point = next }
                    case .ended:
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { point = nil }
                    }
                }
        }
    }
}

extension View {
    func tilt(_ degrees: Double = 6, corner: CGFloat = 16, shine: Bool = true, size: CGSize) -> some View {
        modifier(Tilt(degrees: degrees, corner: corner, shine: shine, size: size))
    }
}
