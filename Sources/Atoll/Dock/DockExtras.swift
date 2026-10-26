import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Dock drop tray

enum DockDropTarget: String, CaseIterable, Identifiable {
    case shelf, airdrop, share, compress
    var id: String { rawValue }

    var title: String {
        switch self {
        case .shelf: "Hold on Shelf"
        case .airdrop: "AirDrop"
        case .share: "Share"
        case .compress: "Compress"
        }
    }

    var symbol: String {
        switch self {
        case .shelf: "tray.and.arrow.down.fill"
        case .airdrop: "dot.radiowaves.left.and.right"
        case .share: "square.and.arrow.up"
        case .compress: "doc.zipper"
        }
    }

    var tint: Color {
        switch self {
        case .shelf: DS.Palette.cyan
        case .airdrop: DS.Palette.blue
        case .share: DS.Palette.green
        case .compress: DS.Palette.orange
        }
    }
}

@MainActor
final class DockDropModel: ObservableObject {
    @Published var shown = false
    @Published var edge: DockGeometry.Edge = .bottom
    var onDrop: ((DockDropTarget, [NSItemProvider]) -> Bool)?
}

struct DockDropTrayView: View {
    @ObservedObject var model: DockDropModel

    var body: some View {
        let layout = model.edge == .bottom ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
        layout {
            ForEach(DockDropTarget.allCases) { t in
                DockDropTile(target: t) { model.onDrop?(t, $0) ?? false }
            }
        }
        .padding(8)
        .modifier(DockGlass(radius: 26))
        .opacity(model.shown ? 1 : 0)
        .blur(radius: model.shown || Access.reduceMotion ? 0 : 12)
        .scaleEffect(model.shown || Access.reduceMotion ? 1 : 0.94, anchor: .bottom)
        .animation(Motion.duo, value: model.shown)
        .padding(12)
        .environment(\.colorScheme, .dark)
    }
}

private struct DockDropTile: View {
    let target: DockDropTarget
    let perform: ([NSItemProvider]) -> Bool
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: target.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(targeted ? .white : target.tint)
                .symbolEffect(.bounce, value: targeted)
            Text(target.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 108, height: 76)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(targeted ? target.tint.opacity(0.42) : Color.white.opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(targeted ? target.tint : Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: targeted ? [] : [5, 4]))
        )
        .scaleEffect(targeted ? 1.05 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
        .fileDropTarget(isTargeted: $targeted, perform: perform)
        .onChange(of: targeted) { _, on in if on { Haptics.snap() } }
        .accessibilityElement(children: .combine)
    }
}

/// Raises a tray of destinations when you drag files toward the Dock.
@MainActor
final class DockDropController: NSObject, NSSharingServicePickerDelegate {
    static let shared = DockDropController()

    private let panel = DockPanel()
    private let model = DockDropModel()
    private var geometry = DockGeometry.current()
    private var monitors: [Any] = []
    private var poll: Timer?
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var sharing = false
    private(set) var isShown = false
    private var cancellables = Set<AnyCancellable>()

    func start() {
        let host = FirstClickHostingView(rootView: DockDropTrayView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        model.onDrop = { [weak self] target, providers in self?.drop(target, providers) ?? false }
        Prefs.shared.$dockDropZone
            .receive(on: RunLoop.main)
            .sink { [weak self] on in on ? self?.install() : self?.uninstall() }
            .store(in: &cancellables)
    }

    private func install() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(m) }
    }

    private func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        poll?.invalidate()
        poll = nil
        hide()
    }

    /// Drag sessions don't reliably reach event monitors, so watch lightly while the button is down.
    /// Every click on the Mac lands here: it only notes the drag pasteboard. The Dock's geometry (a read of the
    /// Dock's preferences) is looked up once a file drag has actually started.
    private var geometryFresh = false

    private func mouseDown() {
        baseline = NSPasteboard(name: .drag).changeCount
        geometryFresh = false
        poll?.invalidate()
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func tick() {
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        guard buttonDown else {
            poll?.invalidate()
            poll = nil
            if !sharing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.hideUnlessSharing() } }
            return
        }
        guard !isShown else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != baseline, pb.types?.contains(.fileURL) ?? false else { return }
        if !geometryFresh {
            geometry = DockGeometry.current()
            geometryFresh = true
        }
        if geometry.dropApproachZone.contains(NSEvent.mouseLocation) { show() }
    }

    private func show() {
        isShown = true
        model.edge = geometry.edge
        guard let host = panel.contentView else { return }
        panel.setFrame(geometry.panelFrame(size: host.fittingSize, gap: 0), display: true)
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.model.shown = true }
    }

    private func hideUnlessSharing() { if !sharing { hide() } }

    private func hide() {
        guard isShown else { return }
        isShown = false
        model.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
        }
    }

    private func drop(_ target: DockDropTarget, _ providers: [NSItemProvider]) -> Bool {
        Haptics.confirm()
        switch target {
        case .shelf:
            return ShelfModel.shared.add(providers: providers) { urls in
                guard !urls.isEmpty else { return }
                IslandManager.shared.confirm("tray.full.fill", urls.count == 1 ? "Added to Shelf" : "Added \(urls.count) files to Shelf", tint: DS.Palette.cyan)
            }
        case .airdrop:
            ShelfModel.loadURLs(providers) { urls in ShelfModel.airDrop(urls: urls) }
        case .share:
            sharing = true
            ShelfModel.loadURLs(providers) { [weak self] urls in
                guard let self, let view = self.panel.contentView, !urls.isEmpty else { self?.sharing = false; return }
                let picker = NSSharingServicePicker(items: urls)
                picker.delegate = self
                let p = view.convert(self.panel.mouseLocationOutsideOfEventStream, from: nil)
                picker.show(relativeTo: NSRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2), of: view, preferredEdge: .maxY)
            }
        case .compress:
            ShelfModel.loadURLs(providers) { urls in
                let items = urls.map { ShelfItem(path: $0.path, added: Date()) }
                ShelfModel.shared.zip(items) { out in
                    guard out != nil else { return }
                    Haptics.confirm()
                    IslandManager.shared.confirm("doc.zipper", "Compressed to Shelf", tint: DS.Palette.orange)
                }
            }
        }
        return true
    }

    #if DEBUG
    var debugWindowNumber: Int { panel.windowNumber }
    func debugShowTray() { geometry = DockGeometry.current(); show() }
    func debugHideTray() { hide() }
    #endif

    nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            sharing = false
            hide()
        }
    }
}

// MARK: - Live Dock icon

/// The app icon, carrying whatever is live: a timer ring or the current album art.
struct DockTileView: View {
    @ObservedObject private var timer = FocusTimer.shared
    @ObservedObject private var np = NowPlayingModel.shared
    let size: CGSize

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
            if timer.isActive {
                ZStack {
                    Circle().fill(Color.black.opacity(0.82))
                    Circle().trim(from: 0, to: max(0.01, 1 - timer.progress))
                        .stroke(DS.Palette.orange, style: StrokeStyle(lineWidth: size.width * 0.05, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(size.width * 0.05)
                    Text("\(Int((timer.remaining / 60).rounded(.up)))")
                        .font(.system(size: size.width * 0.2, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .frame(width: size.width * 0.5, height: size.width * 0.5)
            } else if np.mode == .track, np.isPlaying {
                Artwork(image: np.artwork, size: size.width * 0.46, radius: size.width * 0.08, accent: np.accent)
                    .overlay(RoundedRectangle(cornerRadius: size.width * 0.08, style: .continuous).strokeBorder(.white, lineWidth: size.width * 0.02))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

@MainActor
final class DockTileController {
    static let shared = DockTileController()
    private var cancellables = Set<AnyCancellable>()
    private var liveCancellables = Set<AnyCancellable>()

    func start() {
        Prefs.shared.$showInDock
            .receive(on: RunLoop.main)
            .sink { [weak self] show in self?.apply(show) }
            .store(in: &cancellables)
    }

    private func apply(_ show: Bool) {
        liveCancellables.removeAll()
        let tile = NSApp.dockTile
        guard show else {
            tile.contentView = nil
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
            return
        }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        let size = tile.size
        let host = NSHostingView(rootView: DockTileView(size: size))
        host.frame = NSRect(origin: .zero, size: size)
        tile.contentView = host
        tile.display()
        // Redraw when something live changes — at most once a second.
        FocusTimer.shared.objectWillChange.map { _ in () }
            .merge(with: NowPlayingModel.shared.objectWillChange.map { _ in () })
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { DispatchQueue.main.async { NSApp.dockTile.display() } }
            .store(in: &liveCancellables)
    }

    /// The Dock icon's menu: everything Atoll can do, one click away.
    func menu() -> NSMenu {
        let menu = NSMenu()
        let np = NowPlayingModel.shared
        if np.mode != .idle {
            let title = np.mode == .app ? (np.otherApp?.name ?? "Now Playing") : "\(np.title) — \(np.artist)"
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(ClosureMenuItem(np.isPlaying ? "Pause" : "Play") { NowPlayingModel.shared.playPause() })
            menu.addItem(ClosureMenuItem("Next Track") { NowPlayingModel.shared.next() })
            menu.addItem(.separator())
        }
        if FocusTimer.shared.isActive {
            menu.addItem(ClosureMenuItem(FocusTimer.shared.phase == .paused ? "Resume Timer" : "Pause Timer") { FocusTimer.shared.togglePause() })
            menu.addItem(ClosureMenuItem("Stop Timer") { FocusTimer.shared.stop() })
        } else {
            menu.addItem(ClosureMenuItem("Start 25-Minute Focus Timer") { FocusTimer.shared.start(minutes: 25, label: "Focus") })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Search") { IslandManager.shared.openSearch() })
        menu.addItem(ClosureMenuItem("Show Shelf") { IslandManager.shared.openShelf() })
        menu.addItem(ClosureMenuItem("Enter StandBy") { StandByController.shared.enter(manual: true) })
        menu.addItem(ClosureMenuItem("Edit Widgets…") { WidgetManager.shared.beginEditing() })
        return menu
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}
