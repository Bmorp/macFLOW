import AppKit

/// Physical (or emulated) notch metrics for one screen.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchSize: CGSize
    var hasNotch: Bool

    static func detect(for screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            return NotchGeometry(screenFrame: frame,
                                 notchSize: CGSize(width: max(width, 120), height: topInset),
                                 hasNotch: true)
        }
        // No hardware notch: draw a slim virtual island in the menu bar.
        let menuBar = frame.maxY - screen.visibleFrame.maxY
        let height = min(max(menuBar > 0 ? menuBar - 2 : 24, 22), 30)
        return NotchGeometry(screenFrame: frame,
                             notchSize: CGSize(width: 170, height: height),
                             hasNotch: false)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var hasNotch: Bool { safeAreaInsets.top > 0 }
}
