import SwiftUI
import UniformTypeIdentifiers

/// The island: one black shape that grows out of the bezel and morphs between presentations,
/// plus the detached minimal bubble when two activities are live.
struct IslandView: View {
    /// The opacity of a place that's built but out of sight (see the places below).
    static let parked = ProcessInfo.processInfo.environment["ATOLL_PARK_ZERO"] != nil ? 0.0 : 0.001
    /// While the island has the keyboard (Search, Flow, the planner), parked places are fully hidden: becoming the key
    /// window redraws every text field and menu that's rendered — at 0.001, that was all of them, ~50 ms as Search opened.
    /// They're parked again a moment after the island lets go of the keyboard, once its close has finished.
    @State private var keyed = false
    @State private var unkeyWork: DispatchWorkItem?
    private var parkedOpacity: Double { keyed ? 0 : Self.parked }
    var model: IslandModel
    @Namespace private var ns
    @State private var sweep: CGFloat = 1
    /// What's drawn inside the shape. Usually the model's current state; while closing, the open content
    /// stays (shrinking with the shape) and is swapped only at the very end.
    @State private var shown: Shown?
    @State private var swapWork: DispatchWorkItem?
    /// For a moment after launch, the big presentations are drawn invisibly (outside the island, untouchable)
    /// so their layers, textures and text field exist before the first hover — which is then instant.
    @State private var prewarm = !RenderMode.snapshot
    /// Moving between places, the new one slides in from the side you're heading — no fade.
    @State private var slide: CGFloat = 0
    /// Controls stays built after the first visit (its menus are AppKit views: costly to make, cheap to keep).
    @State private var controlsBuilt = false
    @State private var searchBuilt = false
    @State private var brainBuilt = false
    /// The planner too: the morning's first open must be a reveal, never a build (text fields are costly to make).
    @State private var planBuilt = false
    /// Rewind and your day, likewise (they load their data when shown, so keeping them costs little).
    @State private var flowPlacesBuilt = false

    struct Shown {
        let key: String
        let mode: IslandMode
        let size: CGSize
        let alert: AlertState?
        let primary: ActivityKind?
        let isOpen: Bool
    }

    private func current() -> Shown {
        Shown(key: model.presentationKey, mode: model.mode, size: model.spec.size, alert: model.alert,
              primary: model.primary, isOpen: model.isOpen)
    }

    var body: some View {
        let display = shown ?? current()
        // The live state keeps its live size (hover, growing search results); a held state keeps its own.
        let size = display.key == model.presentationKey ? model.spec.size : display.size
        ZStack(alignment: .top) {
            if let secondary = model.secondary {
                bubble(secondary)
            }

            IslandSurface(spec: model.spec, notchHeight: model.notch.height, rim: model.rim,
                          rimStrength: model.rimStrength, sweep: sweep, elevated: model.isOpen) {
                let places: [IslandFocus] = {
                    var p = model.tabs
                    if controlsBuilt, !p.contains(.controls) { p.append(.controls) }
                    if brainBuilt, !p.contains(.brain) { p.append(.brain) }
                    if planBuilt, !p.contains(.plan) { p.append(.plan) }
                    if flowPlacesBuilt { for f in [IslandFocus.rewind, .day, .sheet] where !p.contains(f) { p.append(f) } }
                    return p
                }()
                let inPlace: Bool = { if case .expanded(let f) = display.mode { return places.contains(f) }; return false }()
                let searching = display.mode == .search
                ZStack(alignment: .top) {
                    if !inPlace && !(searching && searchBuilt) {
                        IslandPresentation(model: model, mode: display.mode, size: size,
                                           alert: display.alert, primary: display.primary, ns: ns)
                            .id(display.key)
                            .transition(.identity)
                    }
                    // The island's places (Home and each live activity's page) are built once and kept, like tabs:
                    // hovering or switching only reveals one. Building Home fresh — two dozen buttons, each with focus,
                    // tooltip and accessibility machinery — cost ~25 ms; an activity page ~15 ms. Now it's near zero.
                    ForEach(places, id: \.self) { place in
                        let on = display.mode == .expanded(place)
                        IslandPresentation(model: model, mode: .expanded(place),
                                           size: on ? size : model.spec(for: .expanded(place)).size,
                                           alert: nil, primary: display.primary, ns: ns, parked: !on)
                            // Hidden, not gone: at 0 opacity Core Animation drops a layer's pixels, so showing a place
                            // redrew all its text and controls on the main thread in the transition's first frame
                            // (40–50 ms). At 0.001 they stay rendered — and showing one is free.
                            .opacity(on ? 1 : parkedOpacity)
                            .animation(nil, value: on)
                            .allowsHitTesting(on)
                            .accessibilityHidden(!on)
                            .environment(\.islandShowing, on)
                    }
                    // Search is kept too (built a few seconds after launch): opening it is a reveal, not a build.
                    if searchBuilt {
                        IslandPresentation(model: model, mode: .search, size: searching ? size : model.spec(for: .search).size,
                                           alert: nil, primary: display.primary, ns: ns, parked: !searching)
                            .opacity(searching ? 1 : parkedOpacity)
                            .animation(nil, value: searching)
                            .allowsHitTesting(searching)
                            .accessibilityHidden(!searching)
                            .environment(\.islandShowing, searching)
                    }
                }
                .offset(x: slide)
            }
            .onTapGesture { tapped() }
            .modifier(IslandChrome(enabled: !RenderMode.snapshot, model: model))

            if prewarm {
                ZStack(alignment: .top) {
                    ForEach([IslandMode.expanded(.activity(.nowPlaying)), .search], id: \.prewarmID) { mode in
                        IslandPresentation(model: model, mode: mode, size: model.spec(for: mode).size, alert: nil, primary: model.primary, ns: ns)
                            .frame(width: model.spec(for: mode).size.width, height: model.spec(for: mode).size.height)
                    }
                }
                .offset(y: model.notch.height + 140)
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        prewarm = false
                        buildControlsWhenIdle()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            if [IslandFocus.rewind, .day, .sheet].contains(where: { model.mode == .expanded($0) }) { flowPlacesBuilt = true }
            present()
        }
    }

    /// Build Controls while nothing is moving (retrying past alerts), so its first open is only a reveal.
    private func buildControlsWhenIdle() {
        guard !controlsBuilt else { return }
        if model.mode == .compact {
            controlsBuilt = true
            searchBuilt = true
            brainBuilt = true
            planBuilt = true
            flowPlacesBuilt = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { buildControlsWhenIdle() }
        }
    }

    /// Opening or switching: the new content takes over on the first frame and grows with the shape.
    /// Closing: the open content shrinks with the shape and gives way only as it lands.
    private func present() {
        swapWork?.cancel()
        swapWork = nil
        let next = current()
        let closing = (shown?.isOpen ?? false) && !next.isOpen && !Access.reduceMotion && !RenderMode.snapshot
        if closing {
            let work = DispatchWorkItem { shown = current() }
            swapWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.closeSwap, execute: work)
        } else {
            let switching = (shown?.isOpen ?? false) && next.isOpen && model.switchDirection != 0 && !Access.reduceMotion
            shown = next
            if switching {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { slide = 34 * model.switchDirection }
                withAnimation(Motion.morph) { slide = 0 }
            }
        }
        playSweep()
    }

    /// One pass of light around the rim each time the island opens onto something new.
    private func playSweep() {
        guard model.isOpen, !Access.reduceMotion, !RenderMode.snapshot else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { sweep = 0 }
        withAnimation(.easeInOut(duration: 0.6).delay(0.05)) { sweep = 1 }
    }

    // MARK: Bubble (minimal presentation)

    /// The bubble melts into the island the moment it opens (or an alert grows): the shape widens straight across
    /// where it sits within two frames, and a bubble still drawn there (it used to take ~0.45 s to leave) read as the
    /// two colliding. It pulls back out only once the island has landed again.
    static let bubbleReturn: Double = 0.28

    private func bubble(_ kind: ActivityKind) -> some View {
        let d = model.bubbleDiameter
        let visible = model.showsBubble
        return ZStack(alignment: .top) {
            LiquidSplit(islandWidth: model.compactSize.width,
                        height: model.notch.height,
                        diameter: d,
                        restOffset: model.bubbleOffset,
                        progress: visible ? model.splitProgress : 0)
                // Blur + threshold cost scales with area: draw a strip under the bezel, not the whole panel
                // (the canvas used to fill all of it — ~16× the pixels — on every frame of a hover).
                .frame(height: model.notch.height + 12)
                .animation(visible ? Motion.split.delay(Self.bubbleReturn) : nil, value: visible)
            ActivityMinimal(kind: kind, diameter: d)
                .offset(x: model.bubbleOffset)
                .opacity(visible ? 1 : 0)
                .scaleEffect(visible ? 1 : 0.5)
                .animation(visible ? Motion.split.delay(Self.bubbleReturn + 0.1) : nil, value: visible)
                .onTapGesture { model.expandSecondary() }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows details")
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: Interaction

    private func tapped() {
        switch model.mode {
        case .compact:
            model.expand(sticky: true)
        case .alert:
            if case .trackChanged = model.alert?.kind {
                model.expand(.activity(.nowPlaying), sticky: true)
            } else if case .tip = model.alert?.kind {
                IslandManager.shared.advanceTour()
            } else {
                model.dismissAlert()
            }
        default:
            break
        }
    }
}

/// The black body, its depth and the rim light — everything but the content.
struct IslandSurface<Content: View>: View {
    let spec: IslandSpec
    let notchHeight: CGFloat
    let rim: RimStyle
    let rimStrength: Double
    var sweep: CGFloat = 1
    var elevated: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = IslandShape(shoulder: spec.shoulder, corner: spec.corner)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            // Colour lives inside the black as light from the content, never as an outline.
            if case .tint(let c) = rim {
                ContentLight(color: c, strength: 0.75)
                    .opacity(elevated ? 1 : 0)
                    .animation(.easeInOut(duration: 0.5), value: c)
            }
            content()
                .modifier(LiveIslandSize(size: spec.size))
        }
        // Top-pinned: content laid out for a larger state must hang from the top edge while the shape grows,
        // never drift vertically with it.
        .frame(width: spec.size.width, height: spec.size.height, alignment: .top)
        .clipShape(shape)
        .overlay(RimLight(spec: spec, notchHeight: notchHeight, style: rim, strength: rimStrength, sweep: sweep))
        .contentShape(shape)
    }
}

/// What's inside the island for one state. It's laid out once at its own size and then *scaled with the
/// shape* — so as the island grows, the content grows with it, as one object. No blur, no fade, no reflow.
struct IslandPresentation: View {
    var model: IslandModel
    let mode: IslandMode
    let size: CGSize
    let alert: AlertState?
    let primary: ActivityKind?
    let ns: Namespace.ID
    /// Built but out of sight: it holds still. Following the island's animated size (as a shown place must) made every
    /// parked place — and every text field and menu inside it — rescale on every frame of every animation.
    var parked = false

    /// The island's size as drawn this frame (see `LiveIslandSize`); nil outside the island.
    @Environment(\.islandLiveSize) private var live

    /// How much of its own size the content shows at a given moment of the shape's animation.
    /// The smaller of the two ratios: an opening island is wide long before it's tall, and zooming by width
    /// alone chopped the bottom off the content for the first third of the spring. Now the whole picture
    /// grows with the shape — and shrinks back into the notch as it closes — without ever being cut.
    /// No lower bound: a floor (it was 0.3) made the content larger than the shape at the very start of an
    /// open and the end of a close, and chopped it there.
    nonisolated static func zoom(live: CGSize, target: CGSize) -> CGFloat {
        guard target.width > 1, target.height > 1 else { return 1 }
        return min(1, max(0.01, min(live.width / target.width, live.height / target.height)))
    }

    var body: some View {
        let target = size
        // Parked: don't even read the live size, so the animation never reaches this subtree.
        let scale = parked ? 1 : (live.map { Self.zoom(live: $0, target: target) } ?? 1)
        Color.clear
            .overlay(alignment: .top) {
                content.frame(width: target.width, height: target.height, alignment: .top)
                    .scaleEffect(scale, anchor: .top)
            }
    }

    @ViewBuilder private var content: some View {
        if case .expanded(let focus) = mode, model.tabs.count > 1 {
            body(for: mode)
                .overlay(alignment: .topLeading) {
                    IslandTabs(model: model, current: focus)
                        .frame(height: model.notch.height)
                        .padding(.leading, IslandModel.expandedFlare + DS.Island.rowLeading)
                }
        } else {
            body(for: mode)
        }
    }

    @ViewBuilder private func body(for mode: IslandMode) -> some View {
        switch mode {
        case .compact:
            if let primary {
                ActivityCompact(kind: primary, model: model, ns: ns)
            } else {
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel("Mac Flow")
                    .accessibilityHint("Shows your player and apps")
                    .accessibilityAddTraits(.isButton)
            }
        case .expanded(.glance):
            HomeView(model: model)
        case .expanded(.controls):
            ControlsView(model: model)
        case .expanded(.brain):
            BrainPlace(model: model)
        case .expanded(.plan):
            PlanView(model: model)
        case .expanded(.rewind):
            RewindView(model: model)
        case .expanded(.day):
            DayArtView(model: model)
        case .expanded(.sheet):
            FlowSheet(model: model)
        case .expanded(.activity(let kind)):
            ActivityExpanded(kind: kind, model: model, ns: ns)
        case .alert:
            if let alert { AlertView(model: model, alert: alert, ns: ns) }
        case .search:
            SearchView(model: model)
        case .drop:
            DropView(model: model)
        case .mirror:
            MirrorView(model: model)
        }
    }
}

/// Island-wide context menu (AppKit-backed, so skipped in offscreen snapshots).
/// File drags aren't caught here: an island-wide drop destination makes SwiftUI re-reduce drop preferences across
/// the whole tree on every change (measured at ~7 ms a switch). IslandController sees a file drag coming and opens
/// the drop view, whose own targets take it.
private struct IslandChrome: ViewModifier {
    let enabled: Bool
    var model: IslandModel

    func body(content: Content) -> some View {
        if enabled {
            content
                .contextMenu {
                    Button("Search…") { model.openSearch() }
                    Button("Mirror") { model.openMirror() }
                    Divider()
                    Button("Settings…") { WindowManager.shared.showSettings() }
                    Button("Quit Mac Flow") { NSApp.terminate(nil) }
                }
        } else {
            content
        }
    }
}

private extension IslandMode {
    var prewarmID: String {
        switch self {
        case .expanded(.glance): "home"
        case .expanded(.controls): "controls"
        case .expanded(.brain): "brain"
        case .expanded(.activity(let k)): k.rawValue
        case .search: "search"
        default: "other"
        }
    }
}

// MARK: - Live size

private struct IslandLiveSizeKey: EnvironmentKey { static let defaultValue: CGSize? = nil }

extension EnvironmentValues {
    /// The island's size as it is drawn this frame, mid-animation included.
    var islandLiveSize: CGSize? {
        get { self[IslandLiveSizeKey.self] }
        set { self[IslandLiveSizeKey.self] = newValue }
    }
}

/// Hands the shape's animating size to the presentations inside it, frame by frame, so each one can scale to
/// fit the silhouette exactly. It's driven by the same value, in the same transaction, as the shape's own frame.
///
/// Reading the size back from layout (`visualEffect`'s proxy) wasn't enough: a presentation inserted mid-animation —
/// an alert, search, a page opened from the compact island — is laid out straight at its final size, so it read
/// "full size" while the shape was still small, and showed cut off (or empty) for the first frames.
struct LiveIslandSize: ViewModifier, Animatable {
    var size: CGSize

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size.width, size.height) }
        set { size = CGSize(width: newValue.first, height: newValue.second) }
    }

    func body(content: Content) -> some View {
        content.environment(\.islandLiveSize, size)
    }
}
