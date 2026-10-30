import Testing
import Foundation
@testable import Atoll

// MARK: - Helpers

/// A fixed calendar, so tests don't depend on the Mac's time zone or region.
let learningCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}()

/// Monday 2 November 2026, at an hour (UTC).
func monday(_ hour: Int, _ minute: Int = 0, plusDays days: Int = 0) -> Date {
    learningCalendar.date(from: DateComponents(year: 2026, month: 11, day: 2 + days, hour: hour, minute: minute))!
}

// MARK: - Features

@Suite("Brain learning · features")
struct FeatureTests {
    @Test func fixedLengthAndDeterministic() {
        let s = Situation(date: monday(16), mode: .coding, minutesInSession: 95, switchesLast15: 4, minutesToMeeting: 25,
                          musicPlaying: true, focusRunning: false)
        let a = ContextFeatures.vector(s, target: "Figma", calendar: learningCalendar)
        let b = ContextFeatures.vector(s, target: "figma ", calendar: learningCalendar)
        #expect(a.count == ContextFeatures.count)
        #expect(a == b)                                         // same situation, same numbers
        #expect(a[ContextFeatures.bias] == 1)
        #expect(a[ContextFeatures.part + ContextFeatures.Part.afternoon.rawValue] == 1)
        #expect(a[ContextFeatures.mode + WorkMode.allCases.firstIndex(of: .coding)!] == 1)
        #expect(a[ContextFeatures.meeting + 3] == 1)             // 10–30 min to the meeting
        #expect(a[ContextFeatures.music] == 1)
        #expect(a[ContextFeatures.target..<ContextFeatures.count].reduce(0, +) == 1)
    }

    @Test func hourIsACircle() {
        let late = ContextFeatures.vector(Situation(date: monday(23, 30)), calendar: learningCalendar)
        let early = ContextFeatures.vector(Situation(date: monday(0, 30, plusDays: 1)), calendar: learningCalendar)
        let noon = ContextFeatures.vector(Situation(date: monday(12)), calendar: learningCalendar)
        func dist(_ a: [Double], _ b: [Double]) -> Double { hypot(a[1] - b[1], a[2] - b[2]) }
        #expect(dist(late, early) < 0.3)
        #expect(dist(late, noon) > 1.8)
    }

    @Test func sessionIsLogScaled() {
        let ten = ContextFeatures.vector(Situation(date: monday(10), minutesInSession: 10), calendar: learningCalendar)[ContextFeatures.session]
        let hour = ContextFeatures.vector(Situation(date: monday(10), minutesInSession: 60), calendar: learningCalendar)[ContextFeatures.session]
        let four = ContextFeatures.vector(Situation(date: monday(10), minutesInSession: 240), calendar: learningCalendar)[ContextFeatures.session]
        #expect(hour - ten > four - hour)
        #expect(abs(four - 1) < 1e-9)
    }
}

// MARK: - The model

@Suite("Brain learning · Bayesian logistic regression")
struct BayesLogitTests {
    @Test func aLabelMovesTheBeliefTheRightWay() {
        var m = BayesLogit(priorMean: [0, 0], priorVariance: [1, 1])
        let x = [1.0, 1.0]
        let before = m.probability(x)
        m.learn(x, label: 0)
        #expect(m.probability(x) < before)
        let (_, vAfter) = m.score(x)
        #expect(vAfter < 2)                                      // and it's surer
        m.learn(x, label: 1, weight: 3)
        #expect(m.probability(x) > 0.5)
    }

    @Test func converges() {
        var m = BayesLogit(priorMean: [0, 0], priorVariance: [1, 1])
        var rng = SplitMix64(seed: 7)
        for _ in 0..<600 {
            let x = [1.0, Double.random(in: -1...1, using: &rng)]
            let truth = BayesLogit.sigmoid(-0.5 + 2 * x[1])
            m.learn(x, label: Double.random(in: 0..<1, using: &rng) < truth ? 1 : 0)
        }
        #expect(abs(m.mean[0] + 0.5) < 0.35)
        #expect(abs(m.mean[1] - 2) < 0.6)
    }

    @Test func certaintyFadesTowardThePrior() {
        var m = BayesLogit(priorMean: [0], priorVariance: [1], now: monday(9))
        for _ in 0..<20 { m.learn([1], label: 0, at: monday(9)) }
        let sure = m.variance(0)
        m.relax(to: monday(9, plusDays: 60), halfLife: 60 * 86_400)
        #expect(m.variance(0) > sure)
        #expect(m.variance(0) < 1)
    }

    @Test func aSingleUpdateIsWellUnderAMillisecond() {
        var m = SuggestionPolicy.freshModel("break", now: monday(9))
        let x = ContextFeatures.vector(Situation(date: monday(15), mode: .coding, minutesInSession: 100), target: "Xcode", calendar: learningCalendar)
        let n = 2000
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<n { m.learn(x, label: Double(i % 2), weight: 1, offset: 0.4) }
        let perUpdate = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n) / 1e6
        print("[update] \(String(format: "%.4f", perUpdate)) ms per update")
        #expect(perUpdate < 1, "one update took \(perUpdate) ms")
    }
}

// MARK: - Simulated users

/// Someone using Flow, simulated: for each suggestion in each moment, how likely they are to take it, and of the
/// rest how many they'd let expire rather than wave away.
struct SyntheticUser {
    let name: String
    /// The kinds of suggestion their days produce, and how often.
    let mix: [(kind: String, weight: Double)]
    let accept: (String, Situation) -> Double
    var ignoreShare = 0.3

    static let hatesBreaks = SyntheticUser(
        name: "hates break nudges",
        mix: [("break", 0.35), ("focus", 0.15), ("music", 0.15), ("routine", 0.15), ("resume", 0.1), ("day", 0.1)],
        accept: { kind, _ in
            switch kind {
            case "break": 0.02
            case "focus": 0.55
            case "music": 0.65
            case "routine": 0.75
            case "resume": 0.8
            default: 0.35
            }
        })

    /// Always has music on to code, needs quiet to write; doesn't care for recaps, lukewarm on breaks.
    static let lovesMusicWhileCoding = SyntheticUser(
        name: "loves music while coding",
        mix: [("music", 0.4), ("break", 0.15), ("focus", 0.15), ("routine", 0.1), ("resume", 0.1), ("day", 0.1)],
        accept: { kind, s in
            switch kind {
            case "music": s.mode == .coding ? 0.92 : 0.08
            case "break": 0.3
            case "focus": 0.55
            case "routine", "resume": 0.75
            default: 0.15
            }
        })

    /// Wants each thing at its own time of day, and not at others.
    static let routineDriven = SyntheticUser(
        name: "routine-driven",
        mix: [("resume", 0.2), ("break", 0.25), ("focus", 0.25), ("music", 0.15), ("routine", 0.15)],
        accept: { kind, s in
            let h = learningCalendar.component(.hour, from: s.date)
            switch kind {
            case "resume": return h < 12 ? 0.9 : 0.1
            case "break": return (13..<17).contains(h) ? 0.85 : 0.05
            case "focus": return h < 12 ? 0.85 : 0.1
            case "music": return h >= 12 ? 0.8 : 0.15
            default: return 0.75
            }
        })

    /// Clicks without looking: the policy mustn't learn anything silly from it.
    static let randomClicker = SyntheticUser(
        name: "random clicker",
        mix: [("break", 0.2), ("focus", 0.2), ("music", 0.2), ("routine", 0.2), ("resume", 0.2)],
        accept: { _, _ in 0.5 }, ignoreShare: 0.3)

    func pickKind<G: RandomNumberGenerator>(_ rng: inout G) -> String {
        let total = mix.reduce(0) { $0 + $1.weight }
        var r = Double.random(in: 0..<total, using: &rng)
        for m in mix { r -= m.weight; if r < 0 { return m.kind } }
        return mix.last!.kind
    }

    /// The moment a candidate comes up in, following `BrainEngine`'s own triggers: a break after 90 minutes of deep
    /// work, a focus nudge when switching a lot, music 10–25 minutes into coding or writing, a recap in the evening.
    func situation<G: RandomNumberGenerator>(for kind: String, _ rng: inout G, day: Int) -> Situation {
        let deep: [WorkMode] = [.coding, .writing, .design, .planning]
        let any: [WorkMode] = [.coding, .writing, .design, .research, .communicating]
        var hour = Int.random(in: 8..<20, using: &rng)
        var s = Situation(date: Date(), mode: any[Int.random(in: 0..<any.count, using: &rng)],
                          minutesInSession: Double.random(in: 1...120, using: &rng),
                          switchesLast15: Int.random(in: 0...12, using: &rng),
                          minutesToMeeting: Bool.random(using: &rng) ? Double.random(in: 15...240, using: &rng) : nil,
                          musicPlaying: Bool.random(using: &rng))
        switch kind {
        case "break":
            s.mode = deep[Int.random(in: 0..<deep.count, using: &rng)]
            s.minutesInSession = Double.random(in: 90...180, using: &rng)
        case "focus":
            s.mode = deep[Int.random(in: 0..<deep.count, using: &rng)]
            s.minutesInSession = Double.random(in: 25...120, using: &rng)
            s.switchesLast15 = Int.random(in: 14...24, using: &rng)
        case "music":
            s.mode = Bool.random(using: &rng) ? .coding : .writing
            s.minutesInSession = Double.random(in: 10...25, using: &rng)
            s.musicPlaying = false
        case "resume":
            s.minutesInSession = Double.random(in: 0...2, using: &rng)
        case "day":
            hour = Int.random(in: 18..<23, using: &rng)
        default:
            break
        }
        s.date = monday(hour, Int.random(in: 0..<60, using: &rng), plusDays: day)
        return s
    }
}

struct Opportunity {
    let kind: String
    let situation: Situation
    /// The user's reaction if it's shown, drawn once so both policies meet the same person.
    let outcome: SuggestionPolicy.Outcome
}

enum Simulation {
    /// About a dozen candidates a day, from `startDay` on.
    static func stream(_ user: SyntheticUser, count: Int, seed: UInt64, startDay: Int = 0) -> [Opportunity] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { i in
            let kind = user.pickKind(&rng)
            let s = user.situation(for: kind, &rng, day: startDay + i / 12)
            let r = Double.random(in: 0..<1, using: &rng)
            let p = user.accept(kind, s)
            let outcome: SuggestionPolicy.Outcome = r < p ? .accepted : (Double.random(in: 0..<1, using: &rng) < user.ignoreShare ? .ignored : .dismissed)
            return Opportunity(kind: kind, situation: s, outcome: outcome)
        }
    }

    struct Result {
        var shown = 0, accepted = 0, dismissed = 0, ignored = 0
        var acceptance: Double { shown == 0 ? 0 : Double(accepted) / Double(shown) }
    }

    static let bar = 0.42

    /// The day-one policy: the old rule, which shows every candidate whose confidence clears the bar.
    static func dayOne(_ stream: [Opportunity]) -> Result {
        var r = Result()
        for o in stream where SuggestionPolicy.typicalConfidence(o.kind) * 1.075 >= bar { tally(&r, o.outcome) }
        return r
    }

    /// Trains a fresh policy on `trainingStream` until it has had `interactions` shown suggestions, then measures it.
    static func learned(train: [Opportunity], interactions: Int, evaluate: [Opportunity], seed: UInt64) -> (Result, SuggestionPolicy) {
        let policy = SuggestionPolicy(store: nil, calendar: learningCalendar)
        var rng = SplitMix64(seed: seed &+ 99)
        var seen = 0
        for o in train where seen < interactions {
            let c = SuggestionPolicy.typicalConfidence(o.kind)
            let d = policy.decide(kind: o.kind, situation: o.situation, confidence: c, bar: bar, using: &rng)
            guard d.show else { continue }
            let id = UUID()
            policy.shown(id, kind: o.kind, situation: o.situation, confidence: c)
            policy.record(id, o.outcome, at: o.situation.date)
            seen += 1
        }
        var r = Result()
        for o in evaluate {
            let d = policy.decide(kind: o.kind, situation: o.situation, confidence: SuggestionPolicy.typicalConfidence(o.kind), bar: bar, using: &rng)
            if d.show { tally(&r, o.outcome) }
        }
        return (r, policy)
    }

    static func tally(_ r: inout Result, _ o: SuggestionPolicy.Outcome) {
        r.shown += 1
        switch o {
        case .accepted: r.accepted += 1
        case .dismissed: r.dismissed += 1
        case .ignored: r.ignored += 1
        case .superseded: break
        }
    }

    /// Averages over many seeds so one lucky run can't pass the bar.
    static func run(_ user: SyntheticUser, seeds: Int = 32) -> (dayOne: Result, learned: Result) {
        var a = Result(), b = Result()
        for seed in 0..<UInt64(seeds) {
            let train = stream(user, count: 400, seed: seed * 2 + 1)
            // The two weeks after: the policy frozen at 30 interactions (no more learning), its certainty fading as it would.
            let eval = stream(user, count: 160, seed: seed * 2 + 2, startDay: 4)
            let d = dayOne(eval)
            let (l, _) = learned(train: train, interactions: 30, evaluate: eval, seed: seed)
            a.shown += d.shown; a.accepted += d.accepted; a.dismissed += d.dismissed; a.ignored += d.ignored
            b.shown += l.shown; b.accepted += l.accepted; b.dismissed += l.dismissed; b.ignored += l.ignored
        }
        return (a, b)
    }
}

@Suite("Brain learning · simulated users")
struct SimulationTests {
    @Test(arguments: [SyntheticUser.hatesBreaks, .lovesMusicWhileCoding, .routineDriven].map(\.name))
    func learnsWithinThirtyInteractions(_ name: String) {
        let user = [SyntheticUser.hatesBreaks, .lovesMusicWhileCoding, .routineDriven].first { $0.name == name }!
        let (dayOne, learned) = Simulation.run(user)
        let lift = learned.acceptance / dayOne.acceptance - 1
        let fewerDismissed = 1 - Double(learned.dismissed) / Double(dayOne.dismissed)
        print("[\(name)] acceptance \(String(format: "%.2f → %.2f (%+.0f%%)", dayOne.acceptance, learned.acceptance, lift * 100)); dismissed \(dayOne.dismissed) → \(learned.dismissed) (−\(Int(fewerDismissed * 100))%); shown \(dayOne.shown) → \(learned.shown)")
        #expect(lift >= 0.25, "acceptance rose only \(Int(lift * 100))%")
        #expect(fewerDismissed >= 0.5, "dismissals fell only \(Int(fewerDismissed * 100))%")
    }

    @Test func aRandomClickerDoesNotCollapseThePolicy() {
        let (dayOne, learned) = Simulation.run(.randomClicker)
        print("[random clicker] acceptance \(String(format: "%.2f → %.2f", dayOne.acceptance, learned.acceptance)); shown \(dayOne.shown) → \(learned.shown)")
        // Coin-flip answers teach nothing real: Flow keeps showing most things, isn't worse at picking, and doesn't
        // silence any kind on the strength of noise.
        #expect(Double(learned.shown) >= 0.6 * Double(dayOne.shown))
        #expect(learned.acceptance >= dayOne.acceptance - 0.03)
        var shownByKind: [String: (all: Int, shown: Int)] = [:]
        for seed in 0..<UInt64(16) {
            let train = Simulation.stream(.randomClicker, count: 400, seed: seed * 2 + 1)
            let eval = Simulation.stream(.randomClicker, count: 160, seed: seed * 2 + 2, startDay: 4)
            let (_, policy) = Simulation.learned(train: train, interactions: 30, evaluate: [], seed: seed)
            var rng = SplitMix64(seed: seed)
            for o in eval {
                let d = policy.decide(kind: o.kind, situation: o.situation, confidence: SuggestionPolicy.typicalConfidence(o.kind), bar: Simulation.bar, using: &rng)
                shownByKind[o.kind, default: (0, 0)].all += 1
                if d.show { shownByKind[o.kind, default: (0, 0)].shown += 1 }
            }
        }
        for (kind, n) in shownByKind { #expect(Double(n.shown) >= 0.4 * Double(n.all), "\(kind) all but silenced") }
    }

    @Test func dayOneIsTheOldRule() {
        let policy = SuggestionPolicy(store: nil, calendar: learningCalendar)
        var rng = SplitMix64(seed: 1)
        for confidence in stride(from: 0.2, through: 0.9, by: 0.05) {
            for bar in [0.42, 0.5] {
                let d = policy.decide(kind: "break", situation: Situation(date: monday(15), mode: .coding), confidence: confidence, bar: bar, using: &rng)
                #expect(d.show == (confidence * 1.075 >= bar), "confidence \(confidence) at bar \(bar)")
            }
        }
    }

    @Test func supersededTeachesNothing() {
        let policy = SuggestionPolicy(store: nil, calendar: learningCalendar)
        let s = Situation(date: monday(15), mode: .coding)
        let id = UUID()
        policy.shown(id, kind: "break", situation: s, confidence: 0.6)
        policy.record(id, .superseded)
        #expect(policy.state("break")?.model.evidence == 0)
        let id2 = UUID()
        policy.shown(id2, kind: "break", situation: s, confidence: 0.6)
        policy.record(id2, .ignored)
        #expect(abs((policy.state("break")?.model.evidence ?? 0) - 0.3) < 1e-9)   // a weak no
    }
}

// MARK: - Questions

private func questionWorld(now: Date = monday(15), learning: Bool = false, policy: SuggestionPolicy? = nil) -> QuestionWorld {
    var w = QuestionWorld(now: now, learning: learning, calendar: learningCalendar,
                          policy: policy ?? SuggestionPolicy(store: nil, calendar: learningCalendar))
    w.modeMinutes = [.coding: 900, .writing: 200]
    w.projects = [("Atoll", 300), ("Site", 280)]
    w.unclassified = [(bundle: "com.example.Sketchy", name: "Sketchy", minutes: 90, guess: nil)]
    w.bestWindow = (9, 12)
    w.patternDays = 6
    return w
}

private func answered(_ key: String, at now: Date) -> BrainStore.Asked {
    BrainStore.Asked(key: key, asked: now, answered: now, answer: "yes", times: 1, skips: 0)
}

@Suite("Brain learning · questions")
struct QuestionTests {
    @Test func asksWhatItIsLeastSureOfAndMostNeedsToKnow() {
        var w = questionWorld()
        let all = QuestionBank.candidates(w).filter { $0.score >= QuestionBank.minimumScore }
        let best = all.max { $0.score < $1.score }
        #expect(best != nil)
        #expect(QuestionBank.choose(w)?.key == best?.key)

        // Coding is most of the week, and music while coding is a coin flip: that is the question.
        let music = QuestionBank.candidates(w).first { $0.key == "pref:music.coding" }!
        #expect(music.uncertainty > 0.5)
        #expect(music.impact > 0.9)

        // Once Flow has seen enough to be sure, it stops being the thing to ask.
        for _ in 0..<40 {
            w.policy.teach(kind: "music", situation: Situation(date: monday(15, 30), mode: .coding, minutesInSession: 15), label: 1, weight: 1)
        }
        let after = QuestionBank.candidates(w).first { $0.key == "pref:music.coding" }!
        #expect(after.uncertainty < music.uncertainty * 0.5)
        #expect(QuestionBank.choose(w)?.key != "pref:music.coding")
    }

    @Test func neverRepeatsAndNeverAsksMoreThanTwoADay() {
        var w = questionWorld()
        var keys: [String] = []
        var perDay: [Int: Int] = [:]
        for day in 0..<10 {
            w.now = monday(15, plusDays: day)
            while let p = QuestionBank.choose(w) {
                keys.append(p.key)
                perDay[day, default: 0] += 1
                w.asked[p.key] = answered(p.key, at: w.now)
                w.facts[p.key] = BrainStore.Fact(key: p.key, value: "yes", source: "answered", confidence: 1, updated: w.now)
            }
        }
        #expect(!keys.isEmpty)
        #expect(Set(keys).count == keys.count, "asked twice: \(keys)")
        #expect(perDay.values.allSatisfy { $0 <= 2 }, "\(perDay)")
        #expect(QuestionBank.budget(learning: true) > QuestionBank.budget(learning: false))
    }

    @Test func aSkippedQuestionRestsAndAnAnsweredOneStaysAnswered() {
        var w = questionWorld()
        let key = "pref:music.coding"
        w.asked[key] = BrainStore.Asked(key: key, asked: w.now, answered: nil, answer: nil, times: 1, skips: 1)
        let p = QuestionBank.candidates(w).first { $0.key == key }!
        #expect(!QuestionBank.eligible(p, w))
        w.now = w.now.addingTimeInterval(4 * 86_400)
        #expect(QuestionBank.eligible(p, w))
        w.asked[key] = answered(key, at: w.now)
        w.facts[key] = BrainStore.Fact(key: key, value: "yes", source: "answered", confidence: 1, updated: w.now)
        #expect(!QuestionBank.eligible(p, w))
    }

    @Test func theOldQuestionsKeepTheirAnswerKeys() {
        let w = questionWorld(learning: true)
        let keys = Set(QuestionBank.candidates(w).map(\.key))
        #expect(keys.contains("pref:music.coding"))
        #expect(keys.contains("pref:music.writing"))
        #expect(keys.contains("pref:window.9-12"))
        #expect(keys.contains("mode:com.example.Sketchy"))
        #expect(keys.contains { $0.hasPrefix("focus:project.") })
    }

    @Test func anAnswerMovesTheBeliefAtOnce() {
        for (answer, direction) in [("no", -1.0), ("yes", 1.0)] {
            let w = questionWorld()
            let probe = QuestionBank.candidates(w).first { $0.key == "pref:music.coding" }!
            let at = Situation(date: monday(15, 30), mode: .coding, minutesInSession: 15)
            let before = w.policy.belief(kind: "music", situation: at)
            let effect = QuestionBank.effect(of: probe.options.first { $0.value == answer }!, for: probe, world: w)
            #expect(effect.acknowledgement.hasPrefix("Got it — "))
            for l in effect.labels { w.policy.teach(kind: l.kind, situation: l.situation, label: l.y, weight: l.weight, fromAnswer: true) }
            let now = w.policy.belief(kind: "music", situation: at)
            #expect((now.p - before.p) * direction > 0.2, "\(answer): \(before.p) → \(now.p)")
            #expect(now.sd < before.sd)
        }
    }

    @Test func neverMeansNeverAtEveryHour() {
        var w = questionWorld()
        for _ in 0..<6 { w.policy.shown(UUID(), kind: "break", situation: Situation(date: monday(16), mode: .coding), confidence: 0.6) }
        for h in [10, 16, 21] { w.policy.teach(kind: "break", situation: Situation(date: monday(h), mode: .coding, minutesInSession: 60), label: 0.5, weight: 0.1) }
        let probe = QuestionProbe(key: "want:break@afternoon", text: "?", detail: "", options: [.init(label: "Never", value: "never")],
                                  uncertainty: 1, impact: 1, topic: .wanted(kind: "break", part: .afternoon, hour: 16))
        let effect = QuestionBank.effect(of: probe.options[0], for: probe, world: w)
        for l in effect.labels { w.policy.teach(kind: l.kind, situation: l.situation, label: l.y, weight: l.weight, fromAnswer: true) }
        for h in [9, 13, 16, 20] {
            let b = w.policy.belief(kind: "break", situation: Situation(date: monday(h), mode: .coding, minutesInSession: 60))
            #expect(b.p < 0.25, "hour \(h): \(b.p)")
        }
    }

    @Test func everyAnswerSaysWhatItDid() {
        var w = questionWorld(learning: true)
        w.levelIsEssentials = true
        for p in QuestionBank.candidates(w) {
            for o in p.options {
                let a = QuestionBank.effect(of: o, for: p, world: w).acknowledgement
                #expect(a.hasPrefix("Got it — ") || a.hasPrefix("Nice — "), "\(p.key)/\(o.value): \(a)")
            }
        }
    }
}

// MARK: - Learning from plan and meeting suggestions

@Suite("Brain learning · plan and meeting feedback")
struct PlanFeedbackTests {
    @Test func planAndMeetingSuggestionsTeachTheSameWay() {
        for kind in ["plan.rest", "plan.focus", "plan.meeting", "meeting.notes", "meeting"] {
            let policy = SuggestionPolicy(store: nil, calendar: learningCalendar)
            let s = Situation(date: monday(15), mode: .coding, minutesInSession: 60)
            let before = policy.belief(kind: kind, situation: s).p
            for _ in 0..<12 {
                let id = UUID()
                policy.shown(id, kind: kind, situation: s, confidence: SuggestionPolicy.typicalConfidence(kind))
                policy.record(id, .dismissed)
            }
            #expect(policy.belief(kind: kind, situation: s).p < before - 0.1, "\(kind)")
            #expect(policy.state(kind)?.dismissed == 12)
        }
    }
}

// MARK: - Mode corrections

@Suite("Brain learning · mode corrections")
struct ModeCorrectionTests {
    private func moment(_ title: String) -> BrainStore.Moment {
        BrainStore.Moment(id: 7, ts: monday(14), mode: WorkMode.coding.rawValue, project: "Atoll", bundle: "com.apple.dt.Xcode", app: "Xcode", title: title)
    }

    @Test func aCorrectionOverridesTheRulesForMomentsLikeIt() {
        let c = ModeCorrections(store: nil, embedder: TextEmbedder(system: false))
        #expect(c.predict(app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Launch notes.md", project: "Atoll") == nil)
        c.correct(moment: moment("Launch notes draft.md"), to: .writing)
        // One exact window is enough; an unrelated window in the same app is not swept up.
        let same = c.predict(app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Launch notes draft.md", project: "Atoll")
        #expect(same?.mode == .writing)
        c.correct(moment: moment("Launch notes draft v2.md"), to: .writing)
        #expect(c.predict(app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Launch notes draft v3.md", project: "Atoll")?.mode == .writing)
        #expect(c.predict(app: "Xcode", bundle: "com.apple.dt.Xcode", title: "AppDelegate.swift", project: "Atoll") == nil)
        #expect(c.summary().first?.mode == .writing)
    }

    @Test func conflictingCorrectionsDoNotGuess() {
        let c = ModeCorrections(store: nil, embedder: TextEmbedder(system: false))
        c.correct(moment: moment("Plan"), to: .writing)
        c.correct(moment: moment("Plan"), to: .planning)
        #expect(c.predict(app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Plan", project: "Atoll") == nil)
    }

    @Test func forgettingAppsCorrectionsRestoresTheRules() {
        let c = ModeCorrections(store: nil, embedder: TextEmbedder(system: false))
        c.correct(moment: moment("Launch notes draft.md"), to: .writing)
        c.forget(bundle: "com.apple.dt.Xcode")
        #expect(c.predict(app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Launch notes draft.md", project: "Atoll") == nil)
    }
}

// MARK: - Task models

private func snapshot(_ title: String, project: String? = nil, estimate: Double? = nil, status: TaskStatus = .open,
                      actual: TimeInterval = 0, created: Date = monday(9)) -> TaskSnapshot {
    TaskSnapshot(id: UUID(), title: title, project: project, estimate: estimate, status: status, actual: actual, created: created)
}

@Suite("Brain learning · task models")
struct TaskModelTests {
    private static let kinds: [(title: String, project: String, minutes: Double)] = [
        ("write blog post", "Site", 90), ("review pull request", "Atoll", 25), ("email invoices", "", 10),
        ("plan sprint", "Atoll", 50), ("fix login bug", "Atoll", 40), ("record demo video", "Site", 120),
    ]

    private func gaussian(_ rng: inout SplitMix64) -> Double {
        let u = Double(rng.next() >> 11) / Double(1 << 53), v = Double(rng.next() >> 11) / Double(1 << 53)
        return (-2 * log(max(u, 1e-12))).squareRoot() * cos(2 * .pi * v)
    }

    @Test func estimateErrorFallsAsCompletionsArrive() {
        let est = DurationEstimator(embedder: TextEmbedder(system: false))
        var rng = SplitMix64(seed: 11)
        var errors: [Double] = []
        for i in 0..<72 {
            let k = Self.kinds[i % Self.kinds.count]
            let title = "\(k.title) \(["", "for Friday", "again", "with notes"][(i / Self.kinds.count) % 4])"
            let actual = k.minutes * exp(0.2 * gaussian(&rng))
            let guess = est.estimate(title: title, project: k.project.isEmpty ? nil : k.project)
            errors.append(abs(guess.minutes - actual) / actual)
            est.learn(.init(id: UUID().uuidString, ts: monday(9, plusDays: i / 6), title: title, project: k.project, mode: "", minutes: actual, estimate: nil))
        }
        func median(_ v: ArraySlice<Double>) -> Double { v.sorted()[v.count / 2] }
        let first = median(errors[0..<12]), last = median(errors[48..<72])
        print("[duration estimator] median error \(Int(first * 100))% → \(Int(last * 100))%")
        #expect(last < first * 0.5, "error \(first) → \(last)")
        #expect(last < 0.3)
        #expect(est.medianError(since: monday(9, plusDays: 8)) != nil)
    }

    @Test func yourOwnEstimatesAreCorrectedForHowYouRunOver() {
        let est = DurationEstimator(embedder: TextEmbedder(system: false))
        for i in 0..<8 {
            est.learn(.init(id: "\(i)", ts: monday(9, plusDays: i), title: "write report \(i)", project: "Work", mode: "", minutes: 60, estimate: 30))
        }
        let g = est.estimate(title: "write report", project: "Work", userEstimate: 30)
        #expect(g.minutes > 45, "you say 30 and take 60; Flow said \(g.minutes)")
        #expect(g.why.contains("short"))
    }

    @MainActor @Test func theBrainIsTheAdvisor() {
        let brain = TaskBrain(store: nil, embedder: TextEmbedder(system: false))
        brain.start()
        #expect(TaskLinks.advisor === brain)
        for i in 0..<6 {
            let t = snapshot("write blog post \(i)", project: "Site", status: .active, actual: 90 * 60)
            brain.handle(.added(t))
            brain.handle(.paused(t, focused: 90 * 60))
            brain.handle(.completed(t))
        }
        let e = brain.estimate(for: snapshot("write launch blog post", project: "Site"))
        #expect(e != nil)
        #expect(abs((e?.minutes ?? 0) - 90) < 25)
        #expect((e?.confidence ?? 0) > 0.3)
    }

    @MainActor @Test func importanceFollowsWhatYouDo() {
        let brain = TaskBrain(store: nil, embedder: TextEmbedder(system: false))
        let now = monday(10)
        let a = snapshot("plain task", created: now.addingTimeInterval(-86_400))
        let before = brain.importance(of: a, at: now)
        // Tasks of this shape get put off again and again.
        for i in 0..<8 {
            var t = snapshot("plain task \(i)", created: now.addingTimeInterval(-86_400))
            t.due = now.addingTimeInterval(3600)
            brain.handle(.added(t), now: now)
            var later = t
            later.due = now.addingTimeInterval(3 * 86_400)
            brain.handle(.updated(later), now: now)
        }
        #expect(brain.importance(of: a, at: now) <= before + 1e-9)
        var high = snapshot("urgent", created: now); high.priority = .high; high.due = now.addingTimeInterval(1800)
        #expect(brain.importance(of: high, at: now) > brain.importance(of: a, at: now))
    }

    @MainActor @Test func asksDoneAndLearnsFromTheAnswer() {
        let embedder = TextEmbedder(system: false)
        let brain = TaskBrain(store: nil, embedder: embedder)
        let now = monday(15)
        let t = snapshot("Write launch post", project: "Site", estimate: 30, status: .active, actual: 35 * 60, created: now.addingTimeInterval(-3 * 3600))
        brain.handle(.added(t), now: now)
        func moments(_ text: String) -> [CompletionFeatures.Moment] {
            (0..<6).map { CompletionFeatures.Moment(at: now.addingTimeInterval(-Double(40 - $0 * 5) * 60), vector: embedder.vector(text)!, project: "Site") }
        }
        let onIt = brain.doneProbability(task: t, moments: moments("Pages · Site · Write launch post"), now: now)
        let elsewhere = brain.doneProbability(task: t, moments: moments("Xcode · Atoll · AppDelegate.swift"), now: now)
        #expect(onIt.p > 0.6, "worked on it, then left: \(onIt.p)")
        #expect(elsewhere.p < onIt.p - 0.3)

        // Looks done: Flow asks.
        brain.debugSetCheck(t.id, p: onIt.p, x: onIt.x, at: now)
        let ask = brain.probes(now: now).first { $0.key == "task.done.\(t.id.uuidString)" }
        #expect(ask?.text.hasPrefix("Done with") == true)

        // "Not yet", said a few times about situations like this, and it stops saying so.
        var p = onIt.p
        for _ in 0..<3 {
            brain.debugSetCheck(t.id, p: p, x: onIt.x, at: now)
            brain.labelDone(t.id, done: false)
            p = brain.doneProbability(task: t, moments: moments("Pages · Site · Write launch post"), now: now).p
        }
        #expect(p < onIt.p - 0.15, "\(onIt.p) → \(p)")
    }
}

// MARK: - Spoken tasks

@Suite("Brain learning · spoken tasks")
struct SpokenTaskTests {
    @Test(arguments: [
        ("Add a task review the deck tomorrow at 3", "review the deck tomorrow at 3"),
        ("add task to call the dentist.", "call the dentist"),
        ("Hey Flow, new task: buy printer ink", "buy printer ink"),
        ("create a to-do called send invoices friday", "send invoices friday"),
        ("add to my tasks water the plants", "water the plants"),
    ])
    func takesTheWordsAfterTheCommand(_ heard: String, _ words: String) {
        #expect(BrainTaskTools.spokenTask(heard) == words)
    }

    @Test(arguments: ["what tasks do I have today", "task manager is slow", "add a note about the meeting", "play some music", "add a task"])
    func leavesEverythingElseToFlow(_ heard: String) {
        #expect(BrainTaskTools.spokenTask(heard) == nil)
    }
}

// MARK: - The store, and erasing

@Suite("Brain learning · store and erase")
struct LearnerStoreTests {
    private func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("brain-learn-\(UUID().uuidString).sqlite") }

    @Test func readsSeeWhatWasJustWritten() {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BrainStore(url: url)
        for i in 0..<150 {
            store.setFact("k\(i)", "v\(i)", source: "answered", confidence: 1)
            store.feedback("kind\(i % 3)", "accepted")
        }
        // Nothing waited between the writes and these reads, and the caches were cold.
        #expect(store.facts().count == 150)
        #expect(store.reactions("kind0").accepted == 50)
        #expect(store.feedbackRows(since: Date().addingTimeInterval(-60)).count == 150)
        store.flush()
        #expect(store.counts().facts == 150)
    }

    @Test func eraseEverythingClearsTheLearners() {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BrainStore(url: url)
        let embedder = TextEmbedder(system: false)
        let policy = SuggestionPolicy(store: store, calendar: learningCalendar)
        let corrections = ModeCorrections(store: store, embedder: embedder)
        for _ in 0..<5 { policy.teach(kind: "break", situation: Situation(date: monday(15), mode: .coding), label: 0, weight: 1) }
        let m = BrainStore.Moment(id: 1, ts: monday(14), mode: "coding", project: "Atoll", bundle: "com.apple.dt.Xcode", app: "Xcode", title: "Notes")
        corrections.correct(moment: m, to: .writing)
        corrections.flush()
        store.noteQuestion("pref:music.coding", answer: "no")
        #expect(policy.state("break") != nil)
        #expect(!corrections.summary().isEmpty)

        store.eraseEverything()

        #expect(policy.state("break") == nil)
        #expect(policy.knownKinds.isEmpty)
        #expect(corrections.summary().isEmpty)
        #expect(corrections.predict(app: "Xcode", bundle: m.bundle, title: "Notes", project: "Atoll") == nil)
        #expect(store.askedLog().isEmpty)
        #expect(store.learnerStates(prefix: "policy").isEmpty)
        #expect(store.corrections().isEmpty)
    }

    @MainActor @Test func whatFlowLearnedShowsBeliefsAndForgetsThem() {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BrainStore(url: url)
        let embedder = TextEmbedder(system: false)
        let policy = SuggestionPolicy(store: store, calendar: learningCalendar)
        let corrections = ModeCorrections(store: store, embedder: embedder)
        let tasks = TaskBrain(store: store, embedder: embedder)
        for hour in [10, 15, 20] {
            for _ in 0..<12 {
                for (mode, outcome) in [(WorkMode.coding, SuggestionPolicy.Outcome.accepted), (.writing, .dismissed)] {
                    let id = UUID()
                    policy.shown(id, kind: "music", situation: Situation(date: monday(hour), mode: mode, minutesInSession: 20), confidence: 0.6)
                    policy.record(id, outcome)
                }
            }
        }
        store.setFact("pref:break.minutes", "10", source: "answered", confidence: 1)
        let all = Beliefs.all(policy: policy, store: store, corrections: corrections, tasks: tasks, now: monday(16), calendar: learningCalendar)
        let music = all.first { $0.id == "policy.music" }
        #expect(music?.sentence == "You like music suggestions while coding, not while writing.")
        #expect((music?.confidence ?? 0) > 0.5)
        #expect((music?.evidence ?? 0) >= 60)
        #expect(all.contains { $0.sentence == "Your breaks last 10 minutes." })

        Beliefs.forget(music!, policy: policy, store: store, corrections: corrections, tasks: tasks)
        #expect(policy.state("music") == nil)
        let fact = all.first { $0.id == "fact.pref:break.minutes" }!
        Beliefs.forget(fact, policy: policy, store: store, corrections: corrections, tasks: tasks)
        #expect(store.fact("pref:break.minutes") == nil)
        #expect(Beliefs.summary().isEmpty == false)
    }

    @Test func trendCountsEachDay() {
        let rows: [(ts: Date, kind: String, outcome: String)] = [
            (monday(10), "break", "accepted"), (monday(11), "break", "dismissed"), (monday(12), "plan.rest", "accepted"),
            (monday(10, plusDays: -1), "music", "dismissed"), (monday(10), "music", "shown"),
        ]
        let days = Beliefs.trend(rows, days: 3, now: monday(18), calendar: learningCalendar)
        #expect(days.count == 3)
        #expect(days.last?.accepted == 2 && days.last?.reacted == 3)
        #expect(days[1].reacted == 1 && days[1].rate == 0)
        #expect(days.first?.rate == nil)
    }
}
