import SwiftUI
import Combine

/// Now: the one thing that matters at this moment, at the top of Home. The island stops being a set of places you
/// visit and starts following your day — Flow's question, then the meeting about to start, the room you're working
/// in, the block that's next, the morning's plan, the evening's picture of the day. One slot, one card, in that
/// order of importance; nothing at all when nothing needs you.
@MainActor
final class NowModel: ObservableObject {
    static let shared = NowModel()

    enum Moment: Equatable {
        /// Something Flow suggested or asked, waiting.
        case flow(FlowInbox.Item)
        /// A meeting starting within ten minutes, or under way.
        case meeting(CalendarModel.Event)
        /// A focus block running (a room, usually).
        case focus(String)
        /// The plan's next block, within 45 minutes.
        case next(PlanItem)
        /// Reading a page in your browser: Flow can summarize, explain or save it.
        case reading(String, browser: String)
        /// Morning, and the day isn't planned yet.
        case plan
        /// The workday's over: the day, drawn.
        case evening

        var key: String {
            switch self {
            case .flow(let i): "flow.\(i.id)"
            case .meeting(let e): "meeting.\(e.id)"
            case .focus(let l): "focus.\(l)"
            case .next(let p): "next.\(p.id)"
            case .reading(let t, _): "reading.\(t)"
            case .plan: "plan"
            case .evening: "evening"
            }
        }
    }

    @Published private(set) var moment: Moment?
    private var dismissed: Set<String> = []
    private var dismissedDay = DayPlan.key()
    private var cancellables = Set<AnyCancellable>()
    private var clock: Timer?

    init() {
        let triggers: [AnyPublisher<Void, Never>] = [
            FlowInbox.shared.$items.map { _ in () }.eraseToAnyPublisher(),
            FocusTimer.shared.$phase.map { _ in () }.eraseToAnyPublisher(),
            FocusTimer.shared.$label.map { _ in () }.eraseToAnyPublisher(),
            CalendarModel.shared.$events.map { _ in () }.eraseToAnyPublisher(),
            PlanStore.shared.$plan.map { _ in () }.eraseToAnyPublisher(),
            Prefs.shared.$brainSuggestions.map { _ in () }.eraseToAnyPublisher(),
            WorkContext.shared.$title.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            WorkContext.shared.$bundle.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.recompute() }
            .store(in: &cancellables)
        // Moments come with time (a meeting draws near, evening arrives), not only with events.
        let t = Timer(timeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { NowModel.shared.recompute() } }
        t.tolerance = 8
        RunLoop.main.add(t, forMode: .common)
        clock = t
        recompute()
    }

    /// Not now, for the rest of today.
    func dismiss(_ m: Moment) {
        dismissed.insert(m.key)
        recompute()
    }

    func recompute() {
        #if DEBUG
        if pinned { return }
        #endif
        if dismissedDay != DayPlan.key() { dismissed = []; dismissedDay = DayPlan.key() }
        let next = Self.resolve(now: PlanClock.now, dismissed: dismissed)
        if next != moment { withAnimation(Motion.morph) { moment = next } }
    }

    /// The order of importance.
    static func resolve(now: Date, dismissed: Set<String>) -> Moment? {
        func ok(_ m: Moment) -> Moment? { dismissed.contains(m.key) ? nil : m }
        if Prefs.shared.brainSuggestions, let item = FlowInbox.shared.top, let m = ok(.flow(item)) { return m }
        if let e = CalendarModel.shared.events.first(where: { !$0.isAllDay && ($0.isNow || (0...600).contains($0.start.timeIntervalSince(now))) }),
           let m = ok(.meeting(e)) { return m }
        let timer = FocusTimer.shared
        if timer.phase != .idle, let m = ok(.focus(timer.label)) { return m }
        let plan = PlanStore.shared.plan
        if plan.started, let p = plan.items.filter({ $0.kind == .focus && !$0.done && (0...45 * 60).contains($0.start.timeIntervalSince(now)) })
            .min(by: { $0.start < $1.start }), let m = ok(.next(p)) { return m }
        let ctx = WorkContext.shared
        if let b = BrowserReader.browser(for: ctx.bundle), !ctx.title.isEmpty, ctx.title.count > 3,
           let m = ok(.reading(ctx.title, browser: b.name)) { return m }
        let hour = Calendar.current.component(.hour, from: now)
        if Prefs.shared.planMorning, hour >= 5, hour < 12, !plan.started, !plan.skipped, let m = ok(.plan) { return m }
        if hour >= Prefs.shared.planEndHour, hour < 23, InsightModel.shared.insight.activeToday > 1800, let m = ok(.evening) { return m }
        return nil
    }

    /// How much room the slot takes on Home (card and the gap under it).
    var height: CGFloat {
        guard let moment else { return 0 }
        if case .flow(let item) = moment { return FlowInboxCard.height(item) }
        return MomentRow.height + FlowInboxCard.gap
    }

    #if DEBUG
    private var pinned = false
    func debugSet(_ m: Moment?) { pinned = true; moment = m }
    /// Back to resolving moments for real (after a pinned one).
    func debugRelease() { pinned = false; recompute() }
    #endif
}

// MARK: - The slot

/// Now, on Home: Flow's card when Flow's waiting, otherwise the moment's own row.
struct NowSlot: View {
    let moment: NowModel.Moment
    var onLeave: () -> Void
    @ObservedObject private var inbox = FlowInbox.shared

    var body: some View {
        switch moment {
        case .flow(let item): FlowInboxCard(item: item, count: inbox.items.count, onLeave: onLeave)
        default: MomentRow(moment: moment, onLeave: onLeave)
        }
    }
}

/// One moment, as a single row: its mark, what it is, when, and the one thing to do about it.
struct MomentRow: View {
    let moment: NowModel.Moment
    var onLeave: () -> Void
    @ObservedObject private var timer = FocusTimer.shared
    @ObservedObject private var rooms = RoomStore.shared
    @Environment(\.islandShowing) private var showing
    @State private var arrived = RenderMode.snapshot

    static let height: CGFloat = 58

    var body: some View {
        HStack(spacing: 12) {
            mark
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Kit.body).foregroundStyle(DS.Ink.primary).lineLimit(1)
                detailLine.font(DS.Kit.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(FlowCardBackground(tint: tint))
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived ? 0 : -8)
        .onChange(of: showing, initial: true) { _, on in settle(on) }
        .onChange(of: moment.key) { _, _ in
            guard showing, !Access.reduceMotion, !RenderMode.snapshot else { return }
            arrived = false
            settle(true)
        }
        .accessibilityElement(children: .contain)
    }

    private func settle(_ on: Bool) {
        guard !RenderMode.snapshot else { return }
        if on {
            withAnimation(Access.reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.8).delay(0.1)) { arrived = true }
        } else {
            arrived = false
        }
    }

    // MARK: Per moment

    private var tint: Color {
        switch moment {
        case .flow: BrainStyle.tint
        case .meeting(let e): e.color
        case .focus: DS.Palette.orange
        case .next: BrainStyle.tint
        case .reading: DS.Palette.blue
        case .plan: PlanView.morning
        case .evening: (InsightModel.shared.insight.modes.first?.mode ?? .other).tint
        }
    }

    @ViewBuilder private var mark: some View {
        switch moment {
        case .focus:
            ZStack {
                Circle().stroke(DS.Palette.orange.opacity(0.25), lineWidth: 3)
                Circle().trim(from: 0, to: max(0.02, 1 - timer.progress))
                    .stroke(DS.Palette.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: timer.progress)
                Image(systemName: timer.phase == .paused ? "pause.fill" : "scope").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Palette.orange)
            }
            .frame(width: 30, height: 30)
            .padding(1)
        default:
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: tint.opacity(0.4), radius: 6, y: 1)
                .accessibilityHidden(true)
        }
    }

    private var symbol: String {
        switch moment {
        case .meeting(let e): e.meetingURL == nil ? "person.2.fill" : "video.fill"
        case .next: "scope"
        case .reading: "doc.text.magnifyingglass"
        case .plan: "sun.horizon.fill"
        case .evening: "circle.circle"
        default: "sparkles"
        }
    }

    private var title: String {
        switch moment {
        case .meeting(let e): e.title
        case .focus(let label): label
        case .next(let p): "Next: \(p.title)"
        case .reading(let t, _): t
        case .plan: "Plan your day"
        case .evening: "Your day, drawn"
        case .flow: ""
        }
    }

    @ViewBuilder private var detailLine: some View {
        switch moment {
        case .meeting(let e):
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let mins = Int((e.isNow ? e.end : e.start).timeIntervalSince(ctx.date) / 60)
                Text(e.isNow ? "\(max(0, mins)) min left" + (e.notes.map { " · " + $0.replacingOccurrences(of: "\n", with: " · ") } ?? "")
                             : "In \(max(1, mins + 1)) min · \(CalendarModel.timeRange(e))")
            }
        case .focus(let label):
            Text("\(timer.clock) left" + (timer.phase == .paused ? " · paused" : "") + (rooms.room(for: label).map { " · " + $0.summary } ?? ""))
        case .next(let p):
            let mins = max(1, Int(p.start.timeIntervalSince(PlanClock.now) / 60))
            Text("\(p.start.formatted(date: .omitted, time: .shortened))–\(p.end.formatted(date: .omitted, time: .shortened)) · in \(mins) min"
                 + (rooms.room(for: p.title).map { " · " + $0.summary } ?? ""))
        case .reading(_, let browser):
            Text("Reading in \(browser)")
        case .plan:
            let drafted = PlanStore.shared.priorities.filter { !$0.title.isEmpty }.count
            let meetings = PlanStore.shared.calendarItems.filter { $0.end > PlanClock.now }.count
            Text([drafted > 0 ? "Flow drafted \(drafted) priorit\(drafted == 1 ? "y" : "ies")" : "Your top three, fitted around your meetings",
                  meetings > 0 ? "\(meetings) meeting\(meetings == 1 ? "" : "s") today" : nil].compactMap { $0 }.joined(separator: " · "))
        case .evening:
            let i = InsightModel.shared.insight
            Text(i.activeToday < 60 ? "See how today went"
                 : "\(DayArtView.length(i.deepToday)) of focus · \(DayArtView.length(i.activeToday)) at your Mac")
        case .flow:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch moment {
        case .meeting(let e):
            if e.meetingURL != nil {
                Pill(title: "Join", symbol: "video.fill") { CalendarModel.shared.open(e); onLeave() }
            } else if MeetingCompanion.shared.state == .idle, Prefs.shared.meetingNotes, e.isNow {
                FlowOptionButton(title: "Take Notes") { MeetingCompanion.shared.offer() }
            }
        case .focus:
            Ghost(symbol: "stop.fill", label: "End Block", size: 10, tint: DS.Ink.tertiary, hit: 26) { timer.stop() }
            Pill(title: timer.phase == .paused ? "Resume" : "Pause") { timer.togglePause() }
        case .next(let p):
            Ghost(symbol: "xmark", label: "Not Now", size: 10, tint: DS.Ink.tertiary, hit: 26) { NowModel.shared.dismiss(moment) }
            Pill(title: rooms.room(for: p.title) == nil ? "Start Focus" : "Set the Room") {
                RoomStore.shared.setRoom(title: p.title, minutes: p.minutes)
                onLeave()
            }
        case .reading:
            Ghost(symbol: "xmark", label: "Not Now", size: 10, tint: DS.Ink.tertiary, hit: 26) { NowModel.shared.dismiss(moment) }
            FlowOptionButton(title: "Save to Learn") { onLeave(); PageActions.perform(.learn) }.fixedSize()
            Pill(title: "Summarize") { PageActions.perform(.summarize) }
        case .plan:
            Ghost(symbol: "xmark", label: "Not Today", size: 10, tint: DS.Ink.tertiary, hit: 26) { NowModel.shared.dismiss(moment) }
            Pill(title: "Plan") { IslandManager.shared.openPlan() }
        case .evening:
            Ghost(symbol: "xmark", label: "Hide", size: 10, tint: DS.Ink.tertiary, hit: 26) { NowModel.shared.dismiss(moment) }
            Pill(title: "See Your Day") { IslandManager.shared.primary?.model.open(.day) }
        case .flow:
            EmptyView()
        }
    }
}
