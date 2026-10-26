import SwiftUI

/// Rewind: today, scrubbable. A ribbon of the day coloured by the kind of work, a playhead you drag (or swipe with two
/// fingers, or step with the arrow keys), and above it what you were doing at that moment — the app, the document,
/// the song, the Claude session — with one click to reopen it. Built from Flow's own moments; no screenshots.
@MainActor
final class RewindModel: ObservableObject {
    static let shared = RewindModel()

    @Published private(set) var moments: [BrainStore.Moment] = []
    @Published private(set) var spans: [Span] = []
    /// Where the playhead is: an index into `moments`.
    @Published var index = 0
    @Published private(set) var dayStart = Date()
    @Published private(set) var dayEnd = Date()

    /// A stretch of one kind of work, for the ribbon.
    struct Span: Identifiable, Equatable {
        let id: Int
        let start: Date
        let end: Date
        let mode: WorkMode
    }

    var current: BrainStore.Moment? { moments.indices.contains(index) ? moments[index] : nil }

    /// Today's moments — and, for stretches before moments were kept, ones drawn from Flow's work sessions.
    /// Where "today" begins for the record of your day: 4 AM. Work at 1 AM belongs to the day it finishes, not to a
    /// day that's an hour old — so at midnight your day doesn't vanish.
    nonisolated static func dayStart(for now: Date = Date(), calendar: Calendar = .current) -> Date {
        let four = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: now) ?? calendar.startOfDay(for: now)
        return now >= four ? four : calendar.date(byAdding: .day, value: -1, to: four) ?? four
    }

    static func today() -> [BrainStore.Moment] {
        let start = dayStart()
        let recorded = BrainStore.shared.moments(from: start)
        let firstRecorded = recorded.first?.ts ?? .distantFuture
        var drawn: [BrainStore.Moment] = []
        for ep in BrainStore.shared.episodes(since: start, limit: 200).reversed() where ep.start < firstRecorded {
            var t = ep.start
            let end = min(ep.end, firstRecorded)
            while t < end {
                drawn.append(BrainStore.Moment(ts: t, mode: ep.mode, project: ep.project, bundle: ep.apps.first ?? "",
                                               app: ep.apps.first.flatMap(Desk.appName) ?? "", title: ep.summary))
                t = t.addingTimeInterval(300)
            }
        }
        // Drawn moments get ids of their own (negative, so they never meet a stored one).
        for i in drawn.indices { drawn[i].id = -Int64(i + 1) }
        return (drawn + recorded).sorted { $0.ts < $1.ts }
    }

    /// Today's moments, the playhead on the latest (or on `at`).
    func load(at: Date? = nil) {
        moments = Self.today()
        spans = Self.spans(moments, until: Date())
        dayStart = moments.first?.ts ?? Date().addingTimeInterval(-3600)
        dayEnd = max(Date(), dayStart.addingTimeInterval(1800))
        index = at.flatMap(nearest) ?? max(0, moments.count - 1)
    }

    func nearest(_ t: Date) -> Int? {
        guard !moments.isEmpty else { return nil }
        return moments.indices.min { abs(moments[$0].ts.timeIntervalSince(t)) < abs(moments[$1].ts.timeIntervalSince(t)) }
    }

    /// Moves the playhead to the moment nearest a point on the ribbon (0…1).
    func scrub(to fraction: Double) {
        let t = dayStart.addingTimeInterval(dayEnd.timeIntervalSince(dayStart) * min(1, max(0, fraction)))
        if let i = nearest(t), i != index { index = i }
    }

    func step(_ delta: Int) {
        let next = min(max(0, index + delta), max(0, moments.count - 1))
        if next != index { index = next }
    }

    /// Consecutive moments of one mode become one span (each lasting until the next moment, capped at 10 minutes).
    nonisolated static func spans(_ moments: [BrainStore.Moment], until now: Date) -> [Span] {
        var out: [Span] = []
        for (i, m) in moments.enumerated() {
            let next = i + 1 < moments.count ? moments[i + 1].ts : now
            let end = min(next, m.ts.addingTimeInterval(600))
            let mode = WorkMode(rawValue: m.mode) ?? .other
            if let last = out.last, last.mode == mode, m.ts.timeIntervalSince(last.end) < 60 {
                out[out.count - 1] = Span(id: last.id, start: last.start, end: end, mode: mode)
            } else {
                out.append(Span(id: i, start: m.ts, end: end, mode: mode))
            }
        }
        return out
    }

    /// The room a moment stands for: its app and document, its song, its Claude session — and, if the moment's project
    /// has a fuller room saved, that.
    func room(for m: BrainStore.Moment) -> Room {
        if !m.project.isEmpty, let saved = RoomStore.shared.projectRoom(m.project),
           abs(saved.saved.timeIntervalSince(m.ts)) < 1800 {
            return saved
        }
        var room = Room(key: "moment", title: m.title.isEmpty ? m.app : m.title, apps: m.bundle.isEmpty ? [] : [m.bundle])
        if !m.document.isEmpty { room.documents[m.bundle] = [m.document] }
        if !m.track.isEmpty {
            let parts = m.track.components(separatedBy: " — ")
            room.track = Room.Track(title: parts.first ?? m.track, artist: parts.count > 1 ? parts[1] : "", source: "")
        }
        if !m.claude.isEmpty { room.claude = ClaudeSessions.shared.sessions.first { $0.folder == m.claude }?.cwd }
        return room
    }

    func reopen() {
        guard let m = current else { return }
        RoomStore.shared.restore(room(for: m), hideOthers: false)
        Haptics.confirm()
    }

    /// "What was I doing at 3?" in words, for Flow.
    static func describe(_ m: BrainStore.Moment) -> String {
        let mode = WorkMode(rawValue: m.mode)?.label ?? "Working"
        var s = "At \(m.ts.formatted(date: .omitted, time: .shortened)): \(mode)"
        if !m.project.isEmpty { s += " on \(m.project)" }
        if !m.app.isEmpty { s += " in \(m.app)" }
        if !m.title.isEmpty { s += " (\(m.title.prefix(80)))" }
        if !m.track.isEmpty { s += ", listening to \(m.track)" }
        if !m.claude.isEmpty { s += ", with Claude in \(m.claude)" }
        return s + "."
    }

    #if DEBUG
    func debugSet(_ list: [BrainStore.Moment], index i: Int) {
        moments = list
        spans = Self.spans(list, until: list.last.map { $0.ts.addingTimeInterval(300) } ?? Date())
        dayStart = list.first?.ts ?? Date()
        dayEnd = list.last.map { $0.ts.addingTimeInterval(300) } ?? Date()
        index = i
    }
    #endif
}

struct RewindView: View {
    var model: IslandModel
    @ObservedObject private var rewind = RewindModel.shared
    @Environment(\.islandShowing) private var showing

    static let height: CGFloat = 214
    private var inset: CGFloat { IslandModel.expandedFlare + DS.Island.rowLeading + 4 }

    var body: some View {
        let size = model.expandedSize(.rewind)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: model.notch.width + 24)
                GlyphButton(symbol: "xmark", label: "Close", size: 11, tint: DS.Ink.secondary, hit: 26) { model.collapse() }
            }
            .frame(height: model.notch.height)
            .padding(.horizontal, inset)
            if let m = rewind.current {
                moment(m)
                    .padding(.horizontal, inset)
                    .padding(.top, 4)
                    .id(m.id)
                    .transition(.opacity)
            } else {
                empty.padding(.horizontal, inset).padding(.top, 8)
            }
            Spacer(minLength: 0)
            if !rewind.moments.isEmpty {
                Ribbon(rewind: rewind)
                    .frame(height: 46)
                    .padding(.horizontal, inset)
                    .padding(.bottom, 18)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(alignment: .top) {
            ContentLight(color: (WorkMode(rawValue: rewind.current?.mode ?? "") ?? .other).tint, origin: UnitPoint(x: 0.15, y: 1.1), strength: 0.7)
                .animation(.smooth(duration: 0.5), value: rewind.current?.mode)
        }
        .onChange(of: showing, initial: true) { _, on in if on, model.mode == .expanded(.rewind), !RenderMode.snapshot { rewind.load() } }
    }

    private func moment(_ m: BrainStore.Moment) -> some View {
        let mode = WorkMode(rawValue: m.mode) ?? .other
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: mode.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(mode.tint)
                    Text((m.project.isEmpty ? mode.label : "\(mode.label) · \(m.project)").uppercased())
                        .font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(mode.tint).lineLimit(1)
                }
                Text(m.ts.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(DS.Ink.primary)
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 4) {
                    detail(symbol: "macwindow", text: [m.app, m.title.isEmpty ? nil : m.title].compactMap { $0 }.joined(separator: " — "))
                    if !m.document.isEmpty, let url = URL(string: m.document) {
                        detail(symbol: url.isFileURL ? "doc" : "globe", text: url.isFileURL ? url.lastPathComponent : (url.host ?? m.document))
                    }
                    if !m.track.isEmpty { detail(symbol: "music.note", text: m.track) }
                    if !m.claude.isEmpty { detail(symbol: "asterisk", text: "Claude · \(m.claude)") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Pill(title: "Reopen", symbol: "arrow.uturn.backward") { rewind.reopen() }
                QuietButton(title: "Ask Flow") {
                    let when = m.ts.formatted(date: .omitted, time: .shortened)
                    BrainEngine.shared.askBrain("What was I doing around \(when), and what came of it?")
                }
            }
            .padding(.top, 18)
        }
    }

    private func detail(symbol: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Ink.tertiary).frame(width: 14)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Rewind", dot: BrainStyle.tint)
            Text("Nothing to rewind yet").font(.system(size: 19, weight: .semibold)).foregroundStyle(DS.Ink.primary)
            Text(WorkContext.shared.level == .off
                 ? "Flow isn’t observing. Turn it on in Settings › Flow to keep a record of your day, on this Mac."
                 : "Flow keeps a moment every few minutes while you work — come back in a little while.")
                .font(.system(size: 12)).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Today as a ribbon: spans coloured by the kind of work, hour marks, and the playhead.
private struct Ribbon: View {
    @ObservedObject var rewind: RewindModel
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = max(1, rewind.dayEnd.timeIntervalSince(rewind.dayStart))
            let x: (Date) -> CGFloat = { CGFloat(min(1, max(0, $0.timeIntervalSince(rewind.dayStart) / span))) * w }
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.white.opacity(0.06)).frame(height: 18).offset(y: 6)
                ForEach(rewind.spans) { s in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(s.mode.tint.opacity(0.85))
                        .frame(width: max(2, x(s.end) - x(s.start) - 1), height: 18)
                        .offset(x: x(s.start), y: 6)
                }
                if let m = rewind.current {
                    let px = x(m.ts)
                    Capsule().fill(Color.white).frame(width: 3, height: 30)
                        .shadow(color: .white.opacity(0.7), radius: 4)
                        .offset(x: px - 1.5, y: 0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: m.id)
                }
                ForEach(hours(), id: \.self) { d in
                    Text(d.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DS.Ink.tertiary)
                        .fixedSize()
                        .position(x: min(max(x(d), 14), w - 14), y: 40)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                dragging = true
                rewind.scrub(to: Double(v.location.x / max(1, w)))
            }.onEnded { _ in dragging = false })
        }
        .accessibilityElement()
        .accessibilityLabel("Today’s timeline")
        .accessibilityValue(rewind.current.map(RewindModel.describe) ?? "Empty")
        .accessibilityAdjustableAction { dir in rewind.step(dir == .increment ? 1 : -1) }
    }

    private func hours() -> [Date] {
        let cal = Calendar.current
        let first = cal.component(.hour, from: rewind.dayStart) + 1
        let last = cal.component(.hour, from: rewind.dayEnd)
        guard last >= first else { return [] }
        let step = max(1, (last - first + 1) / 5)
        return stride(from: first, through: last, by: step).compactMap { cal.date(bySettingHour: $0, minute: 0, second: 0, of: rewind.dayStart) }
    }
}

extension WorkMode {
    /// One colour per kind of work, shared by Rewind and your day.
    var tint: Color {
        switch self {
        case .coding: Color(red: 0.45, green: 0.62, blue: 1.0)
        case .writing: Color(red: 0.98, green: 0.72, blue: 0.36)
        case .design: Color(red: 0.95, green: 0.45, blue: 0.75)
        case .meeting: Color(red: 0.36, green: 0.84, blue: 0.56)
        case .communicating: Color(red: 0.36, green: 0.82, blue: 0.9)
        case .research: Color(red: 0.62, green: 0.52, blue: 1.0)
        case .planning: Color(red: 1.0, green: 0.62, blue: 0.38)
        case .media: Color(red: 0.95, green: 0.36, blue: 0.42)
        case .reading: Color(red: 0.72, green: 0.84, blue: 0.4)
        case .other: Color(white: 0.62)
        case .idle: Color(white: 0.3)
        }
    }
}
