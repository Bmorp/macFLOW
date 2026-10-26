import AppKit
import SwiftUI

/// Where the Dock is, read from its own settings and the screen's visible frame.
struct DockGeometry: Equatable {
    enum Edge: String { case bottom, left, right }

    var edge: Edge
    var autohide: Bool
    var screenFrame: CGRect
    /// The Dock's band along its edge, full length (its real extent isn't public).
    var band: CGRect
    var thickness: CGFloat
    var tileSize: CGFloat = 48
    /// How far magnified icons reach past the Dock's edge (0 without magnification).
    var magnifiedReach: CGFloat = 0

    var isVertical: Bool { edge != .bottom }

    @MainActor static func current() -> DockGeometry {
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        let edge = Edge(rawValue: defaults?.string(forKey: "orientation") ?? "bottom") ?? .bottom
        let autohide = defaults?.bool(forKey: "autohide") ?? false
        let tile = CGFloat(defaults?.double(forKey: "tilesize") ?? 0)
        let tileSize = tile > 0 ? tile : 48

        func inset(_ s: NSScreen) -> CGFloat {
            switch edge {
            case .bottom: s.visibleFrame.minY - s.frame.minY
            case .left: s.visibleFrame.minX - s.frame.minX
            case .right: s.frame.maxX - s.visibleFrame.maxX
            }
        }
        // The Dock sits on the display whose visible frame gives way for it; with auto-hide, the main display.
        let screens = NSScreen.screens
        let screen = screens.max { inset($0) < inset($1) }.flatMap { inset($0) > 8 ? $0 : nil } ?? screens[0]
        let measured = inset(screen)
        let thickness = autohide || measured < 12 ? tileSize + 18 : measured
        let f = screen.frame
        let band: CGRect = switch edge {
        case .bottom: CGRect(x: f.minX, y: f.minY, width: f.width, height: thickness)
        case .left: CGRect(x: f.minX, y: f.minY, width: thickness, height: f.height)
        case .right: CGRect(x: f.maxX - thickness, y: f.minY, width: thickness, height: f.height)
        }
        let magnifies = defaults?.bool(forKey: "magnification") ?? false
        let large = CGFloat(defaults?.double(forKey: "largesize") ?? 0)
        let reach = magnifies ? max(0, (large > 0 ? large : 96) - tileSize) : 0
        return DockGeometry(edge: edge, autohide: autohide, screenFrame: f, band: band, thickness: thickness,
                            tileSize: tileSize, magnifiedReach: reach)
    }

    /// The thin strip just inside the Dock's inner edge, centred, where reaching past the Dock reveals the bar.
    var revealStrip: CGRect {
        let reach: CGFloat = 8
        switch edge {
        case .bottom:
            let w = min(screenFrame.width * 0.7, 900)
            return CGRect(x: screenFrame.midX - w / 2, y: band.maxY, width: w, height: reach)
        case .left:
            let h = min(screenFrame.height * 0.7, 700)
            return CGRect(x: band.maxX, y: screenFrame.midY - h / 2, width: reach, height: h)
        case .right:
            let h = min(screenFrame.height * 0.7, 700)
            return CGRect(x: band.minX - reach, y: screenFrame.midY - h / 2, width: reach, height: h)
        }
    }

    /// Where a floating panel of `size` sits, `gap` points off the Dock's inner edge.
    func panelFrame(size: CGSize, gap: CGFloat) -> CGRect {
        switch edge {
        case .bottom:
            CGRect(x: screenFrame.midX - size.width / 2, y: band.maxY + gap, width: size.width, height: size.height)
        case .left:
            CGRect(x: band.maxX + gap, y: screenFrame.midY - size.height / 2, width: size.width, height: size.height)
        case .right:
            CGRect(x: band.minX - gap - size.width, y: screenFrame.midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    /// The handle sits just past the Dock — and past magnified icons, so it never covers them.
    var handleGap: CGFloat { magnifiedReach > 0 ? magnifiedReach + 6 : 6 }

    /// Generous zone for files dragged toward the Dock.
    var dropApproachZone: CGRect {
        switch edge {
        case .bottom: CGRect(x: screenFrame.minX, y: band.minY, width: screenFrame.width, height: band.height + 110)
        case .left: CGRect(x: band.minX, y: screenFrame.minY, width: band.width + 110, height: screenFrame.height)
        case .right: CGRect(x: band.maxX - band.width - 110, y: screenFrame.minY, width: band.width + 110, height: screenFrame.height)
        }
    }
}

/// A floating panel just above the Dock.
final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosting view that acts on the first click while another app is active.
final class FirstClickHostingView<Content: SwiftUI.View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The material every Dock-side surface is made of: Liquid Glass where available.
struct DockGlass: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        if RenderMode.snapshot {
            content.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: 0.16).opacity(0.92)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            content
                .background(VisualEffect(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        }
    }
}
