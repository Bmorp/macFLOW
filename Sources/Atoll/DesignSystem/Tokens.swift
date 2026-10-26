import SwiftUI
import AppKit
import os

/// Design tokens. Values and rationale live in DESIGN.md.
enum DS {

    // MARK: Colour — Apple's dark system palette on an opaque black island.
    enum Palette {
        static let island = Color.black
        static let label = Color.white
        private static let labelBase = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255)
        /// ≈ #8D8D93, 6.4 : 1 on black (80 % under Increase Contrast).
        static var secondary: Color { labelBase.opacity(Access.increaseContrast ? 0.8 : 0.6) }
        /// ≈ #464649. Decorative only — never the sole carrier of information.
        static var tertiary: Color { labelBase.opacity(Access.increaseContrast ? 0.55 : 0.3) }
        static let fill = Color.white.opacity(0.12)
        static let fillHover = Color.white.opacity(0.2)
        static let track = Color.white.opacity(0.18)

        static let orange = Color(red: 1.0, green: 0.624, blue: 0.039)     // #FF9F0A
        static let green = Color(red: 0.188, green: 0.820, blue: 0.345)    // #30D158
        static let blue = Color(red: 0.039, green: 0.518, blue: 1.0)       // #0A84FF
        static let cyan = Color(red: 0.392, green: 0.824, blue: 1.0)       // #64D2FF
        static let red = Color(red: 1.0, green: 0.271, blue: 0.227)        // #FF453A
        static let yellow = Color(red: 1.0, green: 0.839, blue: 0.039)     // #FFD60A
        static let indigo = Color(red: 0.369, green: 0.361, blue: 0.902)   // #5E5CE6
    }

    // MARK: Type — SF Pro, medium weight or heavier.
    enum Typeface {
        static let hero = Font.system(size: 40, weight: .semibold).monospacedDigit()
        static let title = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 13, weight: .medium)
        /// Figures beside the notch: white, rounded, tabular. Colour stays in the mark on the other side.
        static let compact = Font.system(size: 13.5, weight: .semibold, design: .rounded).monospacedDigit()
        static let caption = Font.system(size: 11, weight: .medium).monospacedDigit()
        static let search = Font.system(size: 19, weight: .regular)
        static let sectionTitle = Font.system(size: 11, weight: .semibold)
    }

    // MARK: Space — 4-pt scale.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: Geometry — concentric: inner = outer − margin.
    enum Radius {
        static let expanded: CGFloat = 30
        static let margin: CGFloat = 16
        static let inner: CGFloat = 14
        static let control: CGFloat = 10
    }

    enum Size {
        /// Body width of an open island (shoulders are added on top).
        static let rowWidth: CGFloat = 460
        /// Height of the one-row area below the notch: 44-pt content, 4 above, 14 below.
        static let rowHeight: CGFloat = 64
        /// The home: music and apps below the notch.
        static let homeWidth: CGFloat = 560
        static let homeHeight: CGFloat = 112
        static let searchWidth: CGFloat = 600
        static let bubbleGap: CGFloat = 8
        static let minHit: CGFloat = 28
    }

    // MARK: Island silhouette
    enum Island {
        /// Shoulders: the concave curves where the island grows out of the top edge.
        static let compactShoulder: CGFloat = 8
        static let openShoulder: CGFloat = 22
        /// Bottom corners of an open island — round enough to read as a pill.
        static let openCorner: CGFloat = 30
        static let rowLeading: CGFloat = 18
    }
}

/// Live system accessibility settings.
///
/// Read on every animation and many renders, so both are cached and refreshed when the setting changes
/// rather than asked of NSWorkspace each time.
enum Access {
    private struct Settings { var reduceMotion: Bool; var increaseContrast: Bool }
    private static let cache = OSAllocatedUnfairLock<Settings?>(initialState: nil)
    private static let observer: NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
    ) { _ in cache.withLock { $0 = nil } }

    private static var current: Settings {
        _ = observer
        if let s = cache.withLock({ $0 }) { return s }
        let ws = NSWorkspace.shared
        let s = Settings(reduceMotion: ws.accessibilityDisplayShouldReduceMotion,
                         increaseContrast: ws.accessibilityDisplayShouldIncreaseContrast)
        cache.withLock { $0 = s }
        return s
    }

    static var reduceMotion: Bool { current.reduceMotion }
    static var increaseContrast: Bool { current.increaseContrast }
}

/// Motion vocabulary. One choreography everywhere (DESIGN.md › Motion):
/// the shape springs; content leaves fast before it shrinks and arrives staggered after it grows.
/// Under Reduce Motion every move becomes a short cross-fade.
enum Motion {
    /// The shape opening — quick, with a whisper of overshoot so it feels thrown rather than slid.
    static var open: Animation {
        Access.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.8)
    }
    /// The shape closing — critically damped and immediate: no bounce, no wait.
    static var close: Animation {
        Access.reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.26, dampingFraction: 1)
    }
    /// When a closing island swaps its open content for the compact one: once the close spring has done
    /// most of its travel, so the content shrinks with the shape and gives way just before it lands.
    static let closeSwap: Double = 0.17
    /// One open state turning into another.
    static var morph: Animation {
        Access.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.88)
    }
    static var expand: Animation { open }
    static var collapse: Animation { close }
    static var split: Animation {
        Access.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.72)
    }
    static var hover: Animation {
        Access.reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.8)
    }
    static var content: Animation { .smooth(duration: 0.3) }
    /// The duo cross-fade spring.
    static var duo: Animation {
        Access.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86)
    }

    // Content choreography.
    static let revealDelay: Double = 0.03
    static let revealStagger: Double = 0.025
    static let revealSpring = Spring(response: 0.3, dampingRatio: 0.9)
    static var reveal: Animation {
        Access.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.9)
    }
    static let exitDuration: Double = 0.1
    static var exit: Animation { .easeIn(duration: exitDuration) }
}
