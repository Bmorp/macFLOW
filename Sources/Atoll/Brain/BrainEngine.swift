import AppKit
import SwiftUI
import Combine

/// Something the Brain can do for you — a fixed, safe set. The engine picks; nothing else ever runs.
enum BrainAction: Equatable {
    case openApps([String])
    case joinMeeting(URL)
    case startTimer(minutes: Int, label: String)
    case askClaude(prompt: String, title: String)
    case openClaude
    case ask(String)                    // ask the Brain itself (opens the answer panel)
    case resumeMusic
    case playArtist(String)
    case openSettings
    case openPlan                       // the day planner in the island
    case setRoom(title: String, minutes: Int)   // a block's room: documents, music, Focus, timer
    case resumeRoom(String)             // a saved room, by key
    case openRewind                     // scrub back through today
    case openDay                        // the day, drawn
    case addToTomorrow([String], from: String)   // carry into tomorrow's plan
    case openFile(URL)                  // e.g. meeting notes
    case none
}

struct BrainSuggestion: Equatable, Identifiable {
    var id = UUID()
    let kind: String                    // feedback key, e.g. "resume", "break"
    let symbol: String
    let title: String
    let detail: String                  // what it's based on, in plain words
    let actionTitle: String
    let action: BrainAction
    let confidence: Double
    /// What it points at (an app, a project, an artist): the learner tells "Figma after Slack" from "Mail after Slack".
    var target: String? = nil
    /// One line on why Flow showed it now, from what it has learned ("You took 3 of 4 like this in the afternoon").
    var why: String = ""
}

struct BrainQuestion: Equatable, Identifiable {
    var id = UUID()
    let key: String                     // the fact it answers
    let text: String
    let detail: String
    let options: [Option]
    struct Option: Equatable, Hashable { let label: String; let value: String }
}

/// The engine: senses → candidates with evidence → a learned policy decides which are worth an interruption
/// (`SuggestionPolicy`) → shown, inside hard rails (quiet times, an hourly cap, cooldowns). Questions are chosen by
/// what Flow is least sure of and most needs to know (`QuestionBank`), and each answer trains it at once.
@MainActor
final class BrainEngine: ObservableObject {
    static let shared = BrainEngine()

    @Published private(set) var lastSuggestion: BrainSuggestion?
    @Published private(set) var thinking = false

    private let store = BrainStore.shared
    private let context = WorkContext.shared
    private let policy = SuggestionPolicy.shared
    private var cooldowns: [String: Date] = [:]
    private var lastPop = Date.distantPast
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var lastMeetingID: String?
    /// Questions on show, by key, so an answer finds what it was about.
    private var asking: [String: QuestionProbe] = [:]
    /// The slower parts of what questions look at (a week of app time and modes), refreshed off the main thread.
    private var weekModes: [WorkMode: Double] = [:]
    private var weekApps: [(bundle: String, name: String, minutes: Double)] = []
    private var guesses: [String: WorkMode] = [:]
    private var worldAt = Date.distantPast
    private var lastScan = Date.distantPast
    private var lastConsidered = Date.distantPast

    private var installedAt: Date {
        if let s = store.fact("brain:installed"), let t = Double(s) { return Date(timeIntervalSince1970: t) }
        store.setFact("brain:installed", "\(Date().timeIntervalSince1970)", source: "inferred", confidence: 1)
        return Date()
    }
    /// The first week is for learning: more questions, a slightly lower bar.
    private var learning: Bool { Date().timeIntervalSince(installedAt) < 7 * 86_400 }

    func start() {
        guard !started else { return }
        started = true
        _ = installedAt
        context.onChange = { [weak self] change in self?.handle(change) }
        context.start()
        MomentRecorder.shared.start()
        PatternsModel.shared.start()
        MemoryKeeper.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { Habits.shared.train() }
        LensModel.shared.start()
        ScreenSensor.shared.start()
        InsightModel.shared.start()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)
        timer = t
        store.purge(olderThan: Prefs.shared.brainRetentionDays)
        // What you did with suggestions before this policy existed still counts.
        policy.adoptHistory()
        ModeCorrections.shared.onChange = { WorkContext.shared.correctionsChanged() }
        TaskBrain.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { BrainEngine.shared.refreshWeek() }
    }

    // MARK: Triggers

    private func handle(_ change: WorkContext.Change) {
        switch change {
        case .returned(let away):
            if away >= 20 * 60 { offer(resume(after: away)) } else if away >= 5 * 60 { offerHabit() }
            // Back from a pause: a good moment to recall something (if a card is due and nothing else spoke up).
            if away >= 3 * 60 { DispatchQueue.main.asyncAfter(deadline: .now() + 20) { LearnStore.shared.quizIfQuiet() } }
            // …or to ask what Flow most needs to know, if nothing else did.
            if away >= 3 * 60 { DispatchQueue.main.asyncAfter(deadline: .now() + 45) { BrainEngine.shared.considerAsking() } }
        case .modeChanged(let from, let to, let after):
            if from == .meeting, to != .meeting, after >= 5 * 60 { offer(backToWork()) }
            if from == .meeting || from == .communicating { offerHabit() }
            if to != .meeting, to != .idle { considerAsking() }
        case .appOpened(let bundle):
            offer(routine(after: bundle))
            guessApp(bundle)
        case .clipboard(let kind):
            if kind == "error", context.mode == .coding { offer(errorHelp()) }
        case .episodeEnded:
            considerAsking()
        }
    }

    private func tick() {
        guard context.level != .off else { return }
        if Date().timeIntervalSince(Habits.shared.trainedAt) > 4 * 3600 { Habits.shared.train() }
        offer(meetingSoon())
        offer(longStretch())
        offer(protectFocus())
        offer(focusMusic())
        offer(endOfDay())
        if Date().timeIntervalSince(lastScan) > 10 * 60 {
            lastScan = Date()
            TaskBrain.shared.scan()
        }
        if Date().timeIntervalSince(worldAt) > 30 * 60 { refreshWeek() }
        // A task that looks done is worth asking about while it's fresh — at a light moment, not mid-stretch.
        if !context.mode.isDeepWork || context.modeDuration < 2 * 60 { considerAsking() }
    }

    // MARK: Candidates

    /// Back after a while: pick up the work you left.
    private func resume(after away: TimeInterval) -> BrainSuggestion? {
        guard let ep = store.episodes(since: Date().addingTimeInterval(-18 * 3600), limit: 10)
            .first(where: { WorkMode(rawValue: $0.mode)?.isDeepWork ?? false }) else { return nil }
        let apps = ep.apps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        guard !apps.isEmpty else { return nil }
        let morning = Calendar.current.component(.hour, from: Date()) < 12 && away > 4 * 3600
        let name = ep.project.isEmpty ? (WorkMode(rawValue: ep.mode)?.label.lowercased() ?? "work") : ep.project
        let names = apps.prefix(3).compactMap { context.appNames[$0] ?? Self.appName($0) }
        // With the project's room saved, continuing means exactly where you were — documents and all.
        if !ep.project.isEmpty, let room = RoomStore.shared.projectRoom(ep.project) {
            return BrainSuggestion(kind: "resume", symbol: "arrow.uturn.forward",
                                   title: morning ? "Good morning — continue \(name)?" : "Pick up \(name)?",
                                   detail: "Right where you left it · \(room.summary)",
                                   actionTitle: "Continue", action: .resumeRoom(room.key), confidence: 0.8, target: ep.project)
        }
        return BrainSuggestion(kind: "resume", symbol: "arrow.uturn.forward",
                               title: morning ? "Good morning — continue \(name)?" : "Pick up \(name)?",
                               detail: "You were \(ep.summary.lowercased()) · opens \(names.joined(separator: ", "))",
                               actionTitle: "Continue", action: .openApps(apps), confidence: 0.75, target: ep.project.isEmpty ? apps.first : ep.project)
    }

    /// At a turning point (back from a break, out of a meeting or messages): what you usually do next from a moment like
    /// this — learned from your own history — offered only when the similar moments mostly agree.
    private func offerHabit() {
        let ctx = context
        Habits.shared.predict(app: ctx.appName, bundle: ctx.bundle, title: ctx.title, project: ctx.project ?? "", mode: ctx.mode.rawValue) { p in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let p, p.confidence >= 0.6, p.support >= 6,
                          NSWorkspace.shared.frontmostApplication?.bundleIdentifier != p.bundle else { return }
                    let room = p.project.isEmpty ? nil : RoomStore.shared.projectRoom(p.project)
                    let s = BrainSuggestion(kind: "habit", symbol: "arrow.triangle.turn.up.right.circle.fill",
                                            title: room != nil ? "Back to \(p.project)?" : "Open \(p.name)?",
                                            detail: "What you usually do now · \(Int(p.confidence * 100))% of moments like this",
                                            actionTitle: "Open", action: room.map { .resumeRoom($0.key) } ?? .openApps([p.bundle]),
                                            confidence: min(0.9, p.confidence), target: p.bundle)
                    BrainEngine.shared.offerFromHabit(s)
                }
            }
        }
    }

    fileprivate func offerFromHabit(_ s: BrainSuggestion) { offer(s) }

    /// A meeting ended: back to what you were doing before it.
    private func backToWork() -> BrainSuggestion? {
        guard let ep = store.episodes(since: Date().addingTimeInterval(-4 * 3600), limit: 8)
            .first(where: { $0.mode != WorkMode.meeting.rawValue && (WorkMode(rawValue: $0.mode)?.isDeepWork ?? false) }) else { return nil }
        let apps = ep.apps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        guard !apps.isEmpty else { return nil }
        return BrainSuggestion(kind: "back", symbol: "arrow.uturn.backward",
                               title: "Back to \(ep.project.isEmpty ? "work" : ep.project)?",
                               detail: "Before the meeting you were \(ep.summary.lowercased())",
                               actionTitle: "Resume", action: RoomStore.shared.projectRoom(ep.project).map { .resumeRoom($0.key) } ?? .openApps(apps),
                               confidence: 0.7, target: ep.project.isEmpty ? apps.first : ep.project)
    }

    /// A meeting is close while you're deep in something.
    private func meetingSoon() -> BrainSuggestion? {
        guard let e = CalendarModel.shared.events.first(where: { !$0.isAllDay && $0.start > Date() && $0.start.timeIntervalSinceNow <= 10 * 60 }),
              e.id != lastMeetingID, context.mode.isDeepWork, context.modeDuration >= 20 * 60 else { return nil }
        lastMeetingID = e.id
        let mins = max(1, Int(e.start.timeIntervalSinceNow / 60))
        let deep = Self.duration(context.modeDuration)
        if let url = e.meetingURL, mins <= 2 {
            return BrainSuggestion(kind: "meeting", symbol: "video.fill", title: "\(e.title) is starting",
                                   detail: "You’ve been \(context.mode.label.lowercased()) for \(deep)", actionTitle: "Join",
                                   action: .joinMeeting(url), confidence: 0.85)
        }
        return BrainSuggestion(kind: "meeting", symbol: "calendar.badge.clock", title: "\(e.title) in \(mins) min",
                               detail: "You’ve been \(context.mode.label.lowercased())\(context.project.map { " on \($0)" } ?? "") for \(deep) — a timer to wrap up?",
                               actionTitle: "Wrap-Up Timer", action: .startTimer(minutes: max(1, mins - 1), label: "Wrap up"), confidence: 0.72)
    }

    /// A long stretch without a pause.
    private func longStretch() -> BrainSuggestion? {
        guard context.mode.isDeepWork, context.modeDuration >= 90 * 60, !FocusTimer.shared.isActive else { return nil }
        // As long as you said you like them (five minutes until you do).
        let minutes = store.fact("pref:break.minutes").flatMap(Int.init) ?? 5
        return BrainSuggestion(kind: "break", symbol: "figure.walk",
                               title: "\(Self.duration(context.modeDuration)) of \(context.mode.label.lowercased()) — a short break?",
                               detail: "A \(minutes)-minute pause keeps the next hour sharp",
                               actionTitle: "\(minutes)-Min Break", action: .startTimer(minutes: minutes, label: "Break"), confidence: 0.6)
    }

    /// Focus is fragmenting: lots of switching away from deep work.
    private func protectFocus() -> BrainSuggestion? {
        guard context.mode.isDeepWork, context.modeDuration >= 25 * 60, context.switchesLast15Minutes >= 14, !FocusTimer.shared.isActive else { return nil }
        return BrainSuggestion(kind: "focus", symbol: "scope",
                               title: "Protect the next 25 minutes?",
                               detail: "\(context.switchesLast15Minutes) app switches in the last 15 minutes",
                               actionTitle: "Start Focus", action: .startTimer(minutes: 25, label: "Focus"), confidence: 0.58)
    }

    /// You copied an error while building.
    private func errorHelp() -> BrainSuggestion? {
        guard let text = context.consumeError() else { return nil }
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        return BrainSuggestion(kind: "error", symbol: "ladybug.fill", title: "Want help with that error?",
                               detail: String(first.prefix(70)), actionTitle: "Ask Claude",
                               action: .askClaude(prompt: "I'm getting this error. Explain the likely cause and the fix, briefly:\n\n\(text)", title: "Explain this error"),
                               confidence: 0.7)
    }

    /// App → (the app you usually open next, how often, out of how many). Learned in the background.
    private var routines: [String: (next: String, count: Int, times: Int)] = [:]
    private var routinesLearnedAt = Date.distantPast

    private func learnRoutines() {
        guard Date().timeIntervalSince(routinesLearnedAt) > 30 * 60 else { return }
        routinesLearnedAt = Date()
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            let list = Array(store.events(since: Date().addingTimeInterval(-30 * 86_400), kinds: ["app"], limit: 6000).reversed())
                .filter { !$0.bundle.isEmpty }
            var follows: [String: [String: Int]] = [:]
            var times: [String: Int] = [:]
            for (i, e) in list.enumerated() {
                times[e.bundle, default: 0] += 1
                var seen = Set<String>()
                var k = i + 1
                while k < list.count, list[k].ts.timeIntervalSince(e.ts) < 180 {
                    if list[k].bundle != e.bundle, seen.insert(list[k].bundle).inserted { follows[e.bundle, default: [:]][list[k].bundle, default: 0] += 1 }
                    k += 1
                }
            }
            var result: [String: (String, Int, Int)] = [:]
            for (app, nexts) in follows {
                if let best = nexts.max(by: { $0.value < $1.value }) { result[app] = (best.key, best.value, times[app] ?? 0) }
            }
            DispatchQueue.main.async { BrainEngine.shared.routines = result.mapValues { (next: $0.0, count: $0.1, times: $0.2) } }
        }
    }

    /// You usually open B right after A.
    private func routine(after bundle: String) -> BrainSuggestion? {
        learnRoutines()
        guard let r = routines[bundle] else { return nil }
        let (next, count, times) = (r.next, r.count, r.times)
        guard times >= 6, Double(count) / Double(times) >= 0.7,
              NSRunningApplication.runningApplications(withBundleIdentifier: next).isEmpty,
              let nextName = Self.appName(next), let thisName = Self.appName(bundle) else { return nil }
        return BrainSuggestion(kind: "routine", symbol: "arrow.triangle.branch",
                               title: "Open \(nextName) too?",
                               detail: "You open it after \(thisName) \(Int(Double(count) / Double(times) * 100))% of the time",
                               actionTitle: "Open", action: .openApps([next]), confidence: 0.55 + 0.3 * Double(count) / Double(times),
                               target: next, why: "You usually open \(nextName) after \(thisName)")
    }

    /// Music that suits the moment, when you usually have it.
    private func focusMusic() -> BrainSuggestion? {
        guard context.mode == .coding || context.mode == .writing, context.modeDuration >= 10 * 60, context.modeDuration < 25 * 60,
              !NowPlayingModel.shared.isPlaying, store.fact("pref:music.\(context.mode.rawValue)") != "no" else { return nil }
        // Taste, learned in the background: the artists you pick for this kind of work.
        let favourites = InsightModel.shared.insight.taste.byMode[context.mode] ?? []
        guard !favourites.isEmpty || store.fact("pref:music.\(context.mode.rawValue)") == "yes" else { return nil }
        let doing = context.mode.label.lowercased()
        if let artist = favourites.first {
            let also = favourites.dropFirst().prefix(2)
            return BrainSuggestion(kind: "music", symbol: "music.note",
                                   title: "\(artist) for \(doing)?",
                                   detail: also.isEmpty ? "What you usually play while \(doing)" : "Your \(doing) music · also \(also.joined(separator: ", "))",
                                   actionTitle: "Play", action: .playArtist(artist), confidence: 0.64, target: artist)
        }
        return BrainSuggestion(kind: "music", symbol: "music.note", title: "Some music for \(doing)?",
                               detail: "You said you like music while you work",
                               actionTitle: "Play", action: .resumeMusic, confidence: 0.58)
    }

    /// Evening, after a real day's work.
    private func endOfDay() -> BrainSuggestion? {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 18, hour < 23 else { return nil }
        let worked = InsightModel.shared.insight.activeToday
        guard worked >= 4 * 3600 else { return nil }
        return BrainSuggestion(kind: "day", symbol: "sun.horizon.fill", title: "Want a quick recap of today?",
                               detail: "\(Self.duration(worked)) of work across your apps",
                               actionTitle: "Recap", action: .ask("Give me a short recap of my day: what I worked on, for how long, and anything left open."),
                               confidence: 0.55)
    }

    // MARK: Questions

    /// A quiet moment: ask the one thing Flow most needs to know, if anything's worth it. Never by chance — by
    /// uncertainty × impact (`QuestionBank`), within a daily budget, never the same question twice unless its
    /// answer has gone stale.
    func considerAsking() {
        guard !quiet, Date().timeIntervalSince(lastPop) >= 10 * 60, Date().timeIntervalSince(lastConsidered) >= 4 * 60,
              !FlowInbox.shared.items.contains(where: \.isQuestion) else { return }
        lastConsidered = Date()
        guard let p = QuestionBank.choose(world()) else { return }
        guard FlowInbox.shared.ask(p.question) else { return }   // already waiting for you
        asking[p.key] = p
        store.noteQuestion(p.key, asked: Date())
        lastPop = Date()
    }

    /// What the question bank looks at, now.
    func world(now: Date = Date()) -> QuestionWorld {
        var w = QuestionWorld(now: now, learning: learning, policy: policy)
        w.facts = Dictionary(store.facts().map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        w.asked = store.askedLog()
        w.modeMinutes = weekModes
        w.unclassified = weekApps.filter { app in
            Understanding.mode(bundle: app.bundle, title: "") == .other && w.facts["mode:\(app.bundle)"]?.source != "answered"
                && !Prefs.shared.brainExcluded.contains(app.bundle)
        }.map { ($0.bundle, $0.name, $0.minutes, guesses[$0.bundle]) }
        w.projects = InsightModel.shared.insight.projects.map { ($0.name, $0.week / 60) }
        let patterns = PatternsModel.shared.patterns
        if patterns.isReady, let s = patterns.bestStart, let e = patterns.bestEnd { w.bestWindow = (s, e) }
        w.patternDays = patterns.days
        w.plansMornings = Prefs.shared.planMorning
        w.levelIsEssentials = context.level == .essentials
        w.taskProbes = TaskBrain.shared.probes(now: now)
        return w
    }

    /// A week of kinds of work and apps, read off the main thread every half hour, for what questions look at.
    func refreshWeek() {
        worldAt = Date()
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            let since = Date().addingTimeInterval(-7 * 86_400)
            var modes: [WorkMode: Double] = [:]
            for ep in store.episodes(since: since, limit: 2000) {
                if let m = WorkMode(rawValue: ep.mode) { modes[m, default: 0] += ep.end.timeIntervalSince(ep.start) / 60 }
            }
            var apps: [String: (name: String, minutes: Double)] = [:]
            for e in store.events(since: since, kinds: ["app"], limit: 20_000) where !e.bundle.isEmpty {
                apps[e.bundle, default: (e.app, 0)].minutes += e.duration / 60
            }
            let list = Array(apps.map { (bundle: $0.key, name: $0.value.name, minutes: $0.value.minutes) }.sorted { $0.minutes > $1.minutes }.prefix(30))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    BrainEngine.shared.weekModes = modes
                    BrainEngine.shared.weekApps = list
                }
            }
        }
    }

    /// An app the rules don't know: on macOS 26, the on-device model makes a first guess, so Flow's question can be a
    /// quick yes ("Is Notion for writing?") rather than a blank one. The guess is held loosely until you confirm it.
    private func guessApp(_ bundle: String) {
        guard Mind.shared.isAvailable, guesses[bundle] == nil, Understanding.mode(bundle: bundle, title: "") == .other,
              store.fact("mode:\(bundle)") == nil, let name = Self.appName(bundle) else { return }
        guesses[bundle] = .other
        let title = context.title
        Task { @MainActor in
            guard let mode = await Mind.shared.classify(app: name, title: title), mode != .other, mode != .idle else { return }
            BrainEngine.shared.guesses[bundle] = mode
        }
    }

    // MARK: Policy

    private var quiet: Bool {
        guard Prefs.shared.brainSuggestions, context.level != .off else { return true }
        if let until = Prefs.shared.brainPausedUntil, until > Date() { return true }
        if context.mode == .meeting || ActivityCenter.shared.call != nil || StandByController.shared.isShowing { return true }
        // In a room (a focus block running): nothing but the plan's own nudges.
        if FocusTimer.shared.phase == .running { return true }
        // An open island isn't a reason to stay quiet any more: the item waits in Flow's inbox (on Home) instead of popping.
        return false
    }

    /// The bar a suggestion's chance of being taken must clear: lower in the first week, while Flow is learning.
    var bar: Double { learning ? 0.42 : 0.5 }

    /// What you told Flow outright: never this kind, or not at this time of day.
    func silenced(_ kind: String, at date: Date = Date()) -> Bool {
        if store.fact("want:\(kind)") == "never" { return true }
        let part = ContextFeatures.Part(hour: Calendar.current.component(.hour, from: date))
        return store.factRecord("want:\(kind)@\(part)").map { $0.value == "no" && !$0.isStale() } ?? false
    }

    private func offer(_ candidate: BrainSuggestion?) {
        guard var s = candidate, !quiet else { return }
        // Hard rails first: cooldowns, a pause between pops, five an hour, and anything you said no to.
        if let until = cooldowns[s.kind], until > Date() { return }
        let gap = Date().timeIntervalSince(lastPop)
        let hourCount = store.suggestionsShown(since: Date().addingTimeInterval(-3600))
        guard gap >= 10 * 60 || s.kind == "meeting", hourCount < 5, !silenced(s.kind) else { return }
        // Then the learned policy: is this one, here, now, worth it?
        let situation = Situation.now()
        let d = policy.decide(kind: s.kind, situation: situation, target: s.target, confidence: s.confidence, bar: bar)
        guard d.show else { return }
        if s.why.isEmpty || d.exploring { s.why = d.why }
        cooldowns[s.kind] = Date().addingTimeInterval(s.kind == "routine" ? 20 * 60 : 75 * 60)
        lastPop = Date()
        lastSuggestion = s
        store.feedback(s.kind, "shown")
        policy.shown(s.id, kind: s.kind, situation: situation, target: s.target, confidence: s.confidence)
        FlowInbox.shared.suggest(s, lasts: s.kind == "meeting" ? 12 * 60 : 30 * 60)
    }

    /// A suggestion that came straight to the inbox (the plan's nudges, meeting notes): learn from it like any other.
    func track(_ s: BrainSuggestion) {
        guard !policy.isTracking(s.id) else { return }
        policy.shown(s.id, kind: s.kind, situation: Situation.now(), target: s.target, confidence: s.confidence)
    }

    /// For the inbox: whether a suggestion that bypassed the engine should pop, or wait quietly on Home — it waits
    /// when you've shown Flow you rarely want that kind.
    func shouldPop(_ s: BrainSuggestion) -> Bool {
        if silenced(s.kind) { return false }
        let b = policy.belief(kind: s.kind, situation: Situation.now(), target: s.target, confidence: s.confidence)
        return b.evidence < 3 || b.p >= bar
    }

    /// The line on a card from the plan or a meeting: what Flow has learned about that kind.
    func why(for s: BrainSuggestion) -> String {
        policy.decide(kind: s.kind, situation: Situation.now(), target: s.target, confidence: s.confidence, bar: 0).why
    }

    // MARK: Outcomes

    func accept(_ s: BrainSuggestion) {
        store.feedback(s.kind, "accepted")
        policy.record(s.id, .accepted)
        perform(s.action)
    }

    func dismiss(_ s: BrainSuggestion) {
        store.feedback(s.kind, "dismissed")
        policy.record(s.id, .dismissed)
        cooldowns[s.kind] = Date().addingTimeInterval(4 * 3600)
        // Music waved away while you'd said you like it then: the answer is wearing thin (and gets asked again sooner).
        if s.kind == "music", let f = store.factRecord("pref:music.\(context.mode.rawValue)"), f.source == "answered", f.value == "yes" {
            store.setFact(f.key, f.value, source: "answered", confidence: f.confidence(at: Date()) * 0.75)
        }
    }

    func ignored(_ s: BrainSuggestion) {
        store.feedback(s.kind, "ignored")
        policy.record(s.id, .ignored)
    }

    /// Replaced by a newer one of its kind, or pushed out of a full inbox: no lesson either way.
    func superseded(_ s: BrainSuggestion) { policy.record(s.id, .superseded) }

    func skip(_ q: BrainQuestion) {
        store.setFact("skipped:\(q.key)", "\(Date().timeIntervalSince1970)", source: "inferred", confidence: 1)
        store.noteQuestion(q.key, skipped: true)
        asking[q.key] = nil
    }

    /// A question ran out unanswered: a soft "not now".
    func expired(_ q: BrainQuestion) {
        store.noteQuestion(q.key, skipped: true)
        asking[q.key] = nil
    }

    /// An answer: a strong label, applied at once. Returns what to say back ("Got it — no more break nudges before 5").
    @discardableResult
    func answer(_ q: BrainQuestion, _ option: BrainQuestion.Option) -> String? {
        HapticEngine.shared.play(.confirm)
        store.noteQuestion(q.key, answer: option.value)
        let probe = asking.removeValue(forKey: q.key) ?? QuestionBank.candidates(world()).first { $0.key == q.key }
        guard let probe else {
            // Not one of Flow's own (the plan's check-in): kept as it was.
            store.setFact(q.key, option.value, source: "answered", confidence: 1)
            if q.key.hasPrefix("plan.checkin"), option.value == "replan" { IslandManager.shared.openPlan() }
            if q.key.hasPrefix("plan.checkin") { return option.value == "behind" ? "Got it — the rest of today, one thing at a time" : "Got it" }
            return nil
        }
        let effect = QuestionBank.effect(of: option, for: probe, world: world())
        apply(effect)
        return effect.acknowledgement
    }

    func apply(_ effect: AnswerEffect) {
        for f in effect.facts { store.setFact(f.key, f.value, source: "answered", confidence: 1) }
        for l in effect.labels { policy.teach(kind: l.kind, situation: l.situation, label: l.y, weight: l.weight, fromAnswer: true) }
        for a in effect.actions {
            switch a {
            case .raiseLevel:
                Prefs.shared.brainLevel = BrainLevel.context.rawValue
                if !InputControl.isTrusted { InputControl.requestTrust() }
            case .completeTask(let id): TaskLinks.ledger?.complete(id)
            case .estimate(let id, let minutes): TaskBrain.shared.applyEstimate(id, minutes: minutes)
            case .doneLabel(let id, let done): TaskBrain.shared.labelDone(id, done: done)
            }
        }
    }

    func perform(_ action: BrainAction) {
        switch action {
        case .openApps(let bundles):
            for b in bundles {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        case .joinMeeting(let url): NSWorkspace.shared.open(url)
        case .startTimer(let m, let label): FocusTimer.shared.start(minutes: m, label: label)
        case .askClaude(let prompt, let title):
            IslandManager.shared.openSearch()
            SearchModel.shared.activate(.ask(prompt: prompt, title: title))
        case .openClaude: ClaudeSessions.shared.open(nil)
        case .ask(let q): askBrain(q)
        case .resumeMusic:
            if NowPlayingModel.shared.hasTrack { NowPlayingModel.shared.playPause() } else { NowPlayingModel.shared.open(.music) }
        case .playArtist(let artist):
            let q = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? artist
            let spotify = InsightModel.shared.insight.taste.topSource == "Spotify" && MediaSource.spotify.isInstalled
            if let url = URL(string: spotify ? "spotify:search:\(q)" : "music://music.apple.com/search?term=\(q)") { NSWorkspace.shared.open(url) }
        case .openSettings: WindowManager.shared.showSettings(page: .brain)
        case .openPlan: IslandManager.shared.openPlan()
        case .setRoom(let title, let minutes): RoomStore.shared.setRoom(title: title, minutes: minutes)
        case .resumeRoom(let key):
            if let room = RoomStore.shared.rooms[key] { RoomStore.shared.restore(room, hideOthers: Prefs.shared.roomHidesOthers) }
        case .openRewind: IslandManager.shared.primary?.model.open(.rewind)
        case .openDay: IslandManager.shared.primary?.model.open(.day)
        case .addToTomorrow(let items, let source):
            PlanStore.shared.carry(items, from: source, as: .meeting)
            IslandManager.shared.primary?.model.showAlert(.message(symbol: "sun.horizon.fill",
                text: items.count == 1 ? "Added to tomorrow’s plan" : "\(items.count) added to tomorrow’s plan", tint: PlanView.morning), duration: 2.4)
        case .openFile(let url): NSWorkspace.shared.open(url)
        case .none: break
        }
    }

    /// Opens the answer panel with the Brain answering.
    func askBrain(_ question: String) {
        IslandManager.shared.primary?.model.openBrain()
        BrainAgent.shared.send(question)
    }

    // MARK: What the Brain knows, compacted

    /// A compact picture of the user for the model: now, today, recent days, schedule, Claude, music, facts.
    func digest() -> String {
        var lines: [String] = []
        let f = DateFormatter()
        f.dateFormat = "EEEE HH:mm"
        lines.append("Now: \(f.string(from: Date())).")
        if context.level != .off {
            var now = "Currently \(context.mode.label.lowercased())"
            if let p = context.project { now += " on \(p)" }
            if !context.appName.isEmpty { now += " in \(context.appName)" }
            if !context.title.isEmpty { now += " (\(context.title.prefix(80)))" }
            now += " for \(Self.duration(context.modeDuration))."
            lines.append(now)
            if context.level == .everything, let screen = ScreenSensor.shared.latest, screen.at.timeIntervalSinceNow > -600 {
                lines.append("On screen in \(screen.app): \(screen.text.prefix(400))")
            }
        }
        let dayStart = Calendar.current.startOfDay(for: Date())
        let today = store.episodes(since: dayStart, limit: 40)
        if !today.isEmpty {
            lines.append("Today’s sessions: " + today.reversed().map {
                "\(Self.clock($0.start))–\(Self.clock($0.end)) \($0.summary)"
            }.joined(separator: "; ") + ".")
        }
        let insight = InsightModel.shared.insight
        if !insight.modes.isEmpty {
            lines.append("Today by kind of work: " + insight.modes.prefix(5).map { "\($0.mode.label.lowercased()) \(Self.duration($0.seconds))" }.joined(separator: ", ")
                         + " (\(Self.duration(insight.deepToday)) of deep work).")
        }
        let projects = insight.projects.prefix(6).map { p in
            "\(p.name): \(Self.duration(p.today)) today, \(Self.duration(p.week)) this week, mostly \(p.mode.label.lowercased()) in \(p.appNames.prefix(2).joined(separator: " and "))"
        }
        if !projects.isEmpty { lines.append("Projects — " + projects.joined(separator: "; ") + ".") }
        let loops = InsightModel.shared.loops.map { "\($0.title) (\($0.detail))" }
        if !loops.isEmpty { lines.append("Open loops: " + loops.joined(separator: "; ") + ".") }
        let upcoming = CalendarModel.shared.events.filter { $0.end > Date() }.prefix(4)
        if !upcoming.isEmpty { lines.append("Calendar: " + upcoming.map { "\($0.title) at \(Self.clock($0.start))" }.joined(separator: ", ") + ".") }
        let plan = PlanStore.shared.summary
        if !plan.isEmpty { lines.append(plan) }
        let learned = PatternsModel.shared.patterns.insights + Habits.shared.sentences
        if !learned.isEmpty { lines.append("What Flow has learned about how they work: " + learned.joined(separator: " ")) }
        let claude = ClaudeSessions.shared.sessions.prefix(4)
        if !claude.isEmpty { lines.append("Claude sessions: " + claude.map { "\($0.name) (\($0.folder), \($0.state))" }.joined(separator: ", ") + ".") }
        let taste = insight.taste
        if !taste.topArtists.isEmpty {
            var t = "Music taste (last month): " + taste.topArtists.prefix(5).map(\.name).joined(separator: ", ")
            for (mode, artists) in taste.byMode.prefix(3) { t += "; while \(mode.label.lowercased()): \(artists.prefix(2).joined(separator: ", "))" }
            lines.append(t + ".")
        }
        if NowPlayingModel.shared.hasTrack { lines.append("Now playing: \(NowPlayingModel.shared.title) by \(NowPlayingModel.shared.artist).") }
        if let ledger = TaskLinks.ledger {
            let open = ledger.openTasks().sorted { TaskBrain.shared.importance(of: $0, at: Date()) > TaskBrain.shared.importance(of: $1, at: Date()) }
            if !open.isEmpty {
                lines.append("Open tasks, most important first: " + open.prefix(6).map { t in
                    t.title + (t.due.map { " (due \(Self.clock($0)))" } ?? "") + (t.status == .active ? " (in progress)" : "")
                }.joined(separator: "; ") + ".")
            }
        }
        let facts = store.facts().filter { $0.source == "answered" && !$0.key.hasPrefix("ask:") && !$0.key.hasPrefix("task.") }.prefix(12)
        if !facts.isEmpty { lines.append("They told Flow: " + facts.map { "\(Self.factText($0))" }.joined(separator: "; ") + ".") }
        let beliefs = Beliefs.all().filter { $0.confidence >= 0.4 }.prefix(5).map(\.sentence)
        if !beliefs.isEmpty { lines.append("Flow has learned: " + beliefs.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }

    static func factText(_ f: BrainStore.Fact) -> String {
        if f.key.hasPrefix("pref:music.") { return "music while \(f.key.dropFirst(11)): \(f.value)" }
        if f.key.hasPrefix("mode:"), let name = appName(String(f.key.dropFirst(5))) { return "\(name) is for \(f.value)" }
        if f.key == "pref:break.minutes" { return "breaks of \(f.value) minutes" }
        if f.key == "focus:project" { return f.value.isEmpty ? "no single project matters most" : "\(f.value) matters most this week" }
        if f.key.hasPrefix("pref:window.") { return "\(f.key.dropFirst(12)) as their sharpest hours: \(f.value)" }
        if f.key.hasPrefix("want:") { return "\(f.key.dropFirst(5)) suggestions: \(f.value)" }
        return "\(f.key): \(f.value)"
    }

    // MARK: Helpers

    static func appName(_ bundle: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    nonisolated static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(max(1, m))m"
    }

    static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    #if DEBUG
    func debugShow(_ s: BrainSuggestion) { lastSuggestion = s }
    #endif
}

extension Situation {
    /// This moment, from the senses.
    @MainActor static func now() -> Situation {
        let ctx = WorkContext.shared
        let next = CalendarModel.shared.events.first { !$0.isAllDay && $0.start > Date() && Calendar.current.isDateInToday($0.start) }
        return Situation(date: Date(), mode: ctx.mode, minutesInSession: ctx.modeDuration / 60, switchesLast15: ctx.switchesLast15Minutes,
                         minutesToMeeting: next.map { $0.start.timeIntervalSinceNow / 60 }, musicPlaying: NowPlayingModel.shared.isPlaying,
                         focusRunning: FocusTimer.shared.phase == .running)
    }
}
