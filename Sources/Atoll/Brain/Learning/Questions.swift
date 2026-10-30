import Foundation

/// A question Flow could ask, tied to the belief it would settle.
///
/// Flow asks the one whose answer would change the most decisions per unit of doubt — uncertainty × impact — and
/// only at a quiet moment, a couple a day once it knows you, never the same one twice unless the answer has gone
/// stale. An answer is a strong label, applied at once.
struct QuestionProbe: Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let text: String
    let detail: String
    let options: [BrainQuestion.Option]
    /// 0…1: how unsure Flow is of what this answers.
    let uncertainty: Double
    /// 0…1: how many of Flow's decisions the answer would change.
    let impact: Double
    /// How long an answer holds before it's worth checking again; nil if only contradiction makes it stale.
    var staleAfter: TimeInterval? = 120 * 86_400
    /// What the answer is about, for its effects.
    let topic: Topic

    var score: Double { uncertainty * impact }
    var question: BrainQuestion { BrainQuestion(key: key, text: text, detail: detail, options: options) }

    enum Topic: Equatable, Sendable {
        case music(WorkMode)
        case wanted(kind: String, part: ContextFeatures.Part, hour: Int)
        case breakLength
        case window(start: Int, end: Int)
        case project(names: [String])
        case app(bundle: String, name: String)
        case level
        case estimate(task: UUID, title: String, minutes: Double)
        case done(task: UUID, title: String)
    }
}

/// What an answer does: facts to keep, labels to learn, what to say back, and anything to do.
struct AnswerEffect: Equatable, Sendable {
    struct Label: Equatable, Sendable {
        let kind: String
        let situation: Situation
        let y: Double
        let weight: Double
    }

    enum Action: Equatable, Sendable {
        case raiseLevel
        case completeTask(UUID)
        case estimate(task: UUID, minutes: Double)
        case doneLabel(task: UUID, done: Bool)
    }

    var facts: [(key: String, value: String)] = []
    var labels: [Label] = []
    var actions: [Action] = []
    var acknowledgement: String

    static func == (a: Self, b: Self) -> Bool {
        a.facts.map { "\($0.key)=\($0.value)" } == b.facts.map { "\($0.key)=\($0.value)" } && a.labels == b.labels
            && a.actions == b.actions && a.acknowledgement == b.acknowledgement
    }
}

/// Everything the question bank looks at, as plain values, so choosing a question is pure and tested.
struct QuestionWorld {
    var now: Date
    var learning: Bool
    var calendar: Calendar = .current
    var policy: SuggestionPolicy
    var facts: [String: BrainStore.Fact] = [:]
    var asked: [String: BrainStore.Asked] = [:]
    /// Minutes in each kind of work over the last week.
    var modeMinutes: [WorkMode: Double] = [:]
    /// Apps the rules don't know, with their minutes this week.
    var unclassified: [(bundle: String, name: String, minutes: Double, guess: WorkMode?)] = []
    /// Projects this week, most time first.
    var projects: [(name: String, minutes: Double)] = []
    var bestWindow: (start: Int, end: Int)?
    var patternDays = 0
    var plansMornings = true
    var levelIsEssentials = false
    var taskProbes: [QuestionProbe] = []
}

enum QuestionBank {
    /// Below this, a question isn't worth an interruption.
    static let minimumScore = 0.12

    /// Questions a day: more while Flow is new, two once it knows you.
    static func budget(learning: Bool) -> Int { learning ? 4 : 2 }

    /// The kinds Flow may ask "is this useful?" about, and how a person names them.
    static let kindNames: [String: String] = [
        "break": "break nudges", "focus": "focus nudges", "routine": "app suggestions", "habit": "what’s-next suggestions",
        "resume": "pick-up-where-you-left-off suggestions", "back": "back-to-work nudges", "day": "evening recaps",
        "plan.rest": "planned-break reminders", "plan.bestwindow": "sharpest-hours nudges", "plan.focus": "plan nudges",
        "meeting.notes": "meeting-notes cards",
    ]

    // MARK: Candidates

    static func candidates(_ w: QuestionWorld) -> [QuestionProbe] {
        var out: [QuestionProbe] = []
        // Music while coding or writing: the old question, now asked when the music policy for that mode is a coin flip.
        for mode in [WorkMode.coding, .writing] where (w.modeMinutes[mode] ?? 0) >= 60 {
            let s = typical(w, hour: w.calendar.component(.hour, from: w.now), mode: mode, minutes: 15)
            let u = decisionDoubt(w.policy, kind: "music", s)
            out.append(QuestionProbe(key: "pref:music.\(mode.rawValue)", text: "Do you like music while \(mode.label.lowercased())?",
                             detail: "I’ll suggest it at the right moment — or never.",
                             options: [.init(label: "Yes", value: "yes"), .init(label: "Sometimes", value: "sometimes"), .init(label: "No", value: "no")],
                             uncertainty: u, impact: min(1, (w.modeMinutes[mode] ?? 0) / 600), topic: .music(mode)))
        }
        // "I keep suggesting X around 4 — useful?": a kind shown often enough that its value at that hour matters,
        // and Flow still can't tell (mostly left to expire, or taken and waved away in turn).
        for kind in w.policy.knownKinds {
            guard let name = kindNames[kind], let st = w.policy.state(kind), st.shown >= 3 else { continue }
            let hours = st.tally.hours
            guard let peak = hours.indices.max(by: { hours[$0] < hours[$1] }), hours[peak] >= 1 else { continue }
            let part = ContextFeatures.Part(hour: peak)
            let inPart = hours.indices.filter { ContextFeatures.Part(hour: $0) == part }.reduce(0) { $0 + hours[$1] }
            guard inPart >= 3 else { continue }
            let s = typical(w, hour: peak, mode: usualMode(st), minutes: 60)
            let reacted = Double(st.accepted + st.dismissed + st.ignored)
            let ignoredShare = reacted > 0 ? Double(st.ignored) / reacted : 1
            let u = decisionDoubt(w.policy, kind: kind, s) * (0.6 + 0.4 * ignoredShare)
            out.append(QuestionProbe(key: "want:\(kind)@\(part)", text: "I keep suggesting \(name) around \(hourName(peak)) — useful?",
                             detail: "Your answer sets when I offer them.",
                             options: [.init(label: "Yes", value: "yes"), .init(label: "Not Then", value: "notthen"), .init(label: "Never", value: "never")],
                             uncertainty: u, impact: min(1, Double(st.shown) / 10), topic: .wanted(kind: kind, part: part, hour: peak)))
        }
        // Break length: once breaks have come up, how long they should be (a five-minute guess until then).
        if let st = w.policy.state("break"), st.shown >= 2 {
            let counts = [1 + Double(st.accepted), 1.0, 1.0]
            let total = counts.reduce(0, +)
            let entropy = -counts.map { $0 / total }.reduce(0) { $0 + $1 * log($1) } / log(3)
            out.append(QuestionProbe(key: "pref:break.minutes", text: "How long do you like a break?", detail: "I’ll offer breaks that long.",
                             options: [.init(label: "5 Min", value: "5"), .init(label: "10 Min", value: "10"), .init(label: "15 Min", value: "15")],
                             uncertainty: entropy, impact: min(1, Double(st.shown) / 6), topic: .breakLength))
        }
        // The sharpest hours, as Patterns found them: confirm before planning every morning around them.
        if let win = w.bestWindow {
            let u = max(0.25, 1 - Double(w.patternDays) / 28)
            out.append(QuestionProbe(key: "pref:window.\(win.start)-\(win.end)", text: "Are \(Patterns.hours(win.start, win.end)) your sharpest hours?",
                             detail: "I put your most important work there.",
                             options: [.init(label: "Yes", value: "yes"), .init(label: "Not Really", value: "no")],
                             uncertainty: u, impact: w.plansMornings ? 0.8 : 0.4, topic: .window(start: win.start, end: win.end)))
        }
        // The project that matters most this week: when time is split between several, Flow can't tell from time alone.
        let top = Array(w.projects.filter { $0.minutes >= 60 }.prefix(3))
        if top.count >= 2 {
            let total = top.reduce(0) { $0 + $1.minutes }
            let shares = top.map { $0.minutes / total }
            let entropy = -shares.reduce(0) { $0 + $1 * log($1) } / log(Double(top.count))
            let week = w.calendar.component(.weekOfYear, from: w.now), year = w.calendar.component(.yearForWeekOfYear, from: w.now)
            out.append(QuestionProbe(key: "focus:project.\(year)-W\(week)", text: "Which project matters most this week?",
                             detail: "It goes first in your plan and your tasks.",
                             options: top.map { .init(label: String($0.name.prefix(18)), value: $0.name) } + [.init(label: "All of Them", value: "")],
                             uncertainty: entropy, impact: 0.7, staleAfter: nil, topic: .project(names: top.map(\.name))))
        }
        // An app the rules don't know, used a while: what it's for.
        for app in w.unclassified where app.minutes >= 20 {
            out.append(QuestionProbe(key: "mode:\(app.bundle)", text: app.guess.map { "Is \(app.name) for \($0.label.lowercased())?" } ?? "What do you use \(app.name) for?",
                             detail: "So I know when you’re working.",
                             options: [.init(label: "Building", value: WorkMode.coding.rawValue), .init(label: "Writing", value: WorkMode.writing.rawValue),
                                       .init(label: "Design", value: WorkMode.design.rawValue), .init(label: "Personal", value: WorkMode.media.rawValue)],
                             uncertainty: app.guess == nil ? 1 : 0.5, impact: min(1, app.minutes / 180), staleAfter: nil,
                             topic: .app(bundle: app.bundle, name: app.name)))
        }
        if w.learning, w.levelIsEssentials {
            out.append(QuestionProbe(key: "ask:level", text: "Should I learn which project you’re in?", detail: "I’d read window titles — on this Mac only.",
                             options: [.init(label: "Yes", value: "yes"), .init(label: "Not Now", value: "no")],
                             uncertainty: 0.7, impact: 0.6, staleAfter: nil, topic: .level))
        }
        return out + w.taskProbes
    }

    // MARK: Choosing

    /// Whether a question may be asked now: not answered (unless the answer's stale), not skipped lately, not waiting.
    static func eligible(_ p: QuestionProbe, _ w: QuestionWorld) -> Bool {
        let a = w.asked[p.key]
        let fact = w.facts[p.key].flatMap { $0.source == "answered" ? $0 : nil }
        // Answered: only once the answer has gone stale — by age, or because what you do has worn its confidence down.
        if let answeredAt = fact?.updated ?? a?.answered {
            let byAge = p.staleAfter.map { w.now.timeIntervalSince(answeredAt) > $0 } ?? false
            // Worn: you said it, then kept doing otherwise (each contradiction lowers the answer's confidence).
            let worn = fact.map { $0.confidence < 1 && $0.isStale(at: w.now) } ?? false
            guard byAge || worn else { return false }
        }
        guard let a else { return true }
        // "Don't ask again": a few days' rest the first time, two months the second.
        if a.skips >= 2 { return w.now.timeIntervalSince(a.asked) > 60 * 86_400 }
        if a.skips == 1, w.now.timeIntervalSince(a.asked) < 3 * 86_400 { return false }
        // Asked and not answered since: it waits on Home for a day; leave it be a while longer.
        if (a.answered.map { $0 < a.asked } ?? true), w.now.timeIntervalSince(a.asked) < 2 * 86_400 { return false }
        return true
    }

    static func askedToday(_ w: QuestionWorld) -> Int {
        w.asked.values.filter { w.calendar.isDate($0.asked, inSameDayAs: w.now) && $0.times > 0 }.count
    }

    /// The question worth asking now, if any.
    static func choose(_ w: QuestionWorld) -> QuestionProbe? {
        guard askedToday(w) < budget(learning: w.learning) else { return nil }
        return candidates(w).filter { $0.score >= minimumScore && eligible($0, w) }
            .max { $0.score == $1.score ? $0.key > $1.key : $0.score < $1.score }
    }

    // MARK: Answers

    /// What an answer means, as labels and facts.
    static func effect(of option: BrainQuestion.Option, for p: QuestionProbe, world w: QuestionWorld) -> AnswerEffect {
        let v = option.value
        switch p.topic {
        case .music(let mode):
            let hours = [10, 15, 20]
            let label = mode.label.lowercased()
            switch v {
            case "yes":
                return AnswerEffect(facts: [(p.key, v)], labels: hours.map { .init(kind: "music", situation: typical(w, hour: $0, mode: mode, minutes: 15), y: 1, weight: 1) },
                                    acknowledgement: "Got it — music while \(label), at the right moments")
            case "no":
                return AnswerEffect(facts: [(p.key, v)], labels: hours.map { .init(kind: "music", situation: typical(w, hour: $0, mode: mode, minutes: 15), y: 0, weight: 1.5) },
                                    acknowledgement: "Got it — no music suggestions while \(label)")
            default:
                return AnswerEffect(facts: [(p.key, v)], labels: hours.flatMap { h in [1.0, 0.0].map { .init(kind: "music", situation: typical(w, hour: h, mode: mode, minutes: 15), y: $0, weight: 0.4) } },
                                    acknowledgement: "Got it — now and then")
            }
        case .wanted(let kind, let part, let hour):
            let name = kindNames[kind] ?? "these"
            let mode = w.policy.state(kind).map(usualMode) ?? .coding
            switch v {
            case "yes":
                return AnswerEffect(labels: part.hours.map { .init(kind: kind, situation: typical(w, hour: $0, mode: mode, minutes: 60), y: 1, weight: 1.5) },
                                    acknowledgement: "Got it — I’ll keep them coming around \(hourName(hour))")
            case "never":
                let all = ContextFeatures.Part.allCases.flatMap(\.hours)
                return AnswerEffect(facts: [("want:\(kind)", "never")], labels: all.map { .init(kind: kind, situation: typical(w, hour: $0, mode: mode, minutes: 60), y: 0, weight: 2) },
                                    acknowledgement: "Got it — no more \(name)")
            default:
                return AnswerEffect(facts: [(p.key, "no")], labels: part.hours.map { .init(kind: kind, situation: typical(w, hour: $0, mode: mode, minutes: 60), y: 0, weight: 1.5) },
                                    acknowledgement: "Got it — no more \(name) \(part.bound)")
            }
        case .breakLength:
            return AnswerEffect(facts: [(p.key, v)], acknowledgement: "Got it — \(v)-minute breaks")
        case .window(let start, let end):
            return AnswerEffect(facts: [(p.key, v)], acknowledgement: v == "yes" ? "Got it — I’ll keep \(Patterns.hours(start, end)) for deep work"
                                                                                  : "Got it — I won’t plan around \(Patterns.hours(start, end))")
        case .project:
            return AnswerEffect(facts: [(p.key, v), ("focus:project", v)],
                                acknowledgement: v.isEmpty ? "Got it — all of them, then" : "Got it — \(v) first this week")
        case .app(_, let name):
            let mode = WorkMode(rawValue: v) ?? .other
            return AnswerEffect(facts: [(p.key, v)], acknowledgement: "Got it — \(name) is for \(mode == .media ? "personal things" : mode.label.lowercased())")
        case .level:
            return AnswerEffect(facts: [(p.key, v)], actions: v == "yes" ? [.raiseLevel] : [],
                                acknowledgement: v == "yes" ? "Got it — I’ll learn your projects" : "Got it — not now")
        case .estimate(let id, let title, let minutes):
            let m = v == "less" ? minutes * 0.6 : v == "more" ? minutes * 1.6 : minutes
            return AnswerEffect(actions: [.estimate(task: id, minutes: m)],
                                acknowledgement: v == "right" ? "Got it — about \(TaskBrain.minutesText(m)) for “\(title.prefix(30))”" : "Got it — about \(TaskBrain.minutesText(m)), then")
        case .done(let id, let title):
            return v == "yes"
                ? AnswerEffect(actions: [.completeTask(id), .doneLabel(task: id, done: true)], acknowledgement: "Nice — “\(title.prefix(32))” is done")
                : AnswerEffect(actions: [.doneLabel(task: id, done: false)], acknowledgement: "Got it — still on it")
        }
    }

    // MARK: Helpers

    /// A plausible moment for a kind, at an hour, for asking about or teaching it.
    static func typical(_ w: QuestionWorld, hour: Int, mode: WorkMode, minutes: Double) -> Situation {
        let day = w.calendar.startOfDay(for: w.now)
        return Situation(date: day.addingTimeInterval(Double(hour) * 3600 + 1800), mode: mode, minutesInSession: minutes)
    }

    /// How much a decision about this kind, here, is a coin flip: 1 when Flow can't tell show from don't, 0 when sure.
    static func decisionDoubt(_ policy: SuggestionPolicy, kind: String, _ s: Situation, bar: Double = 0.5) -> Double {
        let b = policy.belief(kind: kind, situation: s)
        let z = BayesLogit.logit(b.p) * (1 + .pi * b.sd * b.sd / 8).squareRoot()
        let q = BayesLogit.phi((z - BayesLogit.logit(bar)) / max(b.sd, 0.05))
        return 4 * q * (1 - q)
    }

    static func hourName(_ h: Int) -> String {
        h == 12 ? "noon" : "\(h % 12 == 0 ? 12 : h % 12)"
    }

    /// The kind of work a suggestion is most often reacted to in.
    static func usualMode(_ s: SuggestionPolicy.KindState) -> WorkMode {
        let m = s.tally.byMode.indices.max { s.tally.byMode[$0].reduce(0, +) < s.tally.byMode[$1].reduce(0, +) }
        return m.map { WorkMode.allCases[$0] } ?? .coding
    }
}
