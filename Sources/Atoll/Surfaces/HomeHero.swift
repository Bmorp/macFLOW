import SwiftUI
import Combine

// Home's hero and its Today strip. "What matters now": one large card for the one thing, and under it a calm list of
// what's next on your list. The hero is chosen by state, never by habit (HomeHeroKind.resolve).

/// What Home's hero is about, in the order of what matters now: Flow waiting on you, the task you're working on, a
/// running focus timer, a meeting under way or about to start, Now's other moments (the next block, a page you're
/// reading, the morning plan, the evening), your music, a meeting later today, and when none of that: nothing.
enum HomeHeroKind: Equatable {
    case flow(FlowInbox.Item)
    case task(UUID)
    case timer(String)
    case meeting(CalendarModel.Event)
    case moment(NowModel.Moment)
    case music
    case idle

    /// A meeting this close (or under way) outranks everything but Flow and your own focus.
    static let meetingHorizon: TimeInterval = 60 * 60

    static func resolve(flow: FlowInbox.Item?, activeTask: UUID?, timer: String?, meetings: [CalendarModel.Event],
                        moment: NowModel.Moment?, music: Bool, now: Date = Date()) -> HomeHeroKind {
        if let flow { return .flow(flow) }
        if let activeTask { return .task(activeTask) }
        if let timer { return .timer(timer) }
        let upcoming = meetings.filter { !$0.isAllDay && $0.end > now }.sorted { $0.start < $1.start }
        if let soon = upcoming.first(where: { $0.start <= now || $0.start.timeIntervalSince(now) <= meetingHorizon }) { return .meeting(soon) }
        if let moment {
            switch moment {
            case .next, .reading, .plan, .evening: return .moment(moment)
            case .flow, .meeting, .focus: break
            }
        }
        if music { return .music }
        if let later = upcoming.first(where: { Calendar.current.isDate($0.start, inSameDayAs: now) }) { return .meeting(later) }
        return .idle
    }
}

// MARK: - Hero

/// The hero's readings, as (figure, unit): what the big number says.
enum HeroReading {
    /// Time spent: 42 sec, 12 min, 1:04 h.
    static func elapsed(_ seconds: TimeInterval) -> (String, String) {
        let s = max(0, Int(seconds))
        if s < 60 { return ("\(s)", "sec") }
        if s < 3600 { return ("\(s / 60)", "min") }
        return (String(format: "%d:%02d", s / 3600, (s % 3600) / 60), "h")
    }

    /// Time to go: 6 min, and for a meeting hours off, 1:20 h.
    static func minutes(_ m: Int) -> (String, String) {
        m < 60 ? ("\(m)", "min") : (String(format: "%d:%02d", m / 60, m % 60), "h")
    }
}

/// The hero slot: draws the kind Home resolved on a Prism card.
struct HomeHero: View {
    let kind: HomeHeroKind
    var model: IslandModel

    var body: some View {
        Group {
            switch kind {
            case .flow(let item): FlowHero(item: item, onLeave: { model.collapse() })
            case .task: TaskHero(active: TaskStore.shared.active)
            case .timer(let label): TimerHero(label: label)
            case .meeting(let e): MeetingHero(event: e, model: model)
            case .moment(let m): MomentHero(moment: m, model: model)
            case .music: MusicHero(model: model)
            case .idle: IdleHero()
            }
        }
        .frame(width: HomeView.heroWidth, height: HomeView.heroHeight)
        .accessibilityElement(children: .contain)
    }
}

/// The card every hero shares: the thing's eyebrow, its name, a line under it, its reading (a figure) beside, and the
/// actions along the foot.
private struct HeroShell<Figure: View, Actions: View>: View {
    var tint: Color
    var eyebrow: String
    var dot = false
    var title: String
    var detail: String = ""
    var lit: Double = 1
    @ViewBuilder var figure: Figure
    @ViewBuilder var actions: Actions

    var body: some View {
        PrismCard(tint: tint, corner: 22, lit: lit) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Eyebrow(text: eyebrow, dot: dot ? tint : nil, tint: DS.Ink.secondary)
                        Text(title)
                            .font(.system(size: 20, weight: .semibold)).tracking(-0.3)
                            .foregroundStyle(DS.Ink.primary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .padding(.top, 5)
                            .help(title)
                        if !detail.isEmpty {
                            Text(detail).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.secondary).lineLimit(1).padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                    figure
                }
                Spacer(minLength: 6)
                HStack(spacing: 8) { actions }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        }
    }
}

private extension HeroShell where Figure == EmptyView {
    init(tint: Color, eyebrow: String, dot: Bool = false, title: String, detail: String = "", lit: Double = 1, @ViewBuilder actions: () -> Actions) {
        self.init(tint: tint, eyebrow: eyebrow, dot: dot, title: title, detail: detail, lit: lit, figure: { EmptyView() }, actions: actions)
    }
}

/// A big reading: "12 min", "6 min". Light rounded figures, as the instruments use.
private struct HeroFigure: View {
    let value: String
    let unit: String
    var tint: Color = DS.Ink.primary

    var body: some View {
        Figure(value: value, unit: unit, size: 38, tint: tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(value) \(unit)")
    }
}

// MARK: Task

/// The task you're working on, and how long you've been at it.
private struct TaskHero: View {
    @ObservedObject var active: ActiveTask
    @Environment(\.islandShowing) private var showing

    var body: some View {
        if let task = active.task {
            HeroShell(tint: TaskStyle.tint, eyebrow: "Focusing", dot: true, title: task.title,
                      detail: detail(task), figure: {
                if let since = active.since {
                    // Seconds in the first minute, then once a minute: it never ticks while the island is closed.
                    TimelineView(ElapsedSchedule(since: since, showing: showing)) { ctx in
                        let (v, u) = HeroReading.elapsed(active.elapsed(at: ctx.date))
                        HeroFigure(value: v, unit: u)
                    }
                }
            }, actions: {
                Pill(title: "Done", symbol: "checkmark") {
                    HapticEngine.shared.play(.confirm, channel: .tasks)
                    withAnimation(Motion.morph) { TaskStore.shared.complete(task.id) }
                    FocusTimer.shared.stop()
                }
                Ghost(symbol: "pause.fill", label: "Pause Focus", size: 12, hit: 30) { FocusTimer.shared.togglePause() }
                Spacer(minLength: 0)
            })
        }
    }

    private func detail(_ t: TaskSnapshot) -> String {
        var parts: [String] = []
        if let e = t.estimate { parts.append("About \(TaskFormat.length(e))") }
        if let p = t.project { parts.append(p) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Timer

private struct TimerHero: View {
    let label: String
    @ObservedObject private var timer = FocusTimer.shared

    var body: some View {
        HeroShell(tint: DS.Palette.orange, eyebrow: timer.phase == .paused ? "Paused" : "Focus", dot: timer.phase == .running, title: label,
                  detail: RoomStore.shared.room(for: label)?.summary ?? "", figure: {
            Figure(value: timer.clock, size: 38, tint: timer.phase == .paused ? DS.Ink.secondary : DS.Ink.primary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(timer.clock) left")
        }, actions: {
            Pill(title: timer.phase == .paused ? "Resume" : "Pause") { timer.togglePause() }
            Ghost(symbol: "stop.fill", label: "End Focus", size: 11, hit: 30) { timer.stop() }
            Spacer(minLength: 0)
        })
    }
}

// MARK: Meeting

private struct MeetingHero: View {
    let event: CalendarModel.Event
    var model: IslandModel

    var body: some View {
        // Whole minutes, so it re-renders twice a minute at most.
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            let underway = event.start <= now
            let mins = underway ? max(0, Int(event.end.timeIntervalSince(now) / 60)) : max(1, Int((event.start.timeIntervalSince(now) / 60).rounded(.up)))
            let (value, unit) = HeroReading.minutes(mins)
            HeroShell(tint: event.color, eyebrow: underway ? "Happening now" : "Up next", dot: underway, title: event.title,
                      detail: CalendarModel.timeRange(event) + (event.location.map { " · " + $0 } ?? ""), figure: {
                HeroFigure(value: value, unit: underway ? unit + " left" : unit)
            }, actions: {
                if event.meetingURL != nil {
                    Pill(title: "Join", symbol: "video.fill") { CalendarModel.shared.open(event); model.collapse() }
                } else if underway, MeetingCompanion.shared.state == .idle, Prefs.shared.meetingNotes {
                    FlowOptionButton(title: "Take Notes") { MeetingCompanion.shared.offer() }
                }
                Spacer(minLength: 0)
            })
        }
    }
}

// MARK: Other moments

/// Now's other moments (the next block, a page you're reading, the morning plan, the evening) in the hero's frame.
private struct MomentHero: View {
    let moment: NowModel.Moment
    var model: IslandModel
    @ObservedObject private var rooms = RoomStore.shared

    var body: some View {
        switch moment {
        case .next(let p):
            let mins = max(1, Int(p.start.timeIntervalSince(PlanClock.now) / 60))
            HeroShell(tint: BrainStyle.tint, eyebrow: "Next block", title: p.title,
                      detail: "\(p.start.formatted(date: .omitted, time: .shortened))–\(p.end.formatted(date: .omitted, time: .shortened))"
                      + (rooms.room(for: p.title).map { " · " + $0.summary } ?? ""), figure: {
                HeroFigure(value: "\(mins)", unit: "min")
            }, actions: {
                Pill(title: rooms.room(for: p.title) == nil ? "Start Focus" : "Set the Room") {
                    RoomStore.shared.setRoom(title: p.title, minutes: p.minutes)
                    model.collapse()
                }
                PrismQuiet(title: "Not now") { NowModel.shared.dismiss(moment) }
                Spacer(minLength: 0)
            })
        case .reading(let title, let browser):
            HeroShell(tint: DS.Palette.blue, eyebrow: "Reading in \(browser)", title: title, actions: {
                Pill(title: "Summarize") { PageActions.perform(.summarize) }
                FlowOptionButton(title: "Save to Learn") { model.collapse(); PageActions.perform(.learn) }
                Spacer(minLength: 0)
                Ghost(symbol: "xmark", label: "Not Now", size: 10, tint: DS.Ink.tertiary, hit: 28) { NowModel.shared.dismiss(moment) }
            })
        case .plan:
            let drafted = PlanStore.shared.priorities.filter { !$0.title.isEmpty }.count
            HeroShell(tint: PlanView.morning, eyebrow: "Good morning", title: "Plan your day",
                      detail: drafted > 0 ? "Flow drafted \(drafted) priorit\(drafted == 1 ? "y" : "ies")" : "Your top three, fitted around your meetings", actions: {
                Pill(title: "Plan") { IslandManager.shared.openPlan() }
                PrismQuiet(title: "Not today") { NowModel.shared.dismiss(moment) }
                Spacer(minLength: 0)
            })
        case .evening:
            let i = InsightModel.shared.insight
            HeroShell(tint: (i.modes.first?.mode ?? .other).tint, eyebrow: "This evening", title: "Your day, drawn",
                      detail: i.activeToday < 60 ? "See how today went"
                      : "\(DayArtView.length(i.deepToday)) of focus · \(DayArtView.length(i.activeToday)) at your Mac", actions: {
                Pill(title: "See Your Day") { IslandManager.shared.primary?.model.open(.day) }
                PrismQuiet(title: "Hide") { NowModel.shared.dismiss(moment) }
                Spacer(minLength: 0)
            })
        case .flow, .meeting, .focus:
            EmptyView()
        }
    }
}

// MARK: Flow

/// A suggestion or question Flow is waiting on, on the same card Flow's sheet uses.
private struct FlowHero: View {
    let item: FlowInbox.Item
    var onLeave: () -> Void
    @ObservedObject private var inbox = FlowInbox.shared

    var body: some View {
        FlowAskCard(item: item, more: max(0, inbox.items.count - 1), onLeave: onLeave)
    }
}

// MARK: Music

/// Your music as the hero: the cover, lit by its own colours through the glass, and the player under your fingers.
private struct MusicHero: View {
    var model: IslandModel
    @ObservedObject private var media = NowPlayingModel.shared
    @Environment(\.islandShowing) private var showing

    private var playing: Bool { media.mode == .app || media.isPlaying }

    var body: some View {
        PrismCard(tint: media.accent, corner: 22, lit: 1.05, field: media.mode == .track ? media.palette : nil) {
            HStack(spacing: 14) {
                Button { media.openCurrentApp() } label: {
                    ImmersiveArtwork(size: 84).tilt(8, corner: 84 * 0.23, size: CGSize(width: 84, height: 84))
                }
                .buttonStyle(PressStyle(scale: 0.95))
                .help("Open \(media.source?.name ?? media.otherApp?.name ?? "Player")")
                .accessibilityLabel("Open player")

                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(text: playing ? "Now playing" : "Paused", tint: DS.Ink.secondary)
                    MarqueeText(text: media.mode == .app ? (media.otherApp?.name ?? "Audio") : media.title, font: .system(size: 17, weight: .semibold), color: DS.Ink.primary)
                        .padding(.top, 4)
                    Text(media.mode == .app ? "Playing audio" : (media.artist.isEmpty ? media.album : media.artist))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.secondary).lineLimit(1).padding(.top, 1)
                    Spacer(minLength: 2)
                    HStack(spacing: 0) {
                        Ghost(symbol: "backward.fill", label: "Previous", size: 12, hit: 28) { media.previous() }
                        Ghost(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play", size: 17, weight: .bold, hit: 32) { media.playPause() }
                        Ghost(symbol: "forward.fill", label: "Next", size: 12, hit: 28) { media.next() }
                        Spacer(minLength: 6)
                        if media.mode == .track, media.duration > 0 {
                            TimelineView(PeriodicTimelineSchedule.seconds(showing && media.isPlaying)) { ctx in
                                ProgressLine(fraction: media.position(at: ctx.date) / media.duration, tint: .white) { f in media.seek(to: f * media.duration) }
                            }
                            .frame(maxWidth: 70)
                        } else {
                            Waveform(tint: DS.Ink.secondary, active: media.isLive, bars: 5, height: 14, barWidth: 2.5)
                        }
                    }
                    .padding(.leading, -8)
                    .disabled(!media.canControl)
                }
                .frame(height: 84)
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
        }
    }
}

// MARK: Idle

private struct IdleHero: View {
    @ObservedObject private var media = NowPlayingModel.shared

    var body: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting = hour < 5 ? "Late night" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : hour < 22 ? "Good evening" : "Late night"
        HeroShell(tint: Color(nsColor: AmbientLight.colors(AmbientLight.mood(at: Date(), focusing: false)).first ?? .white), eyebrow: greeting, title: "All clear",
                  detail: "Nothing playing. Pick up where you left off.", actions: {
            ForEach(MediaSource.allCases.filter(\.isInstalled), id: \.self) { source in
                HeroSourceChip(source: source) { media.open(source) }
            }
            Spacer(minLength: 0)
        })
    }
}

private struct HeroSourceChip: View {
    let source: MediaSource
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = source.icon { IconImage(image: icon, size: 16) }
                Text(source.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.primary)
            }
            .padding(.leading, 8).padding(.trailing, 11)
            .frame(height: 28)
            .background(Capsule().fill(hover ? DS.Ink.wellHover : DS.Ink.well))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityLabel("Open \(source.name)")
    }
}

// MARK: - Today strip

/// The next few things on your list, quiet beside the hero: a circle to finish each, a title, and the whole strip a
/// way into Tasks.
struct TodayStrip: View {
    var model: IslandModel
    @ObservedObject private var store = TaskStore.shared
    @ObservedObject private var active = TaskStore.shared.active

    static let rows = 3

    /// What's next today, in your order, without the task you're already working on. A task you just finished stays
    /// in its place while its circle fills (the store lets go of it a moment later).
    static func next(_ tasks: [FlowTask], excluding active: UUID?) -> [FlowTask] {
        Array(tasks.filter { $0.id != active }.prefix(rows))
    }

    var body: some View {
        let list = Self.next(store.list(.today), excluding: active.task?.id)
        let open = store.list(.today).filter(\.isOpen).count
        VStack(alignment: .leading, spacing: 2) {
            Button { model.select(.tasks) } label: {
                HStack(spacing: 4) {
                    Text("TODAY").font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(DS.Ink.tertiary)
                    Spacer(minLength: 0)
                    if open > 0 { Text("\(open) open").font(DS.Kit.caption).foregroundStyle(DS.Ink.tertiary) }
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.98))
            .accessibilityLabel("Today, \(open) open. Open Tasks")

            if list.isEmpty {
                // The same rhythm as a list of tasks: a row to add one, and a quiet line saying the day is clear.
                Button { model.select(.tasks) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 17)).foregroundStyle(TaskStyle.tint)
                        Text("Add a task").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Ink.primary)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .accessibilityLabel("Add a task")
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 17, weight: .light)).foregroundStyle(DS.Ink.tertiary)
                    Text("Nothing due today").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Ink.tertiary)
                }
                .frame(height: 28)
                .accessibilityElement(children: .combine)
            } else {
                ForEach(list) { task in TodayRow(task: task, model: model) }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct TodayRow: View {
    let task: FlowTask
    var model: IslandModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            CompletionCircle(done: task.isDone, size: 17) { complete() }
            Button { model.select(.tasks) } label: {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(task.isDone ? DS.Ink.tertiary : DS.Ink.primary)
                    .strikethrough(task.isDone, color: DS.Ink.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 28)
        .onHover { h in hover = h }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.isDone ? "\(task.title), done" : task.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: task.isDone ? "Mark Not Done" : "Complete") { complete() }
        .accessibilityAction(named: "Open Tasks") { model.select(.tasks) }
        .accessibilityAction(named: "Start Focus") { TasksModel.shared.startFocus(task.id) }
    }

    private func complete() {
        if task.isOpen { HapticEngine.shared.play(.confirm, channel: .tasks) }
        withAnimation(Access.reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.62)) { TaskStore.shared.toggle(task.id) }
    }
}
