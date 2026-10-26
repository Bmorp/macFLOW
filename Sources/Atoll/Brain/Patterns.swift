import Foundation
import SwiftUI

/// What Flow has learned about how you work — from four weeks of your own sessions, on this Mac. Not what you did
/// today (that's Insight) but your rhythm: the hours your focus is sharpest, when your day usually starts and ends,
/// how long your focus lasts, whether music helps, when you get scattered. Flow plans and nudges by it.
struct Patterns: Codable, Equatable {
    var computed = Date.distantPast
    /// Days with any activity in the window.
    var days = 0
    /// Average minutes of deep work per active day, by hour (0–23).
    var focusByHour = [Double](repeating: 0, count: 24)
    /// App switches per active day, by hour.
    var switchesByHour = [Double](repeating: 0, count: 24)
    /// The best stretch for focus: start and end hour (end exclusive).
    var bestStart: Int?
    var bestEnd: Int?
    /// Minutes after midnight: when the first and last activity of a day usually is (medians).
    var dayStart: Int?
    var dayEnd: Int?
    /// Median length of a deep-work session, in minutes.
    var focusLength: Double = 0
    /// How much longer deep sessions run with music than without (1.3 = 30% longer); nil until there's enough of both.
    var musicLift: Double?
    /// The hour when you switch apps most (scattered).
    var scatteredHour: Int?
    /// The weekday (1 = Sunday) with the most meetings.
    var meetingDay: Int?
    /// Plain sentences, for Flow and for Settings.
    var insights: [String] = []

    var isReady: Bool { days >= 3 }

    /// "9–11:30" style.
    static func hours(_ start: Int, _ end: Int) -> String {
        func h(_ x: Int) -> String {
            let d = Calendar.current.date(bySettingHour: x % 24, minute: 0, second: 0, of: Date()) ?? Date()
            return d.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
        }
        return "\(h(start))–\(h(end))"
    }

    /// One session of the past, as learning sees it.
    struct Session: Equatable {
        let start: Date
        let end: Date
        let mode: WorkMode
    }

    /// The learning itself — pure, so it's tested.
    static func compute(sessions: [Session], music: [Date], switches: [Date], now: Date, calendar: Calendar = .current) -> Patterns {
        var p = Patterns(computed: now)
        let byDay = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.start) }
        p.days = byDay.count
        guard p.days > 0 else { return p }
        let n = Double(p.days)

        // Deep work by hour: split each deep session across the hours it covers.
        for s in sessions where s.mode.isDeepWork {
            var t = s.start
            while t < s.end {
                let hourEnd = calendar.dateInterval(of: .hour, for: t)?.end ?? s.end
                let slice = min(hourEnd, s.end).timeIntervalSince(t)
                p.focusByHour[calendar.component(.hour, from: t)] += slice / 60 / n
                t = hourEnd
            }
        }
        for sw in switches { p.switchesByHour[calendar.component(.hour, from: sw)] += 1 / n }

        // The best focus window: the 2–3 hour stretch with the most deep work.
        var best: (start: Int, len: Int, score: Double)?
        for len in [2, 3] {
            for start in 6...(22 - len) {
                let score = (start..<(start + len)).reduce(0) { $0 + p.focusByHour[$1] } / Double(len)
                if score > (best?.score ?? 0) * (len == 3 ? 1.12 : 1) { best = (start, len, score) }
            }
        }
        if let best, best.score >= 12 {   // at least ~12 minutes of focus per hour on average
            p.bestStart = best.start
            p.bestEnd = best.start + best.len
        }

        // When the day starts and ends.
        func median(_ v: [Double]) -> Double? { let s = v.sorted(); return s.isEmpty ? nil : s[s.count / 2] }
        let starts = byDay.values.compactMap { $0.map(\.start).min() }.map { Double(calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0)) }
        let ends = byDay.values.compactMap { $0.map(\.end).max() }.map { Double(calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0)) }
        p.dayStart = median(starts).map(Int.init)
        p.dayEnd = median(ends).map(Int.init)

        // How long focus lasts, and whether music helps.
        let deep = sessions.filter { $0.mode.isDeepWork && $0.end.timeIntervalSince($0.start) >= 10 * 60 }
        p.focusLength = median(deep.map { $0.end.timeIntervalSince($0.start) / 60 }) ?? 0
        let sortedMusic = music.sorted()
        func hasMusic(_ s: Session) -> Bool {
            // A track starting during the session, or within ten minutes before it.
            let lo = s.start.addingTimeInterval(-600)
            guard let i = sortedMusic.firstIndex(where: { $0 >= lo }) else { return false }
            return sortedMusic[i] <= s.end
        }
        let with = deep.filter(hasMusic).map { $0.end.timeIntervalSince($0.start) }
        let without = deep.filter { !hasMusic($0) }.map { $0.end.timeIntervalSince($0.start) }
        if with.count >= 4, without.count >= 4, let a = median(with), let b = median(without), b > 0 { p.musicLift = a / b }

        // When you're most scattered (only if it stands out).
        if let maxSw = p.switchesByHour.enumerated().filter({ (6...22).contains($0.offset) }).max(by: { $0.element < $1.element }),
           maxSw.element >= 12, maxSw.element > 1.6 * (p.switchesByHour[6...22].reduce(0, +) / 17) {
            p.scatteredHour = maxSw.offset
        }

        // The meeting-heaviest weekday.
        var meetingsByDay = [Int: Double]()
        for s in sessions where s.mode == .meeting { meetingsByDay[calendar.component(.weekday, from: s.start), default: 0] += s.end.timeIntervalSince(s.start) }
        if let top = meetingsByDay.max(by: { $0.value < $1.value }), top.value >= 3600, meetingsByDay.count >= 2 { p.meetingDay = top.key }

        p.insights = p.sentences()
        return p
    }

    /// What it all means, in words.
    func sentences() -> [String] {
        guard isReady else { return [] }
        var out: [String] = []
        if let s = bestStart, let e = bestEnd { out.append("Your focus is sharpest \(Self.hours(s, e)).") }
        if focusLength >= 10 { out.append("A focus session usually lasts about \(Int(focusLength.rounded())) minutes.") }
        if let lift = musicLift {
            if lift >= 1.15 { out.append("You stay focused \(Int(((lift - 1) * 100).rounded()))% longer with music on.") }
            else if lift <= 0.87 { out.append("You focus longer in silence — about \(Int(((1 / lift - 1) * 100).rounded()))% longer without music.") }
        }
        if let h = scatteredHour { out.append("Around \(Self.hours(h, h + 1).components(separatedBy: "–").first ?? "") you switch apps the most.") }
        if let ds = dayStart, let de = dayEnd {
            let f = { (m: Int) in (Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()).formatted(date: .omitted, time: .shortened) }
            out.append("Your day usually runs \(f(ds))–\(f(de)).")
        }
        if let d = meetingDay { out.append("\(Calendar.current.weekdaySymbols[d - 1])s carry the most meetings.") }
        return out
    }
}

// MARK: - The model

@MainActor
final class PatternsModel: ObservableObject {
    static let shared = PatternsModel()
    @Published private(set) var patterns: Patterns
    private var computing = false
    private var timer: Timer?
    private static let file = "patterns.json"

    init() {
        patterns = Storage.load(Patterns.self, from: Self.file) ?? Patterns()
    }

    func start() {
        guard timer == nil else { return }
        if Date().timeIntervalSince(patterns.computed) > 6 * 3600 { refresh() }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { _ in MainActor.assumeIsolated { PatternsModel.shared.refresh() } }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Four weeks of sessions, learned off the main thread.
    func refresh() {
        guard !computing, Prefs.shared.brainLevel != BrainLevel.off.rawValue else { return }
        computing = true
        DispatchQueue.global(qos: .utility).async {
            let since = Date().addingTimeInterval(-28 * 86_400)
            let store = BrainStore.shared
            let sessions = store.episodes(since: since, limit: 4000).compactMap { e -> Patterns.Session? in
                guard let m = WorkMode(rawValue: e.mode), m != .idle, e.end > e.start else { return nil }
                return Patterns.Session(start: e.start, end: e.end, mode: m)
            }
            let events = store.events(since: since, kinds: ["media", "app"], limit: 40_000)
            let p = Patterns.compute(sessions: sessions, music: events.filter { $0.kind == "media" }.map(\.ts),
                                     switches: events.filter { $0.kind == "app" }.map(\.ts), now: Date())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = PatternsModel.shared
                    me.computing = false
                    me.patterns = p
                    Storage.save(p, to: Self.file)
                }
            }
        }
    }

    /// For the planner: when to put the most important thing today (nil if there's no clear best window).
    func bestWindow(on day: Date) -> DateInterval? {
        guard patterns.isReady, let s = patterns.bestStart, let e = patterns.bestEnd,
              let a = Calendar.current.date(bySettingHour: s, minute: 0, second: 0, of: day),
              let b = Calendar.current.date(bySettingHour: e, minute: 0, second: 0, of: day) else { return nil }
        return DateInterval(start: a, end: b)
    }

    #if DEBUG
    func debugSet(_ p: Patterns) { patterns = p }
    #endif
}

/// Deep work by hour, as 24 quiet bars — the shape of your days.
struct FocusRhythm: View {
    let patterns: Patterns
    var height: CGFloat = 44

    var body: some View {
        let top = max(1, patterns.focusByHour.max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { h in
                    let inBest = (patterns.bestStart.map { h >= $0 } ?? false) && (patterns.bestEnd.map { h < $0 } ?? false)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(inBest ? BrainStyle.tint : Color.secondary.opacity(0.45))
                        .frame(height: max(2, height * patterns.focusByHour[h] / top))
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack {
                Text("12a"); Spacer(); Text("6a"); Spacer(); Text("12p"); Spacer(); Text("6p"); Spacer(); Text("12a")
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(patterns.insights.first ?? "Focus by hour")
    }
}
