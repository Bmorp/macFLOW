import AppKit
import SwiftUI
import Quartz

/// Borderless, non-activating panel that sits above the menu bar, on every Space and over full-screen apps.
final class NotchPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Never let AppKit push us below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // Quick Look for shelf items: the panel is in the responder chain, so it hands control to our data source.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
        panel.delegate = QuickLookController.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

/// Hosting view that reacts to the very first click even when Atoll isn't the active app.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Container that guarantees mouse-moved delivery (tracking areas work for inactive apps)
/// and forwards trackpad scroll gestures.
final class TrackingContainerView: NSView {
    var onMouse: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onMouse?() }
    override func mouseEntered(with event: NSEvent) { onMouse?() }
    override func mouseExited(with event: NSEvent) { onMouse?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
