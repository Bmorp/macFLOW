import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Offscreen snapshot rendering can't run entrance animations or host AppKit views.
enum RenderMode {
    static var snapshot = false
}

// MARK: - Transitions

extension AnyTransition {
    /// Content swap without blur or fade: the new content settles in from a hair smaller, the old one is simply gone.
    static var duo: AnyTransition { duo(anchor: .center) }

    static func duo(anchor: UnitPoint) -> AnyTransition {
        if Access.reduceMotion { return .identity }
        return .asymmetric(insertion: .scale(scale: 0.96, anchor: anchor), removal: .identity)
    }
}

// MARK: - Buttons

/// Press feedback without haptics: a quick dip in scale and opacity.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.9
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Bezel-less SF Symbol button with a 32-pt hit region and a soft hover disc.
struct GlyphButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 15
    var tint: Color = DS.Palette.label
    var hit: CGFloat = 32
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: hit, height: hit)
                .background(Circle().fill(hover ? DS.Palette.fill : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Tinted circle button, as in the Clock timer Live Activity.
struct CircleButton: View {
    let symbol: String
    let label: String
    var tint: Color
    var diameter: CGFloat = 40
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.4, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(tint.opacity(hover ? 0.32 : 0.24)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The one prominent action in a presentation: tinted background, white label.
struct ProminentButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(tint.opacity(hover ? 1 : 0.92)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// Quiet secondary action: grey fill capsule.
struct SecondaryButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(DS.Palette.label)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(hover ? DS.Palette.fillHover : DS.Palette.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: - Indicators

struct ProgressRing: View {
    var progress: Double?
    var tint: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: lineWidth)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.001, min(progress, 1)))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: progress)
            } else {
                SpinnerArc(tint: tint, lineWidth: lineWidth)
            }
        }
    }
}

// Waveform lives in LayerMotion.swift (a Core Animation loop).

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    var accent: Color = DS.Palette.indigo

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct BatteryGlyph: View {
    var level: Int
    var charging: Bool
    var width: CGFloat = 26

    private var fill: Color {
        if charging { return DS.Palette.green }
        if level <= 10 { return DS.Palette.red }
        if level <= 20 { return DS.Palette.orange }
        return .white
    }

    var body: some View {
        let h = width * 0.48
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: h * 0.32, style: .continuous)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: h * 0.2, style: .continuous)
                    .fill(fill)
                    .padding(2)
                    .frame(width: max(5, (width - 2) * CGFloat(level) / 100))
            }
            .frame(width: width, height: h)
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.4)).frame(width: 1.8, height: h * 0.36)
        }
        .animation(.smooth(duration: 0.6), value: level)
        .accessibilityHidden(true)
    }
}

struct BatteryRing: View {
    let level: Int
    let label: String
    var size: CGFloat = 32

    var body: some View {
        VStack(spacing: 4) {
            ProgressRing(progress: Double(level) / 100, tint: level <= 20 ? DS.Palette.red : DS.Palette.green, lineWidth: 3)
                .frame(width: size, height: size)
                .overlay(Text("\(level)").font(.system(size: size * 0.31, weight: .semibold).monospacedDigit()).foregroundStyle(.white))
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Palette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(level) percent")
    }
}

struct PrivacyDots: View {
    let camera: Bool
    let mic: Bool
    var body: some View {
        HStack(spacing: 3) {
            if camera { Circle().fill(DS.Palette.green).frame(width: 6, height: 6) }
            if mic { Circle().fill(DS.Palette.orange).frame(width: 6, height: 6) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([camera ? "Camera in use" : nil, mic ? "Microphone in use" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DS.Palette.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DS.Palette.fill))
    }
}

// MARK: - Scrubber

/// Media scrubber: thin track that thickens under the pointer; alignment haptic only at either end.
struct Scrubber: View {
    let position: Double
    let duration: Double
    var tint: Color = .white
    let onSeek: (Double) -> Void

    @State private var dragValue: Double?
    @State private var hover = false

    var body: some View {
        let fraction = duration > 0 ? (dragValue ?? position / duration) : 0
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = max(1, geo.size.width)
                let h: CGFloat = (hover || dragValue != nil) ? 7 : 4
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Palette.track)
                    Capsule().fill(tint).frame(width: max(h, w * min(max(fraction, 0), 1)))
                }
                .frame(height: h)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let v = min(max(0, g.location.x / w), 1)
                            if let old = dragValue, (old > 0 && v == 0) || (old < 1 && v == 1) { Haptics.snap() }
                            dragValue = v
                        }
                        .onEnded { _ in
                            if let v = dragValue { onSeek(v * duration) }
                            dragValue = nil
                        }
                )
                .onHover { hv in withAnimation(Motion.hover) { hover = hv } }
                .animation(Motion.hover, value: dragValue != nil)
            }
            .frame(height: 12)
            HStack {
                Text((fraction * duration).clock)
                Spacer()
                Text("−" + max(0, duration - fraction * duration).clock)
            }
            .font(DS.Typeface.caption)
            .foregroundStyle(DS.Palette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(fraction * duration)) of \(Int(duration)) seconds")
        .accessibilityAdjustableAction { dir in
            let step = max(5, duration * 0.05)
            onSeek(min(duration, max(0, position + (dir == .increment ? step : -step))))
        }
    }
}

// MARK: - Marquee

/// Single line that glides when it doesn't fit; truncates under Reduce Motion.
/// Titles that fit — nearly all of them — are a plain `Text`: `ViewThatFits` picks it without geometry readers
/// or preferences, which used to cost a few milliseconds every time the island changed.
struct MarqueeText: View {
    let text: String
    var font: Font = DS.Typeface.title
    var color: Color = DS.Palette.label

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
            if Access.reduceMotion || RenderMode.snapshot {
                Text(text).font(font).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
            } else {
                MarqueeScroller(text: text, font: font, color: color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(text)
    }
}

private struct TextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The overflowing case only. The line is drawn once into an image and Core Animation slides it
/// (`MarqueeStrip`), so a long title scrolling costs nothing per frame — it used to re-run a 60 fps
/// timeline, and kept doing so in Home while the island was closed.
private struct MarqueeScroller: View {
    let text: String
    let font: Font
    let color: Color
    @Environment(\.islandShowing) private var showing
    @Environment(\.displayScale) private var scale
    @State private var textWidth: CGFloat = 0
    @State private var strip: CGImage?
    private let speed: Double = 24
    private let gap: CGFloat = 36
    private let pause: Double = 2.2

    var body: some View {
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                MarqueeStrip(image: strip, scale: scale, distance: textWidth + gap, speed: speed, pause: pause,
                             running: showing && textWidth > 0)
                    .allowsHitTesting(false)
            }
            .background(
                Text(text).font(font).fixedSize().hidden()
                    .background(GeometryReader { g in Color.clear.preference(key: TextWidthKey.self, value: g.size.width) })
            )
            .onPreferenceChange(TextWidthKey.self) { w in
                guard w != textWidth else { return }
                textWidth = w
                render()
            }
            .onChange(of: text) { _, _ in render() }
            .onChange(of: scale) { _, _ in render() }
            .onAppear { if strip == nil { render() } }
    }

    private func render() {
        let renderer = ImageRenderer(content: HStack(spacing: gap) { line; line }.fixedSize())
        renderer.scale = max(1, scale)
        strip = renderer.cgImage
    }

    private var line: some View { Text(text).font(font).foregroundStyle(color).fixedSize() }
}

// MARK: - Icons

/// System icons cached and rasterized once to 8-bit sRGB at display size.
@MainActor
enum IconCache {
    private static let images = NSCache<NSString, NSImage>()
    private static let rasters = NSCache<NSString, CGImage>()

    static func app(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        let key = "app:\(bundleID)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        images.setObject(img, forKey: key)
        return img
    }

    static func file(_ path: String) -> NSImage {
        let key = "file:\(path)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        images.setObject(img, forKey: key)
        return img
    }

    static func type(_ identifier: String?, isFolder: Bool = false) -> NSImage {
        let key = "type:\(identifier ?? (isFolder ? "folder" : "data"))" as NSString
        if let hit = images.object(forKey: key) { return hit }
        let t = identifier.flatMap { UTType($0) } ?? (isFolder ? .folder : .data)
        let img = NSWorkspace.shared.icon(for: t)
        images.setObject(img, forKey: key)
        return img
    }

    static func raster(_ image: NSImage, points: CGFloat) -> CGImage? {
        let px = Int((points * 2).rounded())
        let key = "\(ObjectIdentifier(image).hashValue)@\(px)" as NSString
        if let hit = rasters.object(forKey: key) { return hit }
        var rect = CGRect(x: 0, y: 0, width: px, height: px)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        // Some system icons carry extended-range highlights; normalize so they never force EDR tone mapping.
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return source }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: px, height: px))
        let cg = ctx.makeImage() ?? source
        rasters.setObject(cg, forKey: key)
        return cg
    }
}

struct IconImage: View {
    let image: NSImage
    var size: CGFloat

    var body: some View {
        Group {
            if let cg = IconCache.raster(image, points: size) {
                Image(decorative: cg, scale: 2).resizable().interpolation(.high)
            } else {
                Image(nsImage: image).resizable().interpolation(.high)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Formatting

extension Double {
    /// m:ss or h:mm:ss
    var clock: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let s = Int(self)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
