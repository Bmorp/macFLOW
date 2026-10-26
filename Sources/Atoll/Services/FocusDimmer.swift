import AppKit
import SwiftUI
import Combine

/// While a focus block runs, everything but the window you're working in dims — softly, with a feathered edge, and it
/// follows that window as you move it or switch apps. Clicks go straight through; the menu bar and the notch stay lit.
/// Settings › Flow › Rooms › Dim Around Your Window.
@MainActor
final class FocusDimmer {
    static let shared = FocusDimmer()

    private var windows: [NSScreen: DimWindow] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var poll: Timer?
    private var hole: CGRect?        // in AppKit screen coordinates (y up)
    private var on = false
    private let queue = DispatchQueue(label: "atoll.dimmer", qos: .userInitiated)

    func start() {
        guard cancellables.isEmpty else { return }
        Publishers.CombineLatest(FocusTimer.shared.$phase, Prefs.shared.$dimFocus)
            .receive(on: RunLoop.main)
            .sink { phase, enabled in FocusDimmer.shared.set(enabled && phase == .running && !Self.isBreak(FocusTimer.shared.label)) }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FocusDimmer.shared.track() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FocusDimmer.shared.rebuild() }
        }
    }

    #if DEBUG
    var debugHole: CGRect? { hole }
    #endif

    private static func isBreak(_ label: String) -> Bool {
        ["break", "lunch", "rest"].contains { label.lowercased().contains($0) }
    }

    private func set(_ dim: Bool) {
        guard dim != on else { return }
        on = dim
        if dim {
            rebuild()
            track()
            let t = Timer(timeInterval: 0.35, repeats: true) { _ in MainActor.assumeIsolated { FocusDimmer.shared.track() } }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            poll = t
            windows.values.forEach { $0.fade(in: true) }
        } else {
            poll?.invalidate()
            poll = nil
            windows.values.forEach { $0.fade(in: false) }
        }
    }

    private func rebuild() {
        let screens = Set(NSScreen.screens)
        for (screen, w) in windows where !screens.contains(screen) { w.orderOut(nil); windows[screen] = nil }
        guard on else { return }
        for screen in NSScreen.screens where windows[screen] == nil { windows[screen] = DimWindow(screen: screen) }
        for (screen, w) in windows { w.place(on: screen); w.update(hole: hole) }
    }

    /// Where the front window is (off the main thread: the window list is a round trip to the window server).
    private func track() {
        guard on else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        queue.async {
            // The window server lists windows front to back: the first real window that isn't ours is the one you're in.
            // (Asking which app is frontmost can lag behind what's on screen; the window order can't.)
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let bounds = list.lazy
                .filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) != own }
                .compactMap { ($0[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } }
                .first { $0.width > 160 && $0.height > 120 }
            // Window-server coordinates are y-down from the top of the main screen; AppKit's are y-up.
            let rect = bounds.map { CGRect(x: $0.minX, y: primaryHeight - $0.maxY, width: $0.width, height: $0.height) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = FocusDimmer.shared
                    guard rect != me.hole else { return }
                    me.hole = rect
                    me.windows.values.forEach { $0.update(hole: rect) }
                }
            }
        }
    }
}

/// One screen's dimming: a click-through window above other apps' windows, with a soft hole where yours is.
private final class DimWindow: NSWindow {
    private let state = DimState()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: DimView(state: state))
        alphaValue = 0
        place(on: screen)
    }

    func place(on screen: NSScreen) {
        setFrame(screen.frame, display: false)
        // The menu bar (and the notch in it) stays lit.
        state.top = screen.frame.maxY - screen.visibleFrame.maxY
    }

    func update(hole: CGRect?) {
        guard let hole, frame.intersects(hole) else { state.hole = nil; return }
        // Into this window's coordinates, y-down for SwiftUI.
        let local = CGRect(x: hole.minX - frame.minX, y: frame.maxY - hole.maxY, width: hole.width, height: hole.height)
        withAnimation(.smooth(duration: 0.25)) { state.hole = local }
    }

    func fade(in show: Bool) {
        if show { orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = show ? 0.6 : 0.4
            animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if !show { self?.orderOut(nil) } }
        })
    }
}

@MainActor
private final class DimState: ObservableObject {
    @Published var hole: CGRect?
    @Published var top: CGFloat = 0
}

private struct DimView: View {
    @ObservedObject var state: DimState

    var body: some View {
        Canvas { ctx, size in
            var shade = Path(CGRect(x: 0, y: state.top, width: size.width, height: size.height - state.top))
            shade.closeSubpath()
            ctx.fill(shade, with: .color(.black.opacity(0.42)))
            if let hole = state.hole {
                // Cut the window out with a feathered edge, so the light falls off rather than stopping at a line.
                ctx.blendMode = .destinationOut
                ctx.addFilter(.blur(radius: 14))
                ctx.fill(Path(roundedRect: hole.insetBy(dx: -8, dy: -8), cornerRadius: 18), with: .color(.black))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
