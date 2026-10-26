import AppKit
import SwiftUI
import Combine

/// One thing in the Dock Companion.
struct DockEntry: Identifiable {
    enum Icon {
        case file(String)
        case artwork(NSImage?, Color, playing: Bool)
        case appIcon(NSImage)
        case ring(Double, Color, String)
        case action(String, Color)
    }

    let id: String
    let title: String
    let icon: Icon
    var url: URL?
    let perform: () -> Void
}

@MainActor
final class DockBarModel: ObservableObject {
    @Published var shown = false
    @Published var edge: DockGeometry.Edge = .bottom
    @Published var pointer: CGPoint?
    var onAction: (() -> Void)?
}

struct DockBarView: View {
    @ObservedObject var model: DockBarModel
    @ObservedObject private var recent = RecentFiles.shared
    @ObservedObject private var np = NowPlayingModel.shared
    @ObservedObject private var timer = FocusTimer.shared
    @ObservedObject private var cal = CalendarModel.shared

    static let iconSize: CGFloat = 44

    private var vertical: Bool { model.edge != .bottom }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            section(now)
            section(continueItems)
            section(goItems)
            section(doItems, last: true)
        }
        .padding(8)
        .modifier(DockGlass(radius: 24))
        .coordinateSpace(name: "dockbar")
        .onContinuousHover(coordinateSpace: .named("dockbar")) { phase in
            switch phase {
            case .active(let p): model.pointer = p
            case .ended: withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.pointer = nil }
            }
        }
        .modifier(DockPresence(shown: model.shown, edge: model.edge))
        .padding(headroom)
        .environment(\.colorScheme, .dark)
    }

    /// Room for magnified icons and their labels, on the side away from the Dock.
    private var headroom: EdgeInsets {
        switch model.edge {
        case .bottom: EdgeInsets(top: 62, leading: 24, bottom: 4, trailing: 24)
        case .left: EdgeInsets(top: 24, leading: 4, bottom: 24, trailing: 220)
        case .right: EdgeInsets(top: 24, leading: 220, bottom: 24, trailing: 4)
        }
    }

    @ViewBuilder private func section(_ entries: [DockEntry], last: Bool = false) -> some View {
        if !entries.isEmpty {
            ForEach(entries) { DockItemView(entry: $0, model: model) }
            if !last {
                Group {
                    if vertical {
                        Rectangle().fill(Color.white.opacity(0.22)).frame(width: 34, height: 1).padding(.vertical, 6)
                    } else {
                        Rectangle().fill(Color.white.opacity(0.22)).frame(width: 1, height: 34).padding(.horizontal, 6)
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: Sections

    /// Now — whatever is live.
    private var now: [DockEntry] {
        var list: [DockEntry] = []
        if np.mode == .app, let app = np.otherApp, let icon = app.icon {
            list.append(DockEntry(id: "now.app", title: "\(app.name) — Playing audio", icon: .appIcon(icon)) { app.activate() })
        } else if np.mode == .track {
            list.append(DockEntry(id: "now.track", title: "\(np.title) — \(np.artist)", icon: .artwork(np.artwork, np.accent, playing: np.isPlaying)) {
                NowPlayingModel.shared.playPause()
            })
        }
        if timer.isActive {
            list.append(DockEntry(id: "now.timer", title: "\(timer.label) · \(timer.clock) left", icon: .ring(1 - timer.progress, DS.Palette.orange, timer.clock)) {
                FocusTimer.shared.togglePause()
            })
        }
        if let e = cal.events.first(where: { $0.meetingURL != nil && !$0.isAllDay && ($0.isNow || $0.start.timeIntervalSinceNow < 10 * 60) }) {
            list.append(DockEntry(id: "now.meeting", title: "Join \(e.title)", icon: .action("video.fill", DS.Palette.green)) {
                CalendarModel.shared.open(e)
            })
        }
        return list
    }

    /// Continue — files you used most recently.
    private var continueItems: [DockEntry] {
        recent.items.prefix(5).map { hit in
            let url = URL(fileURLWithPath: hit.id)
            return DockEntry(id: "file.\(hit.id)", title: hit.name, icon: .file(hit.id), url: url) { NSWorkspace.shared.open(url) }
        }
    }

    /// Go — the folders you open most.
    private var goItems: [DockEntry] {
        let fm = FileManager.default
        let folders: [(String, URL?)] = [
            ("Downloads", fm.urls(for: .downloadsDirectory, in: .userDomainMask).first),
            ("Desktop", fm.urls(for: .desktopDirectory, in: .userDomainMask).first),
            ("Documents", fm.urls(for: .documentDirectory, in: .userDomainMask).first),
            ("Applications", URL(fileURLWithPath: "/Applications")),
        ]
        return folders.compactMap { name, url in
            guard let url else { return nil }
            return DockEntry(id: "go.\(name)", title: name, icon: .file(url.path), url: url) { NSWorkspace.shared.open(url) }
        }
    }

    /// Do — Atoll's own actions.
    private var doItems: [DockEntry] {
        [
            DockEntry(id: "do.search", title: "Search", icon: .action("magnifyingglass", Color(red: 0.36, green: 0.4, blue: 0.48))) {
                IslandManager.shared.openSearch()
            },
            DockEntry(id: "do.shelf", title: "Shelf", icon: .action("tray.full.fill", DS.Palette.indigo)) {
                IslandManager.shared.openShelf()
            },
            DockEntry(id: "do.screenshot", title: "Take Screenshot", icon: .action("camera.viewfinder", Color(red: 0.42, green: 0.42, blue: 0.46))) {
                SystemActions.screenshot()
            },
            DockEntry(id: "do.standby", title: "StandBy", icon: .action("clock.fill", Color(red: 0.95, green: 0.42, blue: 0.1))) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { StandByController.shared.enter(manual: true) }
            },
            DockEntry(id: "do.widgets", title: "Edit Widgets", icon: .action("square.grid.2x2.fill", DS.Palette.blue)) {
                WidgetManager.shared.beginEditing()
            },
        ]
    }
}

/// The bar rises off the Dock with the duo treatment.
private struct DockPresence: ViewModifier {
    let shown: Bool
    let edge: DockGeometry.Edge
    func body(content: Content) -> some View {
        let travel: CGSize = switch edge {
        case .bottom: CGSize(width: 0, height: 14)
        case .left: CGSize(width: -14, height: 0)
        case .right: CGSize(width: 14, height: 0)
        }
        let anchor: UnitPoint = switch edge {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
        if Access.reduceMotion {
            content.opacity(shown ? 1 : 0).animation(.easeInOut(duration: 0.2), value: shown)
        } else {
            content
                .opacity(shown ? 1 : 0)
                .blur(radius: shown ? 0 : 12)
                .scaleEffect(shown ? 1 : 0.94, anchor: anchor)
                .offset(shown ? .zero : travel)
                .animation(Motion.duo, value: shown)
        }
    }
}

/// An icon that magnifies with distance from the pointer, like the Dock's own.
private struct DockItemView: View {
    let entry: DockEntry
    @ObservedObject var model: DockBarModel

    private let size = DockBarView.iconSize
    private var vertical: Bool { model.edge != .bottom }
    private var anchor: UnitPoint {
        switch model.edge {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private func magnification(_ frame: CGRect) -> CGFloat {
        guard let p = model.pointer, !Access.reduceMotion else { return 1 }
        let d = vertical ? abs(p.y - frame.midY) : abs(p.x - frame.midX)
        return 1 + 0.42 * exp(-(d * d) / (2 * 46 * 46))
    }

    private func hovered(_ frame: CGRect) -> Bool {
        guard let p = model.pointer else { return false }
        return vertical ? abs(p.y - frame.midY) < frame.height / 2 : abs(p.x - frame.midX) < frame.width / 2
    }

    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .named("dockbar"))
            let s = magnification(f)
            Button {
                Haptics.confirm()
                entry.perform()
                model.onAction?()
            } label: {
                DockIcon(icon: entry.icon, size: size)
                    .scaleEffect(s, anchor: anchor)
            }
            .buttonStyle(PressStyle(scale: 0.92))
            .frame(width: g.size.width, height: g.size.height)
            .overlay(alignment: labelAlignment) {
                if hovered(f) {
                    DockLabel(text: entry.title)
                        .fixedSize()
                        .offset(labelOffset(s))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: size, height: size)
        .padding(vertical ? .vertical : .horizontal, 4)
        .zIndex(model.pointer.map { _ in 1 } ?? 0)
        .modifier(FileDrag(url: entry.url))
        .contextMenu {
            if let url = entry.url {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Add to Shelf") { ShelfModel.shared.add(urls: [url]) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { entry.perform() }
    }

    private var labelAlignment: Alignment {
        switch model.edge {
        case .bottom: .top
        case .left: .trailing
        case .right: .leading
        }
    }

    private func labelOffset(_ s: CGFloat) -> CGSize {
        let grow = size * (s - 1)
        switch model.edge {
        case .bottom: return CGSize(width: 0, height: -(grow + 34))
        case .left: return CGSize(width: grow + 14 + 60, height: 0)
        case .right: return CGSize(width: -(grow + 14 + 60), height: 0)
        }
    }
}

private struct FileDrag: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url {
            content.onDrag { NSItemProvider(object: url as NSURL) }
        } else {
            content
        }
    }
}

/// The Dock's own name tag: a dark rounded label above the hovered icon.
private struct DockLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color(white: 0.12).opacity(0.92)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .frame(maxWidth: 280)
    }
}

struct DockIcon: View {
    let icon: DockEntry.Icon
    let size: CGFloat
    @ObservedObject private var recent = RecentFiles.shared

    var body: some View {
        switch icon {
        case .file(let path):
            if let thumb = recent.thumbnails[path] {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.92, height: size * 0.92)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .frame(width: size, height: size)
            } else {
                IconImage(image: IconCache.file(path), size: size)
            }
        case .appIcon(let image):
            IconImage(image: image, size: size)
        case .artwork(let image, let accent, let playing):
            Artwork(image: image, size: size * 0.86, radius: size * 0.2, accent: accent)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.2, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.4, height: size * 0.4)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .offset(x: size * 0.06, y: size * 0.06)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: size, height: size)
        case .ring(let progress, let tint, let text):
            ZStack {
                Circle().fill(Color.black.opacity(0.55))
                ProgressRing(progress: progress, tint: tint, lineWidth: 3.5).padding(3)
                Text(text).font(.system(size: size * 0.2, weight: .semibold).monospacedDigit()).foregroundStyle(.white).minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
            }
            .frame(width: size * 0.92, height: size * 0.92)
            .frame(width: size, height: size)
        case .action(let symbol, let tint):
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 0.86, height: size * 0.86)
                .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(tint.gradient))
                .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .frame(width: size, height: size)
        }
    }
}

/// The handle: a small glass pill that appears above the Dock while the pointer is on it.
/// Hover it (or click) and the companion rises.
@MainActor
final class DockHandleModel: ObservableObject {
    @Published var shown = false
    @Published var hot = false
}

struct DockHandleView: View {
    @ObservedObject var model: DockHandleModel
    var onOpen: () -> Void

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(model.hot ? 0.95 : 0.7))
                .frame(width: model.hot ? 72 : 46, height: model.hot ? 7 : 5)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .overlay(alignment: .top) {
                    Text("Dock Companion")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Color(white: 0.12).opacity(0.9)))
                        .offset(y: -26)
                        .opacity(model.hot ? 1 : 0)
                        .fixedSize()
                }
        }
        .frame(width: 260, height: 26)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .frame(width: 260, height: 60, alignment: .bottom)
        .opacity(model.shown ? 1 : 0)
        .scaleEffect(model.shown ? 1 : 0.6)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.shown)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: model.hot)
        .accessibilityElement()
        .accessibilityLabel("Show Dock Companion")
        .accessibilityAddTraits(.isButton)
    }
}

/// Shows the companion from its handle above the Dock (or from a menu), and hides it when you're done.
@MainActor
final class DockBarController {
    static let shared = DockBarController()

    private let panel = DockPanel()
    private let model = DockBarModel()
    private let handlePanel = DockPanel()
    private let handleModel = DockHandleModel()
    private var geometry = DockGeometry.current()
    private var moveMonitor: Any?
    private var clickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var showCancellables = Set<AnyCancellable>()
    private var handleHideWork: DispatchWorkItem?
    private var handleOpenWork: DispatchWorkItem?
    private var outsideSince: Date?
    private var shownAt = Date()
    private var pointerVisited = false
    private var manual = false
    private var poll: Timer?
    private(set) var isShown = false
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        model.onAction = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.hide() }
        }
        Prefs.shared.$dockCompanion
            .receive(on: RunLoop.main)
            .sink { [weak self] on in on ? self?.installMonitor() : self?.teardown() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.geometry = DockGeometry.current() }
            .store(in: &cancellables)
    }

    /// The bar and handle are built when first needed and released when the companion is off: built, they
    /// observe the timer, the player and recent files, and would re-render on every change even when unused.
    private func ensureHosts() {
        guard panel.contentView == nil else { return }
        let host = FirstClickHostingView(rootView: DockBarView(model: model))
        // The window is sized from the content's intrinsic size (see `layout()`), so the host must report it.
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        let handleHost = FirstClickHostingView(rootView: DockHandleView(model: handleModel) { [weak self] in self?.show(manual: false) })
        handleHost.sizingOptions = []
        handlePanel.contentView = handleHost
    }

    private func releaseHostsIfUnused() {
        guard !isShown, !Prefs.shared.dockCompanion else { return }
        panel.contentView = nil
        handlePanel.contentView = nil
    }

    private func installMonitor() {
        guard moveMonitor == nil else { return }
        ensureHosts()
        geometry = DockGeometry.current()
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.track(NSEvent.mouseLocation) }
        }
    }

    private func teardown() {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        moveMonitor = nil
        hideHandle(after: 0)
        hide()
    }

    // MARK: Handle

    private var handleFrame: CGRect { geometry.panelFrame(size: CGSize(width: 260, height: 60), gap: geometry.handleGap) }

    /// Only the pill's strip counts as "on the handle" — the label above it is decoration.
    private var handleHotZone: CGRect {
        let f = handleFrame
        return CGRect(x: f.minX, y: f.minY, width: f.width, height: 26).insetBy(dx: -10, dy: -10)
    }

    /// While the pointer is on the Dock (or on the handle), the handle is there to reach for.
    private func track(_ p: NSPoint) {
        guard !isShown, !StandByController.shared.isShowing else { return }
        let onDock = geometry.band.contains(p)
        let reach = handleHotZone
        let onHandle = reach.contains(p)
        if onDock || onHandle {
            showHandle()
        } else if handleModel.shown {
            hideHandle(after: 0.5)
        }
        // Resting on the handle opens the companion.
        if onHandle != handleModel.hot { handleModel.hot = onHandle }
        if onHandle {
            if handleOpenWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, reach.contains(NSEvent.mouseLocation) else { return }
                    self.show(manual: false)
                }
                handleOpenWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            }
        } else {
            handleOpenWork?.cancel()
            handleOpenWork = nil
        }
    }

    private func showHandle() {
        handleHideWork?.cancel()
        handleHideWork = nil
        guard !handleModel.shown else { return }
        geometry = DockGeometry.current()
        handlePanel.setFrame(handleFrame, display: false)
        handlePanel.orderFrontRegardless()
        handleModel.shown = true
    }

    private func hideHandle(after delay: TimeInterval) {
        guard handleHideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.handleHideWork = nil
            self.handleModel.shown = false
            self.handleModel.hot = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !self.handleModel.shown { self.handlePanel.orderOut(nil) }
            }
        }
        handleHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Companion

    func toggle() { isShown ? hide() : show(manual: true) }

    /// `manual`: opened from a menu or Settings — it stays until you use it or click elsewhere.
    func show(manual: Bool = true) {
        handleOpenWork?.cancel()
        handleOpenWork = nil
        guard !isShown else { return }
        ensureHosts()
        geometry = DockGeometry.current()
        RecentFiles.shared.start()
        model.edge = geometry.edge
        model.pointer = nil
        isShown = true
        self.manual = manual
        pointerVisited = !manual
        shownAt = Date()
        outsideSince = nil
        hideHandle(after: 0)
        layout()
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.model.shown = true }
        Haptics.snap()
        startPolling()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
        // Keep the size right as sections come and go.
        // Published values arrive just before they change, so measure a moment later.
        RecentFiles.shared.$items.dropFirst().merge(with: FocusTimer.shared.$phase.map { _ in [] }.dropFirst())
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &showCancellables)
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        showCancellables.removeAll()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        poll?.invalidate()
        poll = nil
        model.shown = false
        model.pointer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
            self.releaseHostsIfUnused()
        }
    }

    /// Measures the bar from its current content (a fresh measurement, never a stale layout),
    /// then rises from just above the Dock so the pointer coming up from the handle lands on it.
    private func layout() {
        let sizer = NSHostingController(rootView: DockBarView(model: model))
        let size = sizer.sizeThatFits(in: CGSize(width: geometry.screenFrame.width, height: 400))
        panel.setFrame(geometry.panelFrame(size: size, gap: 2), display: true)
    }

    private func startPolling() {
        poll?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLeave() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    /// Leaves 0.6 s after the pointer is away from both the bar and the Dock. Opened from a menu,
    /// it waits until you've visited it (or 8 s pass untouched).
    private func checkLeave() {
        let p = NSEvent.mouseLocation
        let barRect = panel.frame.insetBy(dx: 12, dy: 12)
        let inBar = barRect.contains(p)
        if inBar { pointerVisited = true }
        if manual && !pointerVisited {
            if Date().timeIntervalSince(shownAt) > 8 { hide() }
            return
        }
        let nearDock = geometry.band.contains(p) || handleHotZone.contains(p)
        if inBar || nearDock || NSEvent.pressedMouseButtons != 0 {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.6 { hide() }
        } else {
            outsideSince = Date()
        }
    }

    #if DEBUG
    var debugWindowNumber: Int { panel.windowNumber }
    var debugHandleWindowNumber: Int { handlePanel.windowNumber }
    var debugOnScreen: Bool { panel.isVisible && panel.occlusionState.contains(.visible) }
    func debugShowHandle(hot: Bool) { showHandle(); handleModel.hot = hot }
    #endif
}
