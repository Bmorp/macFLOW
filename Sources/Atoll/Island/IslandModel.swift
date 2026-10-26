import SwiftUI
import Combine
import Observation

enum IslandFocus: Hashable {
    case activity(ActivityKind)
    case glance
    /// Sound and display controls.
    case controls
    /// Talking to Atoll.
    case brain
    /// Planning the day.
    case plan
    /// Scrubbing back through today.
    case rewind
    /// The day, drawn.
    case day
    /// The pulled-down sheet: your day, what's playing, Flow.
    case sheet
}

enum IslandMode: Equatable {
    case compact
    case expanded(IslandFocus)
    case alert
    case search
    case drop
    case mirror
}

/// Transient moments that need attention, shown as a wide compact or a brief expanded presentation.
enum IslandAlert: Equatable {
    case volume(level: Double, muted: Bool)
    case brightness(Double)
    case charging(Int)
    case lowBattery(Int)
    case device(BluetoothMonitor.Device)
    case privacy(camera: Bool, app: String?)
    case downloadFinished(URL)
    case timerFinished(String)
    case meetingSoon(CalendarModel.Event, minutes: Int)
    case trackChanged
    case message(symbol: String, text: String, tint: Color)
    /// A Claude session finished something that took a while.
    case claudeFinished(id: String, name: String, duration: TimeInterval)
    /// A Claude session is waiting for you.
    case claudeNeedsYou(id: String, name: String, folder: String)
    /// The Brain has a suggestion, or a question.
    case brainSuggestion(BrainSuggestion)
    case brainQuestion(BrainQuestion)
    /// Flow Lens: next steps for something copied or dropped.
    case lens(LensItem)
    /// A card to recall, at a quiet moment.
    case learn(StudyCard)
    /// One step of the first-run tour, shown in the island itself.
    case tip(symbol: String, title: String, detail: String, step: Int, total: Int)
    /// A new version of Mac Flow is out.
    case update(version: String)

    var isWide: Bool {
        switch self {
        case .volume, .brightness, .charging, .lowBattery, .privacy, .message: true
        case .device(let d): !d.hasBattery
        default: false
        }
    }

    var bodyHeight: CGFloat {
        switch self {
        case .device: 78
        case .downloadFinished: 66
        case .timerFinished: 72
        case .meetingSoon: 70
        case .trackChanged: 62
        default: 0
        }
    }

    /// Flow's own: a suggestion or a question, backed by its inbox.
    var isFlow: Bool {
        switch self {
        case .brainSuggestion, .brainQuestion: true
        default: false
        }
    }

    var flowID: UUID? {
        switch self {
        case .brainSuggestion(let s): s.id
        case .brainQuestion(let q): q.id
        default: nil
        }
    }

    /// Alerts of one family update in place (holding a volume key) instead of re-animating.
    func sameFamily(_ other: IslandAlert) -> Bool {
        switch (self, other) {
        case (.volume, .volume), (.message, .message), (.charging, .charging): true
        default: false
        }
    }
}

struct AlertState: Equatable, Identifiable {
    var id = UUID()
    var kind: IslandAlert
}

enum DropTarget: Equatable { case shelf, airdrop, flow }

/// State machine and geometry for one island (one per screen).
///
/// Observable per property: a view re-renders only when something it actually read changes. With every place
/// (Home, each activity page) kept built, an `ObservableObject` re-rendered all of them — two dozen buttons each —
/// on every hover, tick and alert; now a hover re-renders the shape and nothing else.
@MainActor
@Observable
final class IslandModel {
    private(set) var mode: IslandMode = .compact
    private(set) var alert: AlertState?
    private(set) var hovering = false
    private(set) var live: [ActivityKind] = []
    private(set) var splitProgress: CGFloat = 0
    var dropTarget: DropTarget?
    private(set) var focusSearchTick = 0
    private(set) var inlineVolume = false
    /// Bumped when a size that depends on another model changes (Home's Claude strip, search results),
    /// so the shape — which reads it through `spec` — re-measures with the change's animation.
    private(set) var layoutRevision = 0
    @ObservationIgnored var wantsSearchFocus = false
    @ObservationIgnored private var inlineVolumeWork: DispatchWorkItem?

    /// Briefly swaps the waveform for a level meter while the person scrolls to change volume.
    func flashInlineVolume() {
        inlineVolumeWork?.cancel()
        if !inlineVolume { withAnimation(.snappy) { inlineVolume = true } }
        let work = DispatchWorkItem { [weak self] in withAnimation(.smooth) { self?.inlineVolume = false } }
        inlineVolumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    let geometry: NotchGeometry
    let isPrimary: Bool
    @ObservationIgnored weak var panel: NotchPanel?
    @ObservationIgnored private(set) var sticky = false

    @ObservationIgnored private var alertWork: DispatchWorkItem?
    @ObservationIgnored private var interruptedFlow: IslandAlert?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry, isPrimary: Bool) {
        self.geometry = geometry
        self.isPrimary = isPrimary
        live = ActivityCenter.shared.live
        splitProgress = live.count > 1 ? 1 : 0

        ActivityCenter.shared.$live
            .receive(on: RunLoop.main)
            .sink { [weak self] list in self?.liveChanged(list) }
            .store(in: &cancellables)

        // The home grows a Claude strip when you have sessions.
        ClaudeSessions.shared.$sessions
            .map(\.isEmpty)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.mode == .expanded(.glance) else { return }
                withAnimation(Motion.morph) { self.layoutRevision &+= 1 }
            }
            .store(in: &cancellables)

        // A call or meeting row grows the companion strip (and notes change what it shows).
        Publishers.Merge3(MeetingCompanion.shared.$state.map { _ in () }, CalendarModel.shared.$events.map { _ in () },
                          Prefs.shared.$meetingNotes.map { _ in () })
            .receive(on: RunLoop.main)
            .map { MeetingCompanion.shared.showsStrip }
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, case .expanded(.activity(let k)) = self.mode, k == .call || k == .meeting else { return }
                withAnimation(Motion.morph) { self.layoutRevision &+= 1 }
            }
            .store(in: &cancellables)

        // Home grows Now's card for the moment — and shrinks when it passes.
        NowModel.shared.$moment
            .map { m -> String in
                guard let m else { return "" }
                if case .flow(let item) = m { return "\(m.key)\(item.isQuestion)" }
                return "moment"   // every other moment is one row: switching between them keeps the height
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.mode == .expanded(.glance) else { return }
                withAnimation(Motion.morph) { self.layoutRevision &+= 1 }
            }
            .store(in: &cancellables)

        // Resize only when the results actually change height — not on every reassignment.
        SearchModel.shared.$sections
            .receive(on: RunLoop.main)
            .map { _ in SearchModel.shared.contentHeight }
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.mode == .search else { return }
                withAnimation(Motion.morph) { self.layoutRevision &+= 1 }
            }
            .store(in: &cancellables)
    }

    // MARK: - Derived state

    var primary: ActivityKind? { live.first }
    var secondary: ActivityKind? { live.dropFirst().first }
    var showsBubble: Bool { mode == .compact && secondary != nil }

    var focus: IslandFocus? {
        if case .expanded(let f) = mode { return f }
        return nil
    }

    /// Identity of what's on show. A new key means: old content leaves, new content arrives staggered.
    var presentationKey: String {
        switch mode {
        case .compact: "compact.\(primary?.rawValue ?? "idle")"
        case .expanded(.glance): "glance"
        case .expanded(.controls): "controls"
        case .expanded(.brain): "brain"
        case .expanded(.plan): "plan"
        case .expanded(.rewind): "rewind"
        case .expanded(.day): "day"
        case .expanded(.sheet): "sheet"
        case .expanded(.activity(let k)): "activity.\(k.rawValue)"
        case .alert: "alert.\(alert?.id.uuidString ?? "")"
        case .search: "search"
        case .drop: "drop"
        case .mirror: "mirror"
        }
    }

    /// Whether the island is open (rim light on, shoulders wide).
    var isOpen: Bool {
        switch mode {
        case .compact: false
        case .alert: !(alert?.kind.isWide ?? true)
        default: true
        }
    }

    /// The rim light's colour: whatever is on show.
    var rim: RimStyle {
        switch mode {
        // Search lights itself from the selection (SearchView); no fixed rim colour.
        case .search: return .tint(.clear)
        case .drop: return .tint(DS.Palette.cyan)
        case .mirror: return .tint(.white)
        case .expanded(.glance), .expanded(.activity(.nowPlaying)):
            // With a cover, the art field is the light; otherwise a quiet glow from the accent.
            let np = NowPlayingModel.shared
            if np.mode == .track, np.palette != nil { return .tint(.clear) }
            return .tint(np.mode == .track ? np.accent : Color(red: 0.55, green: 0.66, blue: 1))
        case .expanded(.activity(let k)): return .tint(k.tint)
        case .expanded(.controls): return .tint(Color(red: 0.55, green: 0.66, blue: 1))
        case .expanded(.brain), .expanded(.plan), .expanded(.rewind), .expanded(.day), .expanded(.sheet): return .tint(.clear)
        case .compact: return .tint(primary?.tint ?? .white)
        case .alert:
            switch alert?.kind {
            case .charging: return .tint(DS.Palette.green)
            case .lowBattery: return .tint(DS.Palette.red)
            case .privacy(let camera, _): return .tint(camera ? DS.Palette.green : DS.Palette.orange)
            case .downloadFinished: return .tint(DS.Palette.blue)
            case .timerFinished: return .tint(DS.Palette.orange)
            case .meetingSoon(let e, _): return .tint(e.color)
            case .trackChanged: return .tint(NowPlayingModel.shared.accent)
            case .message(_, _, let tint): return .tint(tint)
            case .tip: return .tint(DS.Palette.blue)
            case .claudeFinished, .claudeNeedsYou: return .tint(ClaudeSessions.tint)
            case .brainSuggestion, .brainQuestion, .lens, .learn: return .tint(BrainStyle.tint)
            default: return .tint(.white)
            }
        }
    }

    /// How bright the rim is: off when closed (so the island disappears into the notch), soft for wide alerts.
    var rimStrength: Double {
        if isOpen { return Access.increaseContrast ? 1 : 0.85 }
        if mode == .alert { return 0.45 }
        return 0
    }

    // MARK: - Geometry

    var notch: CGSize { geometry.notchSize }
    /// Shoulder radius when closed — close to the hardware notch's own fillet.
    static let compactFlare: CGFloat = DS.Island.compactShoulder
    /// Shoulder radius when open.
    static let expandedFlare: CGFloat = DS.Island.openShoulder
    static let wideAlertWing: CGFloat = 118
    static let dropRowHeight: CGFloat = 88
    static let mirrorRowHeight: CGFloat = 236

    func wing(for kind: ActivityKind?) -> CGFloat {
        kind?.compactWing(notchHeight: notch.height) ?? 0
    }

    private var compactCorner: CGFloat { geometry.hasNotch ? 10 : notch.height / 2 }

    var compactSize: CGSize {
        var w = notch.width + Self.compactFlare * 2 + wing(for: primary) * 2
        var h = notch.height
        if hovering && mode == .compact {
            w += 10
            h += 3
        }
        return CGSize(width: w, height: h)
    }

    var bubbleDiameter: CGFloat { notch.height }

    /// Horizontal offset of the bubble's centre from the island's centre (resting, not hovering).
    var bubbleOffset: CGFloat {
        let island = notch.width + Self.compactFlare * 2 + wing(for: primary) * 2
        return island / 2 + DS.Size.bubbleGap + 4 + bubbleDiameter / 2
    }

    /// Frame width of an open island, shoulders included.
    var expandedWidth: CGFloat { max(DS.Size.rowWidth, notch.width + 250) + Self.expandedFlare * 2 }

    func rowHeight(_ focus: IslandFocus) -> CGFloat {
        switch focus {
        case .glance: DS.Size.homeHeight + (HomeView.showsClaude ? HomeView.claudeStripHeight : 0) + HomeView.momentHeight
        case .controls: ControlsView.height
        case .brain: BrainPlace.height
        case .plan: PlanView.height
        case .rewind: RewindView.height
        case .day: DayArtView.height
        case .sheet: FlowSheet.height
        case .activity(let k): k.rowHeight
        }
    }

    func expandedSize(_ focus: IslandFocus) -> CGSize {
        _ = layoutRevision
        return switch focus {
        case .glance:
            CGSize(width: max(DS.Size.homeWidth, notch.width + 380) + Self.expandedFlare * 2,
                   height: notch.height + DS.Size.homeHeight + (HomeView.showsClaude ? HomeView.claudeStripHeight : 0) + HomeView.momentHeight)
        case .controls:
            CGSize(width: max(DS.Size.homeWidth, notch.width + 380) + Self.expandedFlare * 2,
                   height: notch.height + ControlsView.height)
        case .brain:
            CGSize(width: max(DS.Size.homeWidth, notch.width + 380) + Self.expandedFlare * 2,
                   height: notch.height + BrainPlace.height)
        case .plan:
            CGSize(width: max(DS.Size.searchWidth, notch.width + 360) + Self.expandedFlare * 2,
                   height: notch.height + PlanView.height)
        case .rewind:
            CGSize(width: max(DS.Size.searchWidth, notch.width + 360) + Self.expandedFlare * 2,
                   height: notch.height + RewindView.height)
        case .day:
            CGSize(width: max(DS.Size.homeWidth, notch.width + 380) + Self.expandedFlare * 2,
                   height: notch.height + DayArtView.height)
        case .sheet:
            CGSize(width: max(FlowSheet.width, notch.width + 420) + Self.expandedFlare * 2,
                   height: notch.height + FlowSheet.height)
        case .activity:
            CGSize(width: expandedWidth, height: notch.height + rowHeight(focus))
        }
    }

    var alertSize: CGSize {
        guard let a = alert?.kind else { return compactSize }
        if a.isWide {
            return CGSize(width: notch.width + Self.compactFlare * 2 + Self.wideAlertWing * 2, height: notch.height)
        }
        if case .brainQuestion = a { return CGSize(width: expandedWidth, height: notch.height + 102) }
        if case .lens = a { return CGSize(width: max(DS.Size.searchWidth, notch.width + 360) + Self.expandedFlare * 2, height: notch.height + 72) }
        if case .learn = a { return CGSize(width: max(DS.Size.searchWidth, notch.width + 360) + Self.expandedFlare * 2, height: notch.height + 168) }
        return CGSize(width: expandedWidth, height: notch.height + DS.Size.rowHeight)
    }

    var searchSize: CGSize {
        _ = layoutRevision
        return CGSize(width: max(DS.Size.searchWidth, notch.width + 360) + Self.expandedFlare * 2,
               height: notch.height + SearchModel.shared.contentHeight + 8)
    }

    var dropSize: CGSize { CGSize(width: expandedWidth, height: notch.height + Self.dropRowHeight) }
    var mirrorSize: CGSize { CGSize(width: expandedWidth, height: notch.height + Self.mirrorRowHeight) }

    var currentSize: CGSize { spec.size }

    var spec: IslandSpec { spec(for: mode) }

    /// The silhouette for a state: size, shoulder and corner morph together.
    func spec(for mode: IslandMode) -> IslandSpec {
        let open = IslandSpec(size: .zero, shoulder: Self.expandedFlare, corner: DS.Island.openCorner)
        switch mode {
        case .compact:
            return IslandSpec(size: compactSize, shoulder: Self.compactFlare, corner: compactCorner)
        case .alert:
            if alert?.kind.isWide ?? true {
                return IslandSpec(size: alertSize, shoulder: Self.compactFlare + 2, corner: 14)
            }
            return IslandSpec(size: alertSize, shoulder: open.shoulder, corner: open.corner)
        case .expanded(let f):
            return IslandSpec(size: expandedSize(f), shoulder: open.shoulder, corner: open.corner)
        case .search:
            return IslandSpec(size: searchSize, shoulder: open.shoulder, corner: 26)
        case .drop:
            return IslandSpec(size: dropSize, shoulder: open.shoulder, corner: open.corner)
        case .mirror:
            return IslandSpec(size: mirrorSize, shoulder: open.shoulder, corner: open.corner)
        }
    }

    static func maxCanvas(for geo: NotchGeometry) -> CGSize {
        CGSize(width: max(max(DS.Size.searchWidth, geo.notchSize.width + 360) + DS.Island.openShoulder * 2 + 120,
                          max(FlowSheet.width, geo.notchSize.width + 420) + DS.Island.openShoulder * 2 + 60),
               height: max(geo.notchSize.height + SearchModel.maxContentHeight + 64, geo.notchSize.height + FlowSheet.height + 60))
    }

    // MARK: - Activities

    private func liveChanged(_ list: [ActivityKind]) {
        guard list != live else { return }
        let hadSecondary = live.count > 1
        live = list
        let hasSecondary = list.count > 1
        if hasSecondary != hadSecondary {
            withAnimation(Motion.split) { splitProgress = hasSecondary ? 1 : 0 }
        }
        // The activity on show ended: fall back gracefully.
        if case .expanded(.activity(let k)) = mode, !list.contains(k) {
            withAnimation(Motion.morph) { mode = .expanded(.glance) }
        }
    }

    // MARK: - Transitions

    func expand(_ focus: IslandFocus? = nil, sticky makeSticky: Bool = false) {
        alertWork?.cancel()
        interruptedFlow = nil
        if makeSticky { sticky = true }
        // Music lives in the home (with your apps); anything else that's live opens its own row.
        // Flow's star opens Home too, where its waiting card is.
        var target = focus ?? primary.flatMap { $0 == .nowPlaying || $0 == .flow ? nil : .activity($0) } ?? .glance
        if target == .activity(.flow) { target = .glance }
        guard mode != .expanded(target) else { return }
        switchDirection = 0
        withAnimation(mode == .compact || mode == .alert ? Motion.open : Motion.morph) {
            mode = .expanded(target)
            hovering = false
            alert = nil
        }
        // Home shows the player too: both re-sync it (after the opening spring, never inside it).
        if target == .glance || target == .activity(.nowPlaying) { NowPlayingModel.shared.refreshAfterOpening() }
    }

    func expandSecondary() {
        guard let s = secondary else { return }
        expand(.activity(s))
    }

    /// The island's places, in tab order: Home, then each live activity that has its own page.
    /// Music lives in Home, so it isn't a tab of its own.
    var tabs: [IslandFocus] {
        // Controls is a tab while you're in it, so you can step back to Home or an activity.
        // Flow's waiting items live on Home, so they aren't a tab either.
        [.glance] + ([IslandFocus.sheet, .plan, .rewind, .day].filter { mode == .expanded($0) }) + (mode == .expanded(.brain) ? [.brain] : [])
            + (mode == .expanded(.controls) ? [.controls] : [])
            + live.filter { $0 != .nowPlaying && $0 != .flow }.map { .activity($0) }
    }

    /// Which way the last switch went (−1 left, +1 right), so content can slide with it.
    @ObservationIgnored private(set) var switchDirection: CGFloat = 0

    /// Go to one of the island's places.
    func select(_ focus: IslandFocus) {
        guard case .expanded(let current) = mode, current != focus else { return }
        let fixed: [IslandFocus] = [.glance, .sheet, .plan, .rewind, .day, .brain, .controls]
        let order = fixed + tabs.filter { !fixed.contains($0) }
        if let a = order.firstIndex(of: current), let b = order.firstIndex(of: focus) {
            switchDirection = b > a ? 1 : -1
        } else {
            switchDirection = 0
        }
        Haptics.snap()
        withAnimation(Motion.morph) { mode = .expanded(focus) }
    }

    /// Two-finger swipe between the island's places while it's open.
    func cycleFocus(_ delta: Int) {
        guard case .expanded(let f) = mode else { return }
        let items = tabs
        guard items.count > 1, let i = items.firstIndex(of: f) ?? items.firstIndex(of: .glance) else { return }
        let next = items[(i + delta + items.count) % items.count]
        select(next)
    }

    func collapse() {
        guard mode != .compact else { return }
        alertWork?.cancel()
        sticky = false
        wantsSearchFocus = false
        if mode == .mirror { CameraMirror.shared.stop() }
        if mode == .search {
            // Reset after the island has closed, never while it's still shrinking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard self?.mode != .search else { return }
                SearchModel.shared.reset()
            }
        }
        // Hand keyboard focus back first: it wakes the input system, and the spring's clock shouldn't be running yet.
        relinquishKey()
        withAnimation(Motion.collapse) {
            mode = .compact
            alert = nil
            dropTarget = nil
        }
    }

    func makeSticky() { sticky = true }
    func setSticky(_ on: Bool) { sticky = on }

    /// Open Atoll's conversation, from anywhere: from the closed island it opens straight there.
    func openBrain() {
        if case .expanded = mode {
            select(.brain)
        } else {
            expand(.brain, sticky: true)
        }
    }

    /// Plan your day: from the closed island it opens straight there, and stays until you're done.
    func openPlan() { open(.plan) }

    /// One of Flow's places (the planner, Rewind, your day): opened straight from anywhere, kept open until you leave.
    func open(_ focus: IslandFocus) {
        if case .expanded = mode {
            sticky = true
            select(focus)
        } else {
            expand(focus, sticky: true)
        }
    }

    func setHovering(_ h: Bool) {
        guard h != hovering, mode == .compact || !h else { return }
        withAnimation(Motion.hover) { hovering = h }
    }

    func openSearch() {
        sticky = true
        wantsSearchFocus = true
        panel?.makeKey()
        withAnimation(Motion.expand) {
            mode = .search
            hovering = false
            alert = nil
        }
        focusSearchTick += 1
    }

    func openDrop() {
        guard mode != .drop else { return }
        withAnimation(Motion.expand) {
            mode = .drop
            hovering = false
            alert = nil
        }
    }

    func openMirror() {
        sticky = true
        withAnimation(Motion.expand) {
            mode = .mirror
            alert = nil
        }
        CameraMirror.shared.start()
    }

    // MARK: - Alerts

    func showAlert(_ kind: IslandAlert, duration: TimeInterval) {
        // Never interrupt something the person is doing.
        guard mode == .compact || mode == .alert else {
            if case let .message(_, text, _) = kind, mode == .search { SearchModel.shared.confirm(text) }
            return
        }
        alertWork?.cancel()
        // A passing alert (volume, a track, a message) over one of Flow's: Flow's comes back after it.
        if mode == .alert, let current = alert, current.kind.isFlow, !kind.isFlow { interruptedFlow = current.kind }
        if kind.isFlow { interruptedFlow = nil }
        if mode == .alert, let current = alert, current.kind.sameFamily(kind) {
            alert = AlertState(id: current.id, kind: kind)
        } else {
            withAnimation(Motion.expand) {
                alert = AlertState(kind: kind)
                mode = .alert
                hovering = false
            }
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .alert else { return }
            if let flow = self.interruptedFlow, self.alert?.kind.isFlow == false, let id = flow.flowID, FlowInbox.shared.contains(id) {
                self.interruptedFlow = nil
                self.showAlert(flow, duration: 12)
                return
            }
            self.interruptedFlow = nil
            withAnimation(Motion.collapse) {
                self.mode = .compact
                self.alert = nil
            }
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismissAlert() {
        alertWork?.cancel()
        interruptedFlow = nil
        guard mode == .alert else { return }
        withAnimation(Motion.collapse) {
            mode = .compact
            alert = nil
        }
    }

    /// Keep an alert on screen while the pointer rests on it (`accessibility.md`: minimize time-boxed elements).
    func holdAlert() { alertWork?.cancel() }

    func releaseAlert(after delay: TimeInterval = 1.2) {
        guard mode == .alert else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismissAlert() }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Drops

    func handleDrop(_ providers: [NSItemProvider], target: DropTarget) -> Bool {
        switch target {
        case .shelf:
            let ok = ShelfModel.shared.add(providers: providers) { urls in
                guard !urls.isEmpty else { return }
                Haptics.confirm()
            }
            if ok {
                withAnimation(Motion.collapse) {
                    mode = .compact
                    dropTarget = nil
                }
            }
            return ok
        case .airdrop:
            ShelfModel.loadURLs(providers) { urls in
                Haptics.confirm()
                ShelfModel.airDrop(urls: urls)
            }
            withAnimation(Motion.collapse) {
                mode = .compact
                dropTarget = nil
            }
            return true
        case .flow:
            ShelfModel.loadURLs(providers) { urls in
                Haptics.confirm()
                LensModel.shared.understand(urls)
            }
            withAnimation(Motion.collapse) {
                mode = .compact
                dropTarget = nil
            }
            return true
        }
    }

    #if DEBUG
    func debugSetMode(_ m: IslandMode, alert a: IslandAlert? = nil) {
        alert = a.map { AlertState(kind: $0) }
        mode = m
    }
    #endif

    // MARK: - Keyboard focus

    /// Hand keyboard focus back to whatever app the person was using.
    func relinquishKey() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }
}
