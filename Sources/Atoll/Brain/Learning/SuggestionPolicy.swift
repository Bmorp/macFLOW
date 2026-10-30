import Foundation

/// Whether a suggestion is worth an interruption, learned from what you do with them.
///
/// One Bayesian logistic regression per kind of suggestion, over the moment's features (`ContextFeatures`) and what
/// the suggestion points at. The candidate's own confidence is the starting point (an offset), so on day one the
/// decision is exactly the old rule — show when confidence × 1.075 clears the bar — and every reaction corrects it:
/// taken = yes, waved away = no, left to expire = a weak no, replaced by a newer one = nothing.
///
/// Each reaction is learned the instant it arrives (an online Laplace step, microseconds), and a moment later, off
/// the main thread, the kind's belief is refitted exactly over every reaction it has kept.
///
/// Deciding is Thompson sampling, optimistic form: draw one plausible score from the belief and show if it — or
/// the belief's mean — clears the bar. So Flow keeps showing what it thinks you want, and now and then retries
/// something you've passed on while it's still unsure, less and less as it becomes sure.
///
/// The gates around it (quiet times, the hourly cap, cooldowns) stay hard rails in `BrainEngine`; this only
/// decides among what they let through.
final class SuggestionPolicy: @unchecked Sendable {
    static let shared = SuggestionPolicy(store: BrainStore.shared)

    enum Outcome: String, Sendable {
        case accepted, dismissed, ignored, superseded

        /// The label and how much it counts.
        var label: (y: Double, weight: Double)? {
            switch self {
            case .accepted: (1, 1)
            case .dismissed: (0, 1)
            case .ignored: (0, 0.3)
            case .superseded: nil
            }
        }
    }

    struct Decision: Sendable, Equatable {
        let show: Bool
        /// The belief's chance of a yes.
        let probability: Double
        /// Shown although the belief's mean is under the bar: Flow is checking.
        let exploring: Bool
        /// One line: why this, now.
        let why: String
    }

    /// Reactions to one kind, by part of day and by mode, for plain-language explanations.
    struct Tally: Codable, Sendable, Equatable {
        var byPart = [[Double]](repeating: [0, 0], count: 4)            // [yes, no] weight
        var byMode = [[Double]](repeating: [0, 0], count: WorkMode.allCases.count)
        var hours = [Double](repeating: 0, count: 24)                   // when it was reacted to

        mutating func add(_ s: Situation, y: Double, weight: Double, calendar: Calendar) {
            let hour = calendar.component(.hour, from: s.date)
            let part = ContextFeatures.Part(hour: hour).rawValue
            let slot = y > 0.5 ? 0 : 1
            byPart[part][slot] += weight
            if let m = WorkMode.allCases.firstIndex(of: s.mode) { byMode[m][slot] += weight }
            hours[hour] += 1
        }
    }

    struct KindState: Codable, Sendable, Equatable {
        var model: BayesLogit
        var examples: [BayesLogit.Example] = []
        var tally = Tally()
        var shown = 0
        var accepted = 0
        var dismissed = 0
        var ignored = 0
        /// Labels taught by answers to questions.
        var answers = 0
    }

    private struct Pending {
        let kind: String
        let situation: Situation
        let x: [Double]
        let offset: Double
        let at: Date
    }

    private let lock = NSLock()
    private var kinds: [String: KindState] = [:]
    private var pending: [UUID: Pending] = [:]
    private var refitting: Set<String> = []
    private let store: BrainStore?
    private let calendar: Calendar
    private var loaded = false
    private let work = DispatchQueue(label: "atoll.brain.policy", qos: .utility)
    /// Tests and simulations refit before returning, so what they measure is what the app reaches a moment later.
    var refitsInline = false
    /// Certainty fades with this half-life, so old habits get rechecked.
    static let halfLife: TimeInterval = 60 * 86_400
    /// Reactions kept per kind for refitting: months of them, at the rate Flow suggests.
    static let keep = 240

    init(store: BrainStore?, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
        refitsInline = store == nil
        store?.onErase { [weak self] in self?.reset(persist: false) }
    }

    // MARK: Priors

    /// How loosely each weight starts. Part of the day and kind of work can flip a preference outright (music while
    /// coding, never while writing), so they start loose; the rest are refinements, and small variances there keep one
    /// reaction from being blamed on whatever else happened to be true. Tuned on the simulated users in the tests.
    static func priorVariance(for kind: String) -> [Double] {
        // What each kind plausibly turns on, from what triggers it: music on the kind of work, a break on how deep in
        // you are, a focus nudge on how scattered, an app or project suggestion on which one.
        var part = 3.0, mode = 3.0, session = 0.15, switches = 0.1, meeting = 0.1, target = 0.3, weekend = 0.3
        switch kind {
        case "music": mode = 4.5; part = 1.5
        case "break", "plan.rest": session = 0.6
        case "focus": switches = 0.5
        case "routine", "habit": target = 1.5; mode = 1.5
        case "resume", "back": target = 1.0
        case "meeting", "plan.meeting": meeting = 0.6
        case "day", "plan.wrapup": weekend = 1.0; part = 0.9
        default: break
        }
        return (0..<ContextFeatures.count).map { i in
            switch i {
            case ContextFeatures.bias: 0.8
            case ContextFeatures.hourSin, ContextFeatures.hourCos: 1.0
            case ContextFeatures.part..<ContextFeatures.weekend: part
            case ContextFeatures.weekend: weekend
            case ContextFeatures.mode..<ContextFeatures.session: mode
            case ContextFeatures.session: session
            case ContextFeatures.switches: switches
            case ContextFeatures.meeting..<ContextFeatures.music: meeting
            case ContextFeatures.music: 0.15
            case ContextFeatures.focus: 0.1
            default: target   // what it points at
            }
        }
    }

    /// Thompson draws use the belief's spread scaled down (Chapelle & Li's posterior reshaping): Flow still checks
    /// what it's unsure of, without spending many interruptions on it.
    static let exploration = 0.25

    /// The old score with no history was confidence × 1.075 (an optimistic 75% accept rate): the same start here.
    static func offset(for confidence: Double) -> Double { BayesLogit.logit(min(0.97, max(0.02, confidence * 1.075))) }

    /// What each kind typically says of itself, for replaying history and for questions about a kind.
    static func typicalConfidence(_ kind: String) -> Double {
        switch kind {
        case "resume": 0.75
        case "habit", "back", "error": 0.7
        case "meeting": 0.78
        case "break", "music": 0.6
        case "focus": 0.58
        case "routine": 0.75
        case "day": 0.55
        case "meeting.notes", "plan.focus", "plan.meeting": 0.9
        case "plan.rest", "plan.bestwindow": 0.85
        case "plan.later": 0.8
        case "plan.wrapup": 0.7
        default: 0.6
        }
    }

    static func freshModel(_ kind: String, now: Date) -> BayesLogit {
        BayesLogit(priorMean: [Double](repeating: 0, count: ContextFeatures.count), priorVariance: priorVariance(for: kind), now: now)
    }

    // MARK: Deciding

    func decide<G: RandomNumberGenerator>(kind: String, situation: Situation, target: String? = nil, confidence: Double,
                                          bar: Double, using rng: inout G) -> Decision {
        let x = ContextFeatures.vector(situation, target: target, calendar: calendar)
        let offset = Self.offset(for: confidence)
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var state = kinds[kind] ?? KindState(model: Self.freshModel(kind, now: situation.date))
        if kinds[kind] != nil {
            state.model.relax(to: situation.date, halfLife: Self.halfLife)
            kinds[kind] = state
        }
        let (mean, variance) = state.model.score(x, offset: offset)
        let threshold = BayesLogit.logit(bar)
        let p = state.model.probability(x, offset: offset)
        // Nothing learned yet: exactly the old rule, no dice.
        guard state.model.evidence > 0 else {
            return Decision(show: mean >= threshold, probability: p, exploring: false, why: why(state, situation, p: p, exploring: false))
        }
        let draw = mean + Self.exploration * variance.squareRoot() * BayesLogit.gaussian(using: &rng)
        let show = max(draw, mean) >= threshold
        let exploring = show && mean < threshold
        return Decision(show: show, probability: p, exploring: exploring, why: why(state, situation, p: p, exploring: exploring))
    }

    func decide(kind: String, situation: Situation, target: String? = nil, confidence: Double, bar: Double) -> Decision {
        var rng = SystemRandomNumberGenerator()
        return decide(kind: kind, situation: situation, target: target, confidence: confidence, bar: bar, using: &rng)
    }

    /// The belief about a kind in a situation: the chance of a yes, how unsure (the score's standard deviation), and
    /// how much it has learned from.
    func belief(kind: String, situation: Situation, target: String? = nil, confidence: Double? = nil) -> (p: Double, sd: Double, evidence: Double) {
        let x = ContextFeatures.vector(situation, target: target, calendar: calendar)
        let offset = Self.offset(for: confidence ?? Self.typicalConfidence(kind))
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        let model = kinds[kind]?.model ?? Self.freshModel(kind, now: situation.date)
        let (_, v) = model.score(x, offset: offset)
        return (model.probability(x, offset: offset), v.squareRoot(), model.evidence)
    }

    // MARK: Learning

    /// A suggestion is on show: remember the moment it was offered in, to learn from what happens to it.
    func shown(_ id: UUID, kind: String, situation: Situation, target: String? = nil, confidence: Double) {
        let x = ContextFeatures.vector(situation, target: target, calendar: calendar)
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard pending[id] == nil else { return }
        pending[id] = Pending(kind: kind, situation: situation, x: x, offset: Self.offset(for: confidence), at: situation.date)
        kinds[kind, default: KindState(model: Self.freshModel(kind, now: situation.date))].shown += 1
        // Inbox items live hours at most: anything this far back is long gone.
        if pending.count > 64, let oldest = pending.min(by: { $0.value.at < $1.value.at })?.key { pending[oldest] = nil }
    }

    func isTracking(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pending[id] != nil
    }

    /// What you did with it. Learned from at once.
    @discardableResult
    func record(_ id: UUID, _ outcome: Outcome, at now: Date = Date()) -> Bool {
        lock.lock()
        guard let p = pending.removeValue(forKey: id) else { lock.unlock(); return false }
        guard let label = outcome.label else { lock.unlock(); return true }
        var state = kinds[p.kind] ?? KindState(model: Self.freshModel(p.kind, now: now))
        learn(&state, x: p.x, situation: p.situation, y: label.y, weight: label.weight, offset: p.offset, at: max(now, p.at))
        switch outcome {
        case .accepted: state.accepted += 1
        case .dismissed: state.dismissed += 1
        case .ignored: state.ignored += 1
        case .superseded: break
        }
        kinds[p.kind] = state
        lock.unlock()
        settle(p.kind)
        return true
    }

    /// A label from elsewhere: an answer to a question (strong), or history being replayed.
    func teach(kind: String, situation: Situation, target: String? = nil, confidence: Double? = nil, label y: Double, weight: Double,
               fromAnswer: Bool = false, settle settleNow: Bool = true) {
        let x = ContextFeatures.vector(situation, target: target, calendar: calendar)
        let offset = Self.offset(for: confidence ?? Self.typicalConfidence(kind))
        lock.lock()
        loadIfNeeded()
        var state = kinds[kind] ?? KindState(model: Self.freshModel(kind, now: situation.date))
        learn(&state, x: x, situation: situation, y: y, weight: weight, offset: offset, at: max(situation.date, state.model.updated))
        if fromAnswer { state.answers += 1 }
        kinds[kind] = state
        lock.unlock()
        if settleNow { settle(kind) }
    }

    /// Called with the lock held.
    private func learn(_ state: inout KindState, x: [Double], situation: Situation, y: Double, weight: Double, offset: Double, at now: Date) {
        state.model.relax(to: now, halfLife: Self.halfLife)
        state.model.learn(x, label: y, weight: weight, offset: offset, at: now)
        state.examples.append(.init(x: x, y: y, weight: weight, offset: offset, at: now))
        if state.examples.count > Self.keep { state.examples.removeFirst(state.examples.count - Self.keep) }
        state.tally.add(situation, y: y, weight: weight, calendar: calendar)
    }

    /// After a label: refit (now, in tests; a moment later off the main thread, in the app), then save.
    private func settle(_ kind: String) {
        if refitsInline { refit(kind); persist(kind); return }
        lock.lock()
        let already = !refitting.insert(kind).inserted
        lock.unlock()
        guard !already else { return }
        // A beat later, so a burst of labels (an answer teaches several) refits once.
        work.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.refitting.remove(kind); self.lock.unlock()
            self.refit(kind)
            self.persist(kind)
        }
    }

    /// The exact belief over every kept reaction.
    func refit(_ kind: String) {
        lock.lock()
        guard let s = kinds[kind], !s.examples.isEmpty else { lock.unlock(); return }
        let examples = s.examples, start = s.model.mean
        let now = max(s.model.updated, examples.last?.at ?? s.model.updated)
        lock.unlock()
        let fitted = BayesLogit.fit(priorMean: [Double](repeating: 0, count: ContextFeatures.count), priorVariance: Self.priorVariance(for: kind),
                                    examples: examples, now: now, halfLife: Self.halfLife, start: start)
        lock.lock()
        // Only if nothing new arrived meanwhile; otherwise the next refit covers it.
        if kinds[kind]?.examples.count == examples.count, kinds[kind]?.examples.last == examples.last {
            kinds[kind]?.model = fitted
        }
        lock.unlock()
    }

    // MARK: What it knows

    func state(_ kind: String) -> KindState? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return kinds[kind]
    }

    var knownKinds: [String] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return kinds.keys.sorted()
    }

    /// Back to the starting point for one kind.
    func forget(kind: String) {
        lock.lock()
        loadIfNeeded()
        kinds[kind] = nil
        pending = pending.filter { $0.value.kind != kind }
        lock.unlock()
        store?.deleteLearner("policy.\(kind)")
    }

    func reset(persist: Bool = true) {
        lock.lock()
        kinds = [:]
        pending = [:]
        loaded = true
        lock.unlock()
        if persist { store?.deleteLearners(prefix: "policy.") }
    }

    // MARK: Why

    /// One line for the card: the evidence behind showing it, in plain words.
    private func why(_ s: KindState, _ situation: Situation, p: Double, exploring: Bool) -> String {
        let part = ContextFeatures.Part(hour: calendar.component(.hour, from: situation.date))
        let modeIndex = WorkMode.allCases.firstIndex(of: situation.mode)
        if exploring { return "Checking in — you passed on a few of these lately" }
        func took(_ t: [Double]) -> (Int, Int)? {
            let yes = Int(t[0].rounded()), all = Int((t[0] + t[1]).rounded())
            return all >= 2 && t[0] >= t[1] ? (yes, all) : nil
        }
        if let (yes, all) = took(s.tally.byPart[part.rawValue]) { return "You took \(yes) of \(all) like this \(part.label)" }
        if let m = modeIndex, ![.other, .idle].contains(WorkMode.allCases[m]), let (yes, all) = took(s.tally.byMode[m]) {
            return "You took \(yes) of \(all) while \(WorkMode.allCases[m].label.lowercased())"
        }
        if s.model.evidence < 0.5 { return "A first guess — Flow learns from what you do with it" }
        return "You take about \(Int((p * 100).rounded()))% of these"
    }

    // MARK: Storage

    /// Called with the lock held.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let store else { return }
        let decoder = JSONDecoder()
        for (key, data) in store.learnerStates(prefix: "policy.") {
            // A saved state from an older layout is dropped rather than misread.
            guard let s = try? decoder.decode(KindState.self, from: data), s.model.dimension == ContextFeatures.count else { continue }
            kinds[String(key.dropFirst("policy.".count))] = s
        }
    }

    /// Encoded and written off the main thread.
    private func persist(_ kind: String) {
        guard let store else { return }
        work.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let state = self.kinds[kind]
            self.lock.unlock()
            guard let state, let data = try? JSONEncoder().encode(state) else { return }
            store.saveLearner("policy.\(kind)", data)
        }
    }

    /// The first launch with this policy: what you did with suggestions before still counts. Replays the old
    /// feedback rows (time of day is all they carry) once, off the main thread.
    func adoptHistory(completion: (@Sendable () -> Void)? = nil) {
        guard let store else { return }
        work.async { [self] in
            guard store.learnerStates(prefix: "policy.adopted").isEmpty else { completion?(); return }
            var touched = Set<String>()
            for r in store.feedbackRows(since: Date().addingTimeInterval(-60 * 86_400)) {
                guard let outcome = Outcome(rawValue: r.outcome), let label = outcome.label else { continue }
                teach(kind: r.kind, situation: Situation(date: r.ts), label: label.y, weight: label.weight, settle: false)
                lock.lock()
                switch outcome {
                case .accepted: kinds[r.kind]?.accepted += 1
                case .dismissed: kinds[r.kind]?.dismissed += 1
                case .ignored: kinds[r.kind]?.ignored += 1
                case .superseded: break
                }
                lock.unlock()
                touched.insert(r.kind)
            }
            for kind in touched { refit(kind); persist(kind) }
            store.saveLearner("policy.adopted", Data("{}".utf8))
            completion?()
        }
    }
}
