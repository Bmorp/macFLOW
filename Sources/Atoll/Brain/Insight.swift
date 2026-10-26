import Foundation
import SwiftUI

/// The Brain's understanding, condensed from raw observations: how today is going, every project you work on,
/// what's left open, and your taste in music by kind of work. Built off the main thread every few minutes, so
/// everything that reads it — suggestions, the island, the Brain's answers, Settings — gets it for free.
struct Insight: Sendable {
    struct Project: Identifiable, Sendable {
        var id: String { name }
        let name: String
        var today: TimeInterval = 0
        var week: TimeInterval = 0
        var lastSeen: Date = .distantPast
        var activeDays = 0
        /// Apps you use for it, most-used first (bundle identifiers).
        var apps: [String] = []
        var appNames: [String] = []
        /// Recent window titles: documents, files, pages.
        var documents: [String] = []
        /// Its usual kind of work.
        var mode: WorkMode = .other
    }

    struct Taste: Sendable {
        var plays = 0
        var skipRate = 0.0
        var topArtists: [(name: String, plays: Int)] = []
        /// Artists you choose while doing each kind of work, most-played first.
        var byMode: [WorkMode: [String]] = [:]
        /// Plays by hour of the day.
        var hours = [Int](repeating: 0, count: 24)
        var topSource: String?
    }

    var computedAt = Date.distantPast
    /// Seconds today per kind of work, largest first.
    var modes: [(mode: WorkMode, seconds: TimeInterval)] = []
    /// Today hour by hour: the main kind of work in each hour, and how much of the hour was active.
    var hours: [(mode: WorkMode, fraction: Double)?] = Array(repeating: nil, count: 24)
    var activeToday: TimeInterval = 0
    var deepToday: TimeInterval = 0
    var projects: [Project] = []
    var taste = Taste()

    static let empty = Insight()
}

/// One thing that's unfinished and worth coming back to.
struct OpenLoop: Identifiable, Equatable {
    enum Kind: String { case claude, resume, meeting }
    let id: String
    let kind: Kind
    let symbol: String
    let title: String
    let detail: String
    let action: BrainAction
}

@MainActor
final class InsightModel: ObservableObject {
    static let shared = InsightModel()

    @Published private(set) var insight = Insight.empty
    @Published private(set) var computing = false
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 5 * 60, repeats: true) { _ in MainActor.assumeIsolated { InsightModel.shared.refresh() } }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Recompute in the background. Cheap to call; overlapping calls collapse into one.
    func refresh() {
        guard !computing, Prefs.shared.brainLevel != BrainLevel.off.rawValue else { return }
        computing = true
        let overrides = Self.overrides()
        let known = ClaudeSessions.shared.sessions.map(\.folder)
        DispatchQueue.global(qos: .utility).async {
            let result = Self.compute(store: .shared, overrides: overrides, known: known)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = InsightModel.shared
                    me.computing = false
                    me.insight = result
                }
            }
        }
    }

    private static func overrides() -> [String: WorkMode] {
        var out: [String: WorkMode] = [:]
        for f in BrainStore.shared.facts() where f.key.hasPrefix("mode:") {
            out[String(f.key.dropFirst(5))] = WorkMode(rawValue: f.value)
        }
        return out
    }

    // MARK: Computing

    nonisolated static func compute(store: BrainStore, overrides: [String: WorkMode], known: [String]) -> Insight {
        var out = Insight()
        out.computedAt = Date()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        let weekStart = dayStart.addingTimeInterval(-6 * 86_400)

        // Work: every foreground stretch of the past week.
        let stretches = store.events(since: weekStart, kinds: ["app"], limit: 30_000)
        var modeTime: [WorkMode: TimeInterval] = [:]
        var hourModes = Array(repeating: [WorkMode: TimeInterval](), count: 24)
        var projects: [String: Insight.Project] = [:]
        var projectApps: [String: [String: TimeInterval]] = [:]
        var projectModes: [String: [WorkMode: TimeInterval]] = [:]
        var projectDays: [String: Set<Int>] = [:]
        var names: [String: String] = [:]

        for e in stretches where !e.bundle.isEmpty {
            let mode = Understanding.mode(bundle: e.bundle, title: e.title, overrides: overrides)
            let d = min(e.duration, 3 * 3600)
            names[e.bundle] = e.app
            if e.ts >= dayStart, mode != .idle {
                modeTime[mode, default: 0] += d
                // Spread the stretch over the hours it covers.
                var t = e.ts, left = d
                while left > 0 {
                    let h = cal.component(.hour, from: t)
                    let hourEnd = cal.date(bySettingHour: h, minute: 59, second: 59, of: t) ?? t
                    let chunk = min(left, max(1, hourEnd.timeIntervalSince(t) + 1))
                    hourModes[h][mode, default: 0] += chunk
                    left -= chunk
                    t = t.addingTimeInterval(chunk)
                    if cal.component(.hour, from: t) < h { break }   // crossed midnight
                }
            }
            let name = e.detail.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count < 60 else { continue }
            var p = projects[name] ?? Insight.Project(name: name)
            p.week += d
            if e.ts >= dayStart { p.today += d }
            p.lastSeen = max(p.lastSeen, e.ts.addingTimeInterval(d))
            if !e.title.isEmpty, !p.documents.contains(e.title), p.documents.count < 6 { p.documents.append(e.title) }
            projects[name] = p
            projectApps[name, default: [:]][e.bundle, default: 0] += d
            projectModes[name, default: [:]][mode, default: 0] += d
            projectDays[name, default: []].insert(cal.ordinality(of: .day, in: .era, for: e.ts) ?? 0)
        }

        out.modes = modeTime.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        out.activeToday = modeTime.values.reduce(0, +)
        out.deepToday = modeTime.filter { $0.key.isDeepWork }.values.reduce(0, +)
        for h in 0..<24 {
            let total = hourModes[h].values.reduce(0, +)
            if total > 60, let top = hourModes[h].max(by: { $0.value < $1.value }) {
                out.hours[h] = (top.key, min(1, total / 3600))
            }
        }
        out.projects = projects.values.map { p in
            var p = p
            let apps = (projectApps[p.name] ?? [:]).sorted { $0.value > $1.value }.map(\.key)
            p.apps = Array(apps.prefix(4))
            p.appNames = p.apps.compactMap { names[$0] }
            p.mode = (projectModes[p.name] ?? [:]).max(by: { $0.value < $1.value })?.key ?? .other
            p.activeDays = projectDays[p.name]?.count ?? 0
            return p
        }
        .filter { $0.week >= 5 * 60 }
        .sorted { a, b in a.today != b.today ? a.today > b.today : a.lastSeen > b.lastSeen }

        // Taste: what you played over the past month, and around which kind of work.
        let plays = store.events(since: dayStart.addingTimeInterval(-30 * 86_400), kinds: ["media", "skip"], limit: 8000)
        var artistPlays: [String: Int] = [:]
        var byMode: [WorkMode: [String: Int]] = [:]
        var sources: [String: Int] = [:]
        var skips = 0, total = 0
        for e in plays {
            if e.kind == "skip" { skips += 1; continue }
            let parts = e.detail.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let artist = parts.first ?? ""
            guard !artist.isEmpty else { continue }
            total += 1
            artistPlays[artist, default: 0] += 1
            if parts.count > 3, let m = WorkMode(rawValue: parts[3]) { byMode[m, default: [:]][artist, default: 0] += 1 }
            if !e.app.isEmpty { sources[e.app, default: 0] += 1 }
            out.taste.hours[cal.component(.hour, from: e.ts)] += 1
        }
        out.taste.plays = total
        out.taste.skipRate = total > 0 ? Double(skips) / Double(total) : 0
        out.taste.topArtists = artistPlays.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }
        out.taste.byMode = byMode.mapValues { $0.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.map(\.key) }.filter { !$0.value.isEmpty }
        out.taste.topSource = sources.max(by: { $0.value < $1.value })?.key
        return out
    }

    // MARK: Open loops (live state + insight; cheap, main thread)

    var loops: [OpenLoop] {
        var out: [OpenLoop] = []
        for s in ClaudeSessions.shared.sessions where s.state == .waiting {
            out.append(OpenLoop(id: "claude:\(s.id)", kind: .claude, symbol: "asterisk",
                                title: "Claude is waiting on you", detail: "\(s.name) · \(s.folder)", action: .openClaude))
        }
        if let e = CalendarModel.shared.events.first(where: { !$0.isAllDay && $0.start > Date() && $0.start.timeIntervalSinceNow < 2 * 3600 }) {
            out.append(OpenLoop(id: "meeting:\(e.id)", kind: .meeting, symbol: "calendar",
                                title: e.title, detail: "\(CalendarModel.relative(e))",
                                action: e.meetingURL.map { .joinMeeting($0) } ?? .none))
        }
        let now = Date()
        for p in insight.projects.prefix(12) where p.today == 0 && p.week >= 45 * 60 {
            let ago = now.timeIntervalSince(p.lastSeen)
            guard ago > 2 * 3600, ago < 4 * 86_400, !p.apps.isEmpty else { continue }
            out.append(OpenLoop(id: "resume:\(p.name)", kind: .resume, symbol: "arrow.uturn.forward",
                                title: "Pick up \(p.name)", detail: "Last worked on \(Self.ago(p.lastSeen)) · \(BrainEngine.duration(p.week)) this week",
                                action: RoomStore.shared.projectRoom(p.name).map { .resumeRoom($0.key) } ?? .openApps(p.apps)))
            if out.filter({ $0.kind == .resume }).count >= 3 { break }
        }
        return out
    }

    static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
