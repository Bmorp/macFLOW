import Foundation

/// One thing Flow believes about you, as a sentence: how sure it is, how much it's based on, and how to forget it.
struct Belief: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case policy(String)
        case fact(String)
        case corrections(bundle: String)
        case estimates
        case importance
    }

    let id: String
    let sentence: String
    /// 0…1: how far past a blank guess Flow is.
    let confidence: Double
    /// Reactions, answers or finished tasks it rests on.
    let evidence: Int
    let symbol: String
    let source: Source
}

/// Everything Flow has learned, in plain words — for Settings › Flow, and for Flow to say when asked.
@MainActor
enum Beliefs {
    static let kindNames: [String: String] = QuestionBank.kindNames.merging([
        "music": "music suggestions", "meeting": "meeting heads-ups", "error": "help with errors",
        "plan.meeting": "plan meeting reminders", "plan.wrapup": "evening wrap-ups", "plan.later": "plan-your-day reminders",
    ]) { a, _ in a }

    static let kindSymbols: [String: String] = [
        "break": "figure.walk", "music": "music.note", "focus": "scope", "routine": "arrow.triangle.branch",
        "habit": "arrow.triangle.turn.up.right.circle.fill", "resume": "arrow.uturn.forward", "back": "arrow.uturn.backward",
        "meeting": "calendar.badge.clock", "error": "ladybug.fill", "day": "sun.horizon.fill", "meeting.notes": "list.bullet.clipboard",
    ]

    static func all(policy: SuggestionPolicy = .shared, store: BrainStore = .shared, corrections: ModeCorrections = .shared,
                    tasks: TaskBrain? = nil, now: Date = Date(), calendar: Calendar = .current) -> [Belief] {
        let tasks = tasks ?? TaskBrain.shared
        var out: [Belief] = []
        let day = calendar.startOfDay(for: now)
        func at(_ hour: Int, _ mode: WorkMode) -> Situation {
            Situation(date: day.addingTimeInterval(Double(hour) * 3600 + 1800), mode: mode, minutesInSession: 45)
        }
        // How you take each kind of suggestion.
        for kind in policy.knownKinds {
            guard let st = policy.state(kind), st.model.evidence >= 2, let name = kindNames[kind] else { continue }
            let mode = QuestionBank.usualMode(st)
            let parts: [(ContextFeatures.Part, Int)] = [(.morning, 10), (.afternoon, 15), (.evening, 20)]
            let ps = parts.map { policy.belief(kind: kind, situation: at($0.1, mode)) }
            let prior = SuggestionPolicy.freshModel(kind, now: now).score(ContextFeatures.vector(at(15, mode), calendar: calendar)).variance.squareRoot()
            let sd = ps.map(\.sd).reduce(0, +) / Double(ps.count)
            let confidence = max(0, min(1, 1 - sd / max(prior, 0.01)))
            let best = ps.indices.max { ps[$0].p < ps[$1].p }!, worst = ps.indices.min { ps[$0].p < ps[$1].p }!
            var sentence: String
            if kind == "music" {
                let coding = policy.belief(kind: kind, situation: at(15, .coding)).p, writing = policy.belief(kind: kind, situation: at(15, .writing)).p
                if abs(coding - writing) >= 0.25 {
                    sentence = coding > writing ? "You like music suggestions while coding, not while writing." : "You like music suggestions while writing, not while coding."
                    out.append(Belief(id: "policy.\(kind)", sentence: sentence, confidence: confidence, evidence: evidence(st),
                                      symbol: kindSymbols[kind] ?? "sparkle", source: .policy(kind)))
                    continue
                }
            }
            let mean = ps.map(\.p).reduce(0, +) / Double(ps.count)
            if ps[best].p - ps[worst].p >= 0.25 {
                sentence = "You take \(name) \(parts[best].0.label), not \(parts[worst].0.label)."
            } else if mean >= 0.6 {
                sentence = "You usually take \(name)."
            } else if mean <= 0.35 {
                sentence = "You usually pass on \(name)."
            } else {
                sentence = "You take \(name) about \(Int((mean * 100).rounded()))% of the time."
            }
            out.append(Belief(id: "policy.\(kind)", sentence: sentence, confidence: confidence, evidence: evidence(st),
                              symbol: kindSymbols[kind] ?? "sparkle", source: .policy(kind)))
        }
        // What you told Flow, fading as answers do.
        for f in store.facts() where f.source == "answered" && shown(f.key) {
            out.append(Belief(id: "fact.\(f.key)", sentence: sentence(for: f), confidence: f.confidence(at: now), evidence: 1,
                              symbol: f.key.hasPrefix("told:") ? "text.bubble" : "person.fill.questionmark", source: .fact(f.key)))
        }
        // Moments you corrected.
        for c in corrections.summary() {
            out.append(Belief(id: "corrections.\(c.bundle)", sentence: "\(c.app.isEmpty ? "That app" : c.app) is for \(c.mode == .media ? "personal things" : c.mode.label.lowercased()) — you corrected it.",
                              confidence: min(1, 0.5 + Double(c.count) * 0.2), evidence: c.count, symbol: c.mode.symbol, source: .corrections(bundle: c.bundle)))
        }
        // Your tasks.
        let n = tasks.estimator.count
        if n >= 3 {
            let err = tasks.estimator.medianError(since: now.addingTimeInterval(-30 * 86_400))
            let sentence = err.map { "Flow’s task estimates are within \(Int(($0 * 100).rounded()))% of your real time, from \(n) finished tasks." }
                ?? "Flow estimates tasks from the \(n) you’ve finished."
            out.append(Belief(id: "estimates", sentence: sentence, confidence: err.map { max(0, 1 - $0) } ?? 0.3, evidence: n,
                              symbol: "timer", source: .estimates))
        }
        let imp = tasks.importanceModel
        if imp.evidence >= 3 {
            out.append(Belief(id: "importance", sentence: "Flow ranks your tasks by what you finish first and what you put off.",
                              confidence: 1 - exp(-imp.evidence / 8), evidence: Int(imp.evidence.rounded()), symbol: "list.number", source: .importance))
        }
        return out.sorted { $0.confidence * Double(min($0.evidence, 20) + 1) > $1.confidence * Double(min($1.evidence, 20) + 1) }
    }

    private static func evidence(_ st: SuggestionPolicy.KindState) -> Int { st.accepted + st.dismissed + st.ignored + st.answers }

    private static func shown(_ key: String) -> Bool {
        !(key.hasPrefix("ask:") || key.hasPrefix("plan.checkin") || key.hasPrefix("skipped:") || key.hasPrefix("asked:")
          || key.hasPrefix("task.") || key.hasPrefix("focus:project."))
    }

    static func sentence(for f: BrainStore.Fact) -> String {
        if f.key.hasPrefix("told:") { return "You told Flow: \(f.value)" }
        if f.key.hasPrefix("pref:music.") {
            let mode = WorkMode(rawValue: String(f.key.dropFirst(11)))?.label.lowercased() ?? String(f.key.dropFirst(11))
            return f.value == "no" ? "No music suggestions while \(mode)." : f.value == "yes" ? "You like music while \(mode)." : "Music while \(mode), now and then."
        }
        if f.key.hasPrefix("mode:"), let mode = WorkMode(rawValue: f.value) {
            let name = BrainEngine.appName(String(f.key.dropFirst(5))) ?? String(f.key.dropFirst(5))
            return "\(name) is for \(mode == .media ? "personal things" : mode.label.lowercased())."
        }
        if f.key == "pref:break.minutes" { return "Your breaks last \(f.value) minutes." }
        if f.key == "focus:project" { return f.value.isEmpty ? "No one project comes first this week." : "\(f.value) comes first this week." }
        if f.key.hasPrefix("pref:window.") {
            let parts = f.key.dropFirst(12).split(separator: "-").compactMap { Int($0) }
            let hours = parts.count == 2 ? Patterns.hours(parts[0], parts[1]) : String(f.key.dropFirst(12))
            return f.value == "yes" ? "\(hours) are your sharpest hours." : "\(hours) aren’t your sharpest hours."
        }
        if f.key.hasPrefix("want:") {
            let rest = f.key.dropFirst(5)
            let kind = String(rest.split(separator: "@").first ?? rest)
            let name = kindNames[kind] ?? kind
            if f.value == "never" { return "No \(name)." }
            if let partName = rest.split(separator: "@").dropFirst().first, let part = ContextFeatures.Part.allCases.first(where: { "\($0)" == partName }) {
                return "No \(name) \(part.bound)."
            }
        }
        return BrainEngine.factText(f)
    }

    /// Forget one belief: the learner goes back to where it started, and Flow may ask about it again.
    static func forget(_ b: Belief, policy: SuggestionPolicy = .shared, store: BrainStore = .shared, corrections: ModeCorrections = .shared,
                       tasks: TaskBrain? = nil) {
        let tasks = tasks ?? TaskBrain.shared
        switch b.source {
        case .policy(let kind):
            policy.forget(kind: kind)
            for key in store.askedLog().keys where key.hasPrefix("want:\(kind)@") { store.forgetQuestion(key) }
        case .fact(let key):
            store.deleteFact(key)
            store.forgetQuestion(key)
        case .corrections(let bundle):
            corrections.forget(bundle: bundle)
        case .estimates, .importance:
            tasks.reset()
        }
    }

    /// For Flow, asked "what have you learned about me?".
    static func summary(limit: Int = 8) -> String {
        let list = all().prefix(limit)
        guard !list.isEmpty else { return "Nothing confident yet — Flow is still learning from what you take, wave away and tell it." }
        return list.map { "- \($0.sentence) (\(Int(($0.confidence * 100).rounded()))% sure, from \($0.evidence))" }.joined(separator: "\n")
    }

    /// The last seven days: of the suggestions you reacted to each day, how many you took.
    struct Day: Identifiable, Equatable, Sendable {
        var id: Date { day }
        let day: Date
        let accepted: Int
        let reacted: Int
        var rate: Double? { reacted == 0 ? nil : Double(accepted) / Double(reacted) }
    }

    nonisolated static func trend(_ rows: [(ts: Date, kind: String, outcome: String)], days: Int = 7, now: Date = Date(),
                                  calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().map { back in
            let start = calendar.date(byAdding: .day, value: -back, to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            let inDay = rows.filter { $0.ts >= start && $0.ts < end }
            let accepted = inDay.filter { $0.outcome == "accepted" }.count
            let reacted = inDay.filter { ["accepted", "dismissed", "ignored"].contains($0.outcome) }.count
            return Day(day: start, accepted: accepted, reacted: reacted)
        }
    }
}
