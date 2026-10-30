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
