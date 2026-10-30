import AppKit
import SwiftUI

// The island's SwiftUI content under Island Engine 2.0. The engine draws the silhouette, rim and light in Core
// Animation and scales these hosts' layers with the shape; SwiftUI only lays the content out, once per change, at
// its final size. Nothing here reads the animating size, so an animation frame costs SwiftUI nothing.

/// Hosting view that takes the first click even when Mac Flow isn't active, and only the clicks `accepts` allows:
/// the hosts fill the whole panel, one above the other, and each answers only where its content is on show.
final class IslandHostView<Content: View>: NSHostingView<Content> {
    var accepts: (NSPoint) -> Bool = { _ in true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard accepts(point) else { return nil }
        return super.hitTest(point)
    }
}

/// The closed island: the compact presentation of what's live (or nothing). Always built; hidden by the engine
/// (never removed) while the island is open, so closing never rebuilds it.
struct CompactRoot: View {
    var model: IslandModel
    @Namespace private var ns

    var body: some View {
        let _ = IslandTrace.countBody()
        let shown = model.isCompact
        let size = model.compactSize
        IslandPresentation(model: model, mode: .compact, size: size, alert: nil, primary: model.primary, ns: ns)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture { model.tap() }
            .modifier(IslandChrome(enabled: true, model: model))
            .environment(\.islandShowing, shown)
            .accessibilityHidden(!shown)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The second activity's bubble, behind the island.
struct BubbleRoot: View {
    var model: IslandModel
    /// Off once the engine's `LiquidBridge` draws the bridge.
    var drawsBridge: Bool

    var body: some View {
        let _ = IslandTrace.countBody()
        Group {
            if let secondary = model.secondary {
                IslandBubble(model: model, kind: secondary, drawsBridge: drawsBridge)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Everything shown in an open island: every place (kept built, as on the legacy surface), Search, alerts, drop
/// and mirror, each top-centred at its own size. While the island closes it keeps showing the last open state;
/// the engine hands over to the compact host as the shape lands.
struct OpenRoot: View {
    var model: IslandModel
    @Namespace private var ns

    /// What was last on show, held while the island closes. A plain reference: remembering it mustn't re-render.
    final class Memory { var held: IslandView.Shown? }
    @State private var memory = Memory()

    @State private var keyed = false
    @State private var unkeyWork: DispatchWorkItem?
    private var parkedOpacity: Double { keyed ? 0 : IslandView.parked }
    @State private var prewarm = true
    @State private var controlsBuilt = false
    @State private var searchBuilt = false
    @State private var brainBuilt = false
    @State private var planBuilt = false
    @State private var flowPlacesBuilt = false

    private func current(_ mode: IslandMode) -> IslandView.Shown {
        IslandView.Shown(key: model.presentationKey, mode: mode, size: model.spec(for: mode).size, alert: model.alert,
                         primary: model.primary, isOpen: model.isOpen)
    }

    var body: some View {
        let _ = IslandTrace.countBody()
        let mode = model.previewMode ?? model.mode
        let live = mode != .compact
        let display = live ? current(mode) : (memory.held ?? current(mode))
        let _ = live ? (memory.held = display) : ()
        let places: [IslandFocus] = {
            var p = model.tabs
            if case .expanded(let f) = display.mode, !p.contains(f) { p.append(f) }
            if controlsBuilt, !p.contains(.controls) { p.append(.controls) }
            if brainBuilt, !p.contains(.brain) { p.append(.brain) }
            if planBuilt, !p.contains(.plan) { p.append(.plan) }
            if flowPlacesBuilt { for f in [IslandFocus.rewind, .day, .sheet, .tasks] where !p.contains(f) { p.append(f) } }
            return p
        }()
        let inPlace: Bool = { if case .expanded(let f) = display.mode { return places.contains(f) }; return false }()
        let searching = display.mode == .search
        ZStack(alignment: .top) {
            if !inPlace && !(searching && searchBuilt) && display.mode != .compact {
                IslandPresentation(model: model, mode: display.mode, size: display.size,
                                   alert: display.alert, primary: display.primary, ns: ns)
                    .id(display.key)
                    .transition(.identity)
                    .environment(\.islandShowing, live)
                    .allowsHitTesting(live)
            }
            // Places are built once and only revealed, like tabs (see IslandView).
            ForEach(places, id: \.self) { place in
                let on = display.mode == .expanded(place)
                IslandPresentation(model: model, mode: .expanded(place), size: model.spec(for: .expanded(place)).size,
                                   alert: nil, primary: display.primary, ns: ns, parked: !on)
                    .opacity(on ? 1 : parkedOpacity)
                    .animation(nil, value: on)
                    .allowsHitTesting(on && live)
                    .accessibilityHidden(!on)
                    .environment(\.islandShowing, on && live)
            }
            if searchBuilt {
                IslandPresentation(model: model, mode: .search, size: model.spec(for: .search).size,
                                   alert: nil, primary: display.primary, ns: ns, parked: !searching)
                    .opacity(searching ? 1 : parkedOpacity)
                    .animation(nil, value: searching)
                    .allowsHitTesting(searching && live)
                    .accessibilityHidden(!searching)
                    .environment(\.islandShowing, searching && live)
            }
            if prewarm {
                ZStack(alignment: .top) {
                    ForEach([IslandMode.expanded(.activity(.nowPlaying)), .search], id: \.prewarmKey) { m in
                        IslandPresentation(model: model, mode: m, size: model.spec(for: m).size, alert: nil, primary: model.primary, ns: ns)
                            .frame(width: model.spec(for: m).size.width, height: model.spec(for: m).size.height)
                    }
                }
                .offset(y: model.notch.height + 140)
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        prewarm = false
                        buildWhenIdle()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { model.tap() }
        .modifier(IslandChrome(enabled: true, model: model))
        .accessibilityHidden(!live)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let w = note.object as? NSWindow, w === model.panel else { return }
            unkeyWork?.cancel()
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { keyed = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard let w = note.object as? NSWindow, w === model.panel else { return }
            unkeyWork?.cancel()
            let work = DispatchWorkItem {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { keyed = false }
            }
            unkeyWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
        .onChange(of: model.presentationKey) { _, _ in
            if model.mode == .expanded(.controls) { controlsBuilt = true }
            if model.mode == .expanded(.brain) { brainBuilt = true }
            if model.mode == .expanded(.plan) { planBuilt = true }
            if [IslandFocus.rewind, .day, .sheet, .tasks].contains(where: { model.mode == .expanded($0) }) { flowPlacesBuilt = true }
        }
    }

    /// Build the rest of the places while nothing is moving (retrying past alerts), so their first open is a reveal.
    private func buildWhenIdle() {
        guard !controlsBuilt else { return }
        if model.mode == .compact {
            controlsBuilt = true
            searchBuilt = true
            brainBuilt = true
            planBuilt = true
            flowPlacesBuilt = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { buildWhenIdle() }
        }
    }
}

extension IslandMode {
    var prewarmKey: String {
        switch self {
        case .expanded(.activity(let k)): k.rawValue
        case .search: "search"
        default: "other"
        }
    }
}
