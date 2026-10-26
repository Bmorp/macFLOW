import AppKit
import SwiftUI
import Combine

/// A widget's own borderless window, just above the desktop icons, on every Space.
final class WidgetWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = WidgetWindow.desktopLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    /// While dragging, the widget floats over its neighbours.
    static let liftedLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Per-window presentation state the SwiftUI root reads.
@MainActor
final class WidgetWindowState: ObservableObject {
    @Published var presented = false
    @Published var lifted = false
    var onDrag: ((_ ended: Bool) -> Void)?
}

/// Duo entrance and exit for a whole widget.
private struct DuoPresence: ViewModifier {
    let shown: Bool
    func body(content: Content) -> some View {
        if Access.reduceMotion {
            content.opacity(shown ? 1 : 0)
        } else {
            content
                .opacity(shown ? 1 : 0)
                .blur(radius: shown ? 0 : 12)
                .scaleEffect(shown ? 1 : 0.94)
        }
    }
}

private struct WidgetWindowRoot: View {
    let id: UUID
    @ObservedObject var state: WidgetWindowState
    @ObservedObject private var store = WidgetStore.shared
    @ObservedObject private var prefs = Prefs.shared

    private var style: WidgetStyle {
        store.desktopFocused || store.editing || !prefs.widgetsDimInApps ? .desktop : .vibrant
    }

    var body: some View {
        Group {
            if let w = store.instance(id) {
                WidgetContainer(kind: w.kind, family: w.family, editing: store.editing, lifted: state.lifted,
                                onRemove: { store.remove(id) }) {
                    WidgetContent(kind: w.kind)
                }
                .environment(\.widgetStyle, style)
                .modifier(DuoPresence(shown: state.presented))
                .animation(Motion.duo, value: state.presented)
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { _ in state.onDrag?(false) }
                        .onEnded { _ in state.onDrag?(true) }
                )
                .contextMenu { menu(for: w) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(w.kind.title) widget")
            }
        }
        .padding(WidgetMetrics.windowPadding)
    }

    @ViewBuilder private func menu(for w: WidgetInstance) -> some View {
        if w.kind.families.count > 1 {
            Picker("Size", selection: Binding(get: { w.family }, set: { store.resize(id, to: $0) })) {
                ForEach(w.kind.families) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
        }
        Button("Edit Widgets…") { WidgetManager.shared.beginEditing() }
        Button("Remove Widget") { store.remove(id) }
    }
}

@MainActor
private final class WidgetWindowController {
    let id: UUID
    let window = WidgetWindow()
    let state = WidgetWindowState()
    private var family: WidgetFamily
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var alignedX = false
    private var alignedY = false
    var isDragging: Bool { dragStartMouse != nil }

    private var store: WidgetStore { .shared }
    private let pad = WidgetMetrics.windowPadding

    init(_ instance: WidgetInstance) {
        id = instance.id
        family = instance.family
        let host = WidgetHostingView(rootView: WidgetWindowRoot(id: instance.id, state: state))
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(windowFrame(for: instance), display: false)
        state.onDrag = { [weak self] ended in ended ? self?.endDrag() : self?.drag() }
    }

    private func windowFrame(for w: WidgetInstance) -> NSRect {
        store.frame(for: w).insetBy(dx: -pad, dy: -pad)
    }

    func present(delay: TimeInterval = 0) {
        // Atoll is never the active app; ordinary ordering would leave the window off screen.
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.state.presented = true }
    }

    func dismiss(completion: @escaping () -> Void) {
        state.presented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.window.orderOut(nil)
            self?.window.close()
            completion()
        }
    }

    func update(_ w: WidgetInstance) {
        guard !isDragging else { return }
        let target = windowFrame(for: w)
        if w.family != family {
            // Size change: the old size dissolves, the new one settles in.
            family = w.family
            state.presented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.window.setFrame(target, display: true)
                self?.state.presented = true
            }
        } else if window.frame != target {
            animate(to: target)
        }
    }

    private func animate(to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Access.reduceMotion ? 0 : 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            window.animator().setFrame(frame, display: true)
        }
    }

    // MARK: Dragging — follows the pointer, pulls onto neighbours' edges with an alignment haptic.

    private func drag() {
        let mouse = NSEvent.mouseLocation
        if dragStartMouse == nil {
            dragStartMouse = mouse
            dragStartOrigin = window.frame.origin
            window.level = WidgetWindow.liftedLevel
            state.lifted = true
        }
        guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin, let w = store.instance(id) else { return }
        let size = w.family.size
        let raw = NSPoint(x: startOrigin.x + mouse.x - startMouse.x + pad, y: startOrigin.y + mouse.y - startMouse.y + pad)
        let center = NSPoint(x: raw.x + size.width / 2, y: raw.y + size.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? WidgetStore.screen(for: w.screenID)
        let offset = store.offset(forCocoaOrigin: raw, size: size, on: screen)
        let a = store.aligned(offset, size: size, screen: screen.displayID, excluding: id, threshold: 8)
        if (a.x && !alignedX) || (a.y && !alignedY) { Haptics.snap() }
        alignedX = a.x
        alignedY = a.y
        let origin = store.cocoaOrigin(forOffset: a.point, size: size, on: screen)
        window.setFrameOrigin(NSPoint(x: origin.x - pad, y: origin.y - pad))
    }

    private func endDrag() {
        guard dragStartMouse != nil else { return }
        dragStartMouse = nil
        dragStartOrigin = nil
        alignedX = false
        alignedY = false
        state.lifted = false
        let origin = NSPoint(x: window.frame.minX + pad, y: window.frame.minY + pad)
        guard let w = store.move(id, toCocoaOrigin: origin) else { return }
        family = w.family
        animate(to: windowFrame(for: w))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) { [weak self] in
            self?.window.level = WidgetWindow.desktopLevel
        }
    }

    func relayout() {
        guard let w = store.instance(id) else { return }
        window.setFrame(windowFrame(for: w), display: true)
    }
}

/// Widgets react to the very first click — Atoll is never the active app while you use them.
private final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Keeps one window per widget in sync with the store.
@MainActor
final class WidgetManager {
    static let shared = WidgetManager()

    private var controllers: [UUID: WidgetWindowController] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        WidgetStore.shared.$instances
            .combineLatest(Prefs.shared.$widgetsEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] list, enabled in self?.sync(enabled ? list : []) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.controllers.values.forEach { $0.relayout() } }
            .store(in: &cancellables)
    }

    private func sync(_ list: [WidgetInstance]) {
        let wanted = Set(list.map(\.id))
        for (id, c) in controllers where !wanted.contains(id) {
            controllers[id] = nil
            c.dismiss {}
        }
        var stagger: TimeInterval = 0
        for w in list {
            if let c = controllers[w.id] {
                c.update(w)
            } else {
                let c = WidgetWindowController(w)
                controllers[w.id] = c
                c.present(delay: stagger)
                stagger += 0.05
            }
        }
    }

    // MARK: Editing

    func beginEditing() {
        if !Prefs.shared.widgetsEnabled { Prefs.shared.widgetsEnabled = true }
        withAnimation(Motion.duo) { WidgetStore.shared.editing = true }
        WidgetGalleryWindow.shared.show()
    }

    func endEditing() {
        withAnimation(Motion.duo) { WidgetStore.shared.editing = false }
        WidgetGalleryWindow.shared.hide()
    }

    #if DEBUG
    /// Window IDs for own-window capture during verification.
    var debugWindowNumbers: [Int] { controllers.values.map { $0.window.windowNumber } }
    #endif
}
