#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: draws every in-between frame of the island's transitions at fixed moments, using the same
/// springs, exit timing and reveal stagger as the live animation — so glitches can be seen, not guessed.
@MainActor
enum MotionHarness {
    struct Transition {
        let name: String
        let from: (IslandModel) -> Void
        let to: (IslandModel) -> Void
        let spring: Spring
        let delay: Double
    }

    static let times: [Double] = [0, 0.04, 0.08, 0.12, 0.16, 0.22, 0.3, 0.4, 0.55, 0.8]

    static func run(outDir: String) {
        Storage.readOnly = true
        RenderMode.snapshot = true
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let screen = NSScreen.screens.first(where: \.hasNotch) ?? NSScreen.main!
        let geo = NotchGeometry.detect(for: screen)

        NowPlayingModel.shared.debugInjectApp(nil)
        NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: 97, artwork: art())
        FocusTimer.shared.start(minutes: 25, label: "Focus")
        ActivityCenter.shared.debugSet([.nowPlaying, .timer])
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        // Keep in step with `Motion`.
        let open = Spring(response: 0.3, dampingRatio: 0.8)
        let close = Spring(response: 0.26, dampingRatio: 1)
        let morph = Spring(response: 0.3, dampingRatio: 0.88)
        let transitions: [Transition] = [
            Transition(name: "m0-open-home", from: { _ in }, to: { $0.debugSetMode(.expanded(.glance)) }, spring: open, delay: 0),
            Transition(name: "m1-open-music", from: { _ in }, to: { $0.debugSetMode(.expanded(.activity(.nowPlaying))) }, spring: open, delay: 0),
            Transition(name: "m2-close-home", from: { $0.debugSetMode(.expanded(.glance)) }, to: { _ in }, spring: close, delay: 0),
            Transition(name: "m3-switch-music-timer", from: { $0.debugSetMode(.expanded(.activity(.nowPlaying))) },
                       to: { $0.debugSetMode(.expanded(.activity(.timer))) }, spring: morph, delay: 0),
            Transition(name: "m4-glance-search", from: { $0.debugSetMode(.expanded(.glance)) }, to: { SearchModel.shared.reset(); $0.debugSetMode(.search) },
                       spring: morph, delay: 0),
            Transition(name: "m5-volume-alert", from: { _ in }, to: { $0.debugSetMode(.alert, alert: .volume(level: 0.6, muted: false)) },
                       spring: open, delay: 0),
        ]

        for t in transitions {
            let a = IslandModel(geometry: geo, isPrimary: true)
            let b = IslandModel(geometry: geo, isPrimary: true)
            t.from(a)
            t.to(b)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let frames = VStack(alignment: .leading, spacing: 0) {
                ForEach(times, id: \.self) { time in
                    frame(a, b, transition: t, time: time)
                }
            }
            let r = ImageRenderer(content: frames.environment(\.colorScheme, .dark))
            r.scale = 1.5
            r.colorMode = .nonLinear
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(t.name).png"))
            }
        }
        FocusTimer.shared.stop()
        print("motion ok → \(outDir)")
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }

    private static func frame(_ a: IslandModel, _ b: IslandModel, transition t: Transition, time: Double) -> some View {
        let g = CGFloat(time <= t.delay ? 0 : t.spring.value(target: 1.0, time: time - t.delay))
        let sa = a.spec, sb = b.spec
        let spec = IslandSpec(size: CGSize(width: lerp(sa.size.width, sb.size.width, g), height: lerp(sa.size.height, sb.size.height, g)),
                              shoulder: lerp(sa.shoulder, sb.shoulder, g), corner: lerp(sa.corner, sb.corner, g))
        let rim = CGFloat(lerp(CGFloat(a.rimStrength), CGFloat(b.rimStrength), min(1, max(0, g))))
        // Same rule as the live view: closing holds the open content until `Motion.closeSwap`; otherwise swap at once.
        let showFrom = a.isOpen && !b.isOpen && time < Motion.closeSwap
        let sweepT = max(0, time - 0.05) / 0.6
        let sweep = b.isOpen ? CGFloat(min(1, sweepT < 0.5 ? 2 * sweepT * sweepT : 1 - pow(-2 * sweepT + 2, 2) / 2)) : 1
        let canvas = CGSize(width: 760, height: 190)
        return ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.30, green: 0.36, blue: 0.56), Color(red: 0.55, green: 0.42, blue: 0.56)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.white.opacity(0.2)).frame(height: a.notch.height)
            IslandSurface(spec: spec, notchHeight: a.notch.height, rim: b.rim, rimStrength: Double(rim), sweep: sweep, elevated: b.isOpen || a.isOpen) {
                if showFrom {
                    IslandPresentation(model: a, mode: a.mode, size: sa.size, alert: a.alert, primary: a.primary, ns: Namespace().wrappedValue)
                } else {
                    IslandPresentation(model: b, mode: b.mode, size: sb.size, alert: b.alert, primary: b.primary, ns: Namespace().wrappedValue)
                }
            }
            Text(String(format: "%.0f ms", time * 1000))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }

    private static func art() -> NSImage {
        let img = NSImage(size: NSSize(width: 200, height: 200))
        img.lockFocus()
        NSGradient(colors: [NSColor(red: 0.98, green: 0.45, blue: 0.3, alpha: 1), NSColor(red: 0.55, green: 0.2, blue: 0.85, alpha: 1)])?
            .draw(in: NSRect(x: 0, y: 0, width: 200, height: 200), angle: -45)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 60, y: 60, width: 80, height: 80)).fill()
        img.unlockFocus()
        return img
    }
}
#endif
