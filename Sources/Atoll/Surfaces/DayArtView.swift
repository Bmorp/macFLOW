import SwiftUI

/// Your day, drawn: a ring from the first moment you sat down to now. Each stretch of work is an arc in its colour,
/// meetings ride an inner track, every song you played is a dot on the outside, and each priority you finished is a
/// small star on the ring. In the middle, the hours of focus. It draws itself in as it opens, and saves as an image.
struct DayStory: Equatable {
    var date = Date()
    var start = Date()
    var end = Date()
    var spans: [RewindModel.Span] = []
    var songs: [Song] = []
    var meetings: [DateInterval] = []
    var finished: [Date] = []
    var focus: TimeInterval = 0
    var active: TimeInterval = 0
    var modes: [Share] = []
    var topProject: String?
    var priorities = (done: 0, total: 0)
    var headline = ""

    struct Song: Equatable { let at: Date; let artist: String }
    struct Share: Equatable { let mode: WorkMode; let seconds: TimeInterval }

    static func == (a: DayStory, b: DayStory) -> Bool {
        a.date == b.date && a.spans == b.spans && a.songs == b.songs && a.meetings == b.meetings && a.finished == b.finished
            && a.focus == b.focus && a.headline == b.headline && a.priorities.done == b.priorities.done && a.priorities.total == b.priorities.total
    }

    /// Angle (radians, 0 at the top, clockwise) of a moment on the ring.
    func angle(_ t: Date) -> Double {
        let f = min(1, max(0, t.timeIntervalSince(start) / max(1, end.timeIntervalSince(start))))
        return f * 2 * .pi
    }

    /// A line that reads the day back — computed, so it's never invented.
    nonisolated static func headline(modes: [Share], focus: TimeInterval, meetings: Int, songs: Int, project: String?) -> String {
        guard let top = modes.first else { return "A quiet day" }
        let share = top.seconds / max(1, modes.reduce(0) { $0 + $1.seconds })
        var line: String
        switch top.mode {
        case .coding: line = share > 0.55 ? "A day of building" : "Building, between other things"
        case .writing: line = share > 0.55 ? "A day of writing" : "Words, between other things"
        case .design: line = "A day of making things look right"
        case .meeting: line = meetings >= 4 ? "A day of meetings" : "Mostly conversations"
        case .communicating: line = "A day of catching up"
        case .research, .reading: line = "A day of learning"
        case .planning: line = "A day of planning"
        case .media: line = "An easy day"
        default: line = "A full day"
        }
        if let project, top.mode == .coding || top.mode == .writing || top.mode == .design { line += ", mostly on \(project)" }
        if focus >= 4 * 3600 { line += " — deep and steady" } else if songs >= 25 { line += ", with a soundtrack" }
        return line
    }
}

@MainActor
final class DayArtModel: ObservableObject {
    static let shared = DayArtModel()
    @Published private(set) var story = DayStory()
    @Published private(set) var savedTo: URL?

    func load() {
        let now = Date()
        let cal = Calendar.current
        let dayStart = RewindModel.dayStart(for: now)
        let moments = RewindModel.today()
        // The day it is (in the record's sense): at 1 AM, still yesterday.
        var s = DayStory(date: dayStart)
        let first = moments.first?.ts ?? cal.date(bySettingHour: Prefs.shared.planStartHour, minute: 0, second: 0, of: now) ?? now
        s.start = cal.date(bySetting: .minute, value: 0, of: first).map { $0 > first ? $0.addingTimeInterval(-3600) : $0 } ?? first
        s.end = max(now, s.start.addingTimeInterval(8 * 3600))
        s.spans = RewindModel.spans(moments, until: now)
        s.songs = BrainStore.shared.events(since: dayStart, kinds: ["media"], limit: 400).map {
            DayStory.Song(at: $0.ts, artist: $0.detail.components(separatedBy: "|").first ?? "")
        }
        s.meetings = s.spans.filter { $0.mode == .meeting }.map { DateInterval(start: $0.start, end: $0.end) }
        let plan = PlanStore.shared.plan
        s.finished = plan.focus.filter(\.done).map { $0.start.addingTimeInterval(Double($0.minutes) * 30) }
        s.priorities = (plan.focus.filter(\.done).count, plan.focus.count)
        var byMode: [WorkMode: TimeInterval] = [:]
        for sp in s.spans where sp.mode != .idle { byMode[sp.mode, default: 0] += sp.end.timeIntervalSince(sp.start) }
        s.modes = byMode.map { DayStory.Share(mode: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
        s.active = byMode.values.reduce(0, +)
        s.focus = s.spans.filter { $0.mode.isDeepWork }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let insight = InsightModel.shared.insight
        s.focus = max(s.focus, insight.deepToday)
        s.topProject = insight.projects.first(where: { $0.today > 600 })?.name
        s.headline = DayStory.headline(modes: s.modes, focus: s.focus, meetings: s.meetings.count, songs: s.songs.count, project: s.topProject)
        story = s
        savedTo = nil
    }

    /// Renders the card at 3× into ~/Pictures/Mac Flow and shows it in Finder.
    func save() {
        let card = DayArtCard(story: story).frame(width: 640, height: 360).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: card)
        r.scale = 3
        guard let cg = r.cgImage else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Mac Flow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Day \(DayPlan.key(for: story.date)).png")
        guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else { return }
        savedTo = url
        Haptics.confirm()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    #if DEBUG
    func debugSet(_ s: DayStory) { story = s }
    #endif
}

struct DayArtView: View {
    var model: IslandModel
    @ObservedObject private var art = DayArtModel.shared
    @Environment(\.islandShowing) private var showing
    @State private var drawn: Double

    static let height: CGFloat = 262
    private var inset: CGFloat { IslandModel.expandedFlare + DS.Island.rowLeading + 2 }

    init(model: IslandModel) {
        self.model = model
        _drawn = State(initialValue: RenderMode.snapshot || model.mode != .expanded(.day) ? 1 : 0)
    }

    var body: some View {
        let size = model.expandedSize(.day)
        let s = art.story
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: model.notch.width + 24)
                GlyphButton(symbol: "xmark", label: "Close", size: 11, tint: DS.Ink.secondary, hit: 26) { model.collapse() }
            }
            .frame(height: model.notch.height)
            .padding(.horizontal, inset)
            HStack(alignment: .center, spacing: 22) {
                DayRing(story: s, progress: drawn)
                    .frame(width: 204, height: 204)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(DS.Ink.tertiary)
                    Text(s.headline)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(DS.Ink.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                    stats(s).padding(.top, 14)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        QuietButton(title: art.savedTo == nil ? "Save Image" : "Saved") { art.save() }
                        Pill(title: "Recap with Flow", symbol: "sparkles") {
                            BrainEngine.shared.askBrain("Recap my day: what got done, how my time went, and one thing to carry into tomorrow. Be brief.")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 204)
            }
            .padding(.horizontal, inset)
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(alignment: .top) {
            ContentLight(color: s.modes.first?.mode.tint ?? BrainStyle.tint, origin: UnitPoint(x: 0.22, y: 0.62), strength: 0.9)
        }
        .onChange(of: showing, initial: true) { _, on in
            guard on, model.mode == .expanded(.day), !RenderMode.snapshot else { return }
            art.load()
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { drawn = 0 }
            withAnimation(Access.reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 1.3, dampingFraction: 0.9).delay(0.12)) { drawn = 1 }
        }
    }

    private func stats(_ s: DayStory) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                stat(Self.length(s.focus), "focus", BrainStyle.tint)
                stat(Self.length(s.active), "at your Mac", DS.Ink.secondary)
            }
            GridRow {
                stat("\(s.meetings.count)", s.meetings.count == 1 ? "meeting" : "meetings", WorkMode.meeting.tint)
                stat("\(s.songs.count)", s.songs.count == 1 ? "song" : "songs", WorkMode.media.tint)
            }
            if s.priorities.total > 0 {
                GridRow {
                    stat("\(s.priorities.done)/\(s.priorities.total)", "priorities", PlanView.morning)
                    if let p = s.topProject { stat(p, "", DS.Ink.secondary) } else { Color.clear.frame(height: 1) }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(value).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(DS.Ink.primary).lineLimit(1)
            if !label.isEmpty { Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.Ink.tertiary).lineLimit(1) }
        }
    }

    static func length(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}

/// The saved image: the ring, the line, the numbers, the mark.
struct DayArtCard: View {
    let story: DayStory

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.035, blue: 0.045)
            RadialGradient(colors: [(story.modes.first?.mode.tint ?? BrainStyle.tint).opacity(0.35), .clear], center: UnitPoint(x: 0.28, y: 0.5),
                           startRadius: 10, endRadius: 320)
            HStack(spacing: 34) {
                DayRing(story: story, progress: 1).frame(width: 270, height: 270)
                VStack(alignment: .leading, spacing: 10) {
                    Text(story.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(.white.opacity(0.5))
                    Text(story.headline).font(.system(size: 24, weight: .semibold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    Text("\(DayArtView.length(story.focus)) focus · \(story.meetings.count) meetings · \(story.songs.count) songs")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    HStack(spacing: 8) {
                        FlowMark(color: .white.opacity(0.7)).frame(height: 12)
                        Text("Mac Flow").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 50)
            }
            .padding(.horizontal, 40)
        }
    }
}

/// The ring. `progress` draws it in, clockwise from the start of the day.
struct DayRing: View, Animatable {
    let story: DayStory
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 18
            let limit = progress * 2 * .pi
            func point(_ a: Double, _ radius: CGFloat) -> CGPoint {
                CGPoint(x: c.x + radius * CGFloat(sin(a)), y: c.y - radius * CGFloat(cos(a)))
            }
            func arc(_ a0: Double, _ a1: Double, _ radius: CGFloat) -> Path {
                var p = Path()
                p.addArc(center: c, radius: radius, startAngle: .radians(a0 - .pi / 2), endAngle: .radians(a1 - .pi / 2), clockwise: false)
                return p
            }
            // The track, and an hour tick every hour.
            ctx.stroke(arc(0, 2 * .pi, r), with: .color(.white.opacity(0.06)), lineWidth: 14)
            var t = Calendar.current.nextDate(after: story.start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? story.end
            while t < story.end {
                let a = story.angle(t)
                var tick = Path()
                tick.move(to: point(a, r - 10))
                tick.addLine(to: point(a, r - 7))
                ctx.stroke(tick, with: .color(.white.opacity(Calendar.current.component(.hour, from: t) % 6 == 0 ? 0.5 : 0.18)), lineWidth: 1)
                t = t.addingTimeInterval(3600)
            }
            // Work, in its colours.
            for s in story.spans where s.mode != .idle {
                let a0 = story.angle(s.start), a1 = min(story.angle(s.end), limit)
                guard a1 > a0 else { continue }
                ctx.stroke(arc(a0, max(a1 - 0.004, a0 + 0.002), r), with: .color(s.mode.tint.opacity(s.mode.isDeepWork ? 0.95 : 0.6)),
                           style: StrokeStyle(lineWidth: s.mode.isDeepWork ? 14 : 9, lineCap: .butt))
            }
            // Meetings, on the inner track.
            for m in story.meetings {
                let a0 = story.angle(m.start), a1 = min(story.angle(m.end), limit)
                guard a1 > a0 else { continue }
                ctx.stroke(arc(a0, a1, r - 16), with: .color(WorkMode.meeting.tint), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            // The soundtrack: a thin ribbon outside the ring, a segment per song in its artist's colour, from when it
            // started until the next (or four minutes) — continuous when you listened all afternoon, sparse when you didn't.
            let songs = story.songs.sorted { $0.at < $1.at }
            for (i, song) in songs.enumerated() {
                let a0 = story.angle(song.at)
                guard a0 <= limit else { continue }
                let next = i + 1 < songs.count ? songs[i + 1].at : song.at.addingTimeInterval(240)
                let a1 = min(story.angle(min(next, song.at.addingTimeInterval(360))), limit)
                guard a1 > a0 else { continue }
                // A stable colour per artist (String.hashValue changes every launch).
                let hue = Double(song.artist.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
                ctx.stroke(arc(a0, max(a0 + 0.003, a1 - 0.004), r + 13), with: .color(Color(hue: hue, saturation: 0.5, brightness: 1).opacity(0.85)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .butt))
            }
            // Priorities finished: Flow's star on the ring.
            for f in story.finished {
                let a = story.angle(f)
                guard a <= limit else { continue }
                let p = point(a, r)
                ctx.fill(Brand.starPath(center: p, h: 14), with: .color(.white))
            }
            // Now.
            if story.end.timeIntervalSinceNow > -60, progress >= 0.999 {
                let p = point(story.angle(Date()), r)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(.white))
            }
        }
        .overlay {
            // The number sized to the ring, so it sits inside the track at any size.
            GeometryReader { g in
                let side = min(g.size.width, g.size.height)
                VStack(spacing: 2) {
                    Text(DayArtView.length(story.focus))
                        .font(.system(size: max(14, side * 0.15), weight: .light, design: .rounded).monospacedDigit())
                        .foregroundStyle(DS.Ink.primary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("FOCUS").font(.system(size: max(8, side * 0.05), weight: .semibold)).tracking(DS.Kit.eyebrowTracking).foregroundStyle(DS.Ink.tertiary)
                }
                .frame(width: side * 0.6)
                .position(x: g.size.width / 2, y: g.size.height / 2)
            }
            .opacity(progress)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your day: \(DayArtView.length(story.focus)) of focus, \(story.meetings.count) meetings, \(story.songs.count) songs")
    }
}
