import Foundation
import Combine

/// The Brain's side of your tasks. It listens to everything that happens to them (`TaskEvents`), learns how long
/// your tasks take and which you treat as important, notices when one looks finished and asks, and offers all of it
/// back to Flow Tasks as the `TaskAdvisor`. Tasks themselves live in Flow Tasks' store; this reads them through
/// `TaskLinks.ledger` when it's there, and from the events it has seen when it isn't.
@MainActor
final class TaskBrain: TaskAdvisor {
    static let shared = TaskBrain(store: BrainStore.shared, embedder: .shared)

    let estimator: DurationEstimator
    private(set) var detector = BayesLogit(priorMean: CompletionFeatures.priorMean, priorVariance: CompletionFeatures.priorVariance)
    private(set) var importanceModel = BayesLogit(priorMean: ImportanceFeatures.priorMean, priorVariance: ImportanceFeatures.priorVariance)
    private let store: BrainStore?
    private let embedder: TextEmbedder
    private var seen: [UUID: TaskSnapshot] = [:]
    private var focused: [UUID: TimeInterval] = [:]
    private var focusModes: [UUID: [String: TimeInterval]] = [:]
    /// Estimates the Brain stored on tasks (so a different value is yours), and ones you confirmed when asked.
    private var suggested: [UUID: Double] = [:]
    private var confirmed: [UUID: Double] = [:]
    private var postponed: [UUID: Int] = [:]
    /// The latest "is it done?" reading per open task.
    private(set) var doneChecks: [UUID: (p: Double, x: [Double], at: Date)] = [:]
    private var guesses: [String: DurationEstimator.Guess] = [:]
    private var cancellable: AnyCancellable?
    private let work = DispatchQueue(label: "atoll.brain.tasks", qos: .utility)
    private var started = false
    private var scanning = false
    /// The project you said matters most this week.
    var focusProject: () -> String? = { BrainStore.shared.fact("focus:project") }
    /// The kind of work going on right now (for what a task's time was spent doing).
    var currentMode: () -> WorkMode = { WorkContext.shared.mode }

    init(store: BrainStore?, embedder: TextEmbedder) {
        self.store = store
        self.embedder = embedder
        estimator = DurationEstimator(embedder: embedder)
    }

    func start() {
        guard !started else { return }
        started = true
        TaskLinks.advisor = self
        cancellable = TaskEvents.stream.sink { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
        store?.onErase { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.reset(persist: false) } } }
        load()
    }

    // MARK: Events

    func handle(_ e: TaskEvent, now: Date = Date()) {
        switch e {
        case .added(let t):
            seen[t.id] = t
            if t.estimate == nil, TaskLinks.ledger != nil { offerEstimate(t) }
        case .updated(let t):
            if let old = seen[t.id], Self.putOff(old, t) {
                postponed[t.id, default: 0] += 1
                teachImportance(t, y: 0, weight: 0.5, now: now)
            }
            if t.status == .dropped, seen[t.id]?.status != .dropped { teachImportance(t, y: 0, weight: 0.7, now: now) }
            seen[t.id] = t
        case .started(let t):
            seen[t.id] = t
            teachImportance(t, y: 1, weight: 0.3, now: now)
        case .paused(let t, let f):
            seen[t.id] = t
            focused[t.id, default: 0] += f
            focusModes[t.id, default: [:]][currentMode().rawValue, default: 0] += f
        case .completed(let t):
            completed(t, now: now)
        case .reopened(let t):
            seen[t.id] = t
            // It wasn't done after all: whatever said it was, said so wrongly.
            if let c = doneChecks[t.id] { detector.learn(c.x, label: 0, weight: 1) }
        case .deleted(let id):
            if let t = seen[id] { teachImportance(t, y: 0, weight: 0.5, now: now) }
            seen[id] = nil
            doneChecks[id] = nil
        }
        persistMeta()
    }

    /// Scheduled or due moved later.
    static func putOff(_ old: TaskSnapshot, _ new: TaskSnapshot) -> Bool {
        if let a = old.scheduled, let b = new.scheduled, b.timeIntervalSince(a) > 3600 { return true }
        if let a = old.due, let b = new.due, b.timeIntervalSince(a) > 3600 { return true }
        return false
    }

    private func completed(_ t: TaskSnapshot, now: Date) {
        let minutes = max(t.actual, focused[t.id] ?? 0) / 60
        let mode = focusModes[t.id]?.max { $0.value < $1.value }?.key ?? ""
        let userEstimate = confirmed[t.id] ?? t.estimate.flatMap { e in suggested[t.id].map { abs($0 - e) < 0.5 } == true ? nil : e }
        if minutes >= 1 {
            let ex = BrainStore.TaskExample(id: t.id.uuidString, ts: now, title: t.title, project: t.project ?? "", mode: mode,
                                            minutes: minutes, estimate: userEstimate)
            store?.save(ex)
            if store == nil { estimator.learn(ex) } else { let est = estimator; work.async { est.learn(ex) } }
            guesses = [:]
        }
        // Done first: it mattered, a little more than what you left open.
        teachImportance(t, y: 1, weight: 1, now: now)
        for other in openTasks where other.id != t.id && other.created < now { teachImportance(other, y: 0, weight: 0.15, now: now) }
        if let c = doneChecks[t.id] { detector.learn(c.x, label: 1, weight: 0.5) }
        seen[t.id] = nil
        doneChecks[t.id] = nil
        focused[t.id] = nil
        focusModes[t.id] = nil
        persistModels()
    }

    var openTasks: [TaskSnapshot] {
        if let ledger = TaskLinks.ledger { return ledger.openTasks() }
        return seen.values.filter { $0.status == .open || $0.status == .active }.sorted { $0.created < $1.created }
    }

    // MARK: TaskAdvisor

    func estimate(for task: TaskSnapshot) -> TaskEstimate? {
        let g = guess(task)
        return TaskEstimate(minutes: g.minutes, low: g.low, high: g.high, confidence: g.confidence, why: g.why)
    }

    func importance(of task: TaskSnapshot, at date: Date) -> Double {
        let x = ImportanceFeatures.vector(task, at: date, postponed: postponed[task.id] ?? 0, focusProject: focusProject())
        return importanceModel.probability(x)
    }

    private func guess(_ t: TaskSnapshot) -> DurationEstimator.Guess {
        let user = confirmed[t.id] ?? t.estimate.flatMap { e in suggested[t.id].map { abs($0 - e) < 0.5 } == true ? nil : e }
        let key = "\(t.title)|\(t.project ?? "")|\(user ?? -1)"
        if let hit = guesses[key] { return hit }
        let g = estimator.estimate(title: t.title, project: t.project, userEstimate: user)
        if guesses.count > 300 { guesses = [:] }
        guesses[key] = g
        return g
    }

    /// A new task without an estimate: give it Flow's, when Flow has a reasonable one.
    private func offerEstimate(_ t: TaskSnapshot) {
        let est = estimator
        let title = t.title, project = t.project, id = t.id
        work.async {
            let g = est.estimate(title: title, project: project)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let me = self, g.confidence >= 0.25, let ledger = TaskLinks.ledger, ledger.task(id)?.estimate == nil else { return }
                    let m = (g.minutes / 5).rounded() * 5
                    me.suggested[id] = max(5, m)
                    ledger.suggestEstimate(id, minutes: max(5, m))
                    me.persistMeta()
                }
            }
        }
    }

    // MARK: Questions

    /// "Done with X?" for tasks that look finished, and "about 45 min?" for new ones Flow isn't sure of.
    func probes(now: Date = Date()) -> [QuestionProbe] {
        var out: [QuestionProbe] = []
        let open = openTasks
        let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, c) in doneChecks where c.p >= 0.6 && now.timeIntervalSince(c.at) < 45 * 60 {
            guard let t = byID[id] else { continue }
            out.append(QuestionProbe(key: "task.done.\(id.uuidString)", text: "Done with “\(t.title.prefix(40))”?",
                             detail: "It looks finished from what you’ve been doing.",
                             options: [.init(label: "Yes, Done", value: "yes"), .init(label: "Not Yet", value: "no")],
                             uncertainty: c.p, impact: 0.9, staleAfter: 86_400, topic: .done(task: id, title: t.title)))
        }
        for t in open where now.timeIntervalSince(t.created) < 2 * 86_400 && confirmed[t.id] == nil {
            // Only Flow's own estimates (or none): yours aren't up for question.
            if let e = t.estimate, suggested[t.id].map({ abs($0 - e) >= 0.5 }) ?? true { continue }
            let g = guess(t)
            guard g.confidence < 0.45 else { continue }
            let m = max(5, (g.minutes / 5).rounded() * 5)
            out.append(QuestionProbe(key: "task.estimate.\(t.id.uuidString)", text: "About \(Self.minutesText(m)) for “\(t.title.prefix(32))”?",
                             detail: "So the plan leaves it enough room.",
                             options: [.init(label: "Less", value: "less"), .init(label: "About Right", value: "right"), .init(label: "More", value: "more")],
                             uncertainty: 1 - g.confidence, impact: 0.5 + 0.4 * min(1, m / 120), staleAfter: nil,
                             topic: .estimate(task: t.id, title: t.title, minutes: m)))
        }
        return out
    }

    /// Your answer to "about 45 min?": it becomes the task's estimate, and when the task's done, it teaches Flow how
    /// your confirmed estimates compare with what happens.
    func applyEstimate(_ id: UUID, minutes: Double) {
        let m = max(5, (minutes / 5).rounded() * 5)
        confirmed[id] = m
        suggested[id] = m
        TaskLinks.ledger?.suggestEstimate(id, minutes: m)
        guesses = [:]
        persistMeta()
    }

    /// Your answer to "Done with X?".
    func labelDone(_ id: UUID, done: Bool) {
        guard let c = doneChecks[id] else { return }
        detector.learn(c.x, label: done ? 1 : 0, weight: 1.5)
        if !done { doneChecks[id] = nil }
        persistModels()
    }

    // MARK: Completion

    /// How likely a task is done, given your recent moments. Pure, for tests and the scan.
    func doneProbability(task: TaskSnapshot, moments: [CompletionFeatures.Moment], now: Date) -> (p: Double, x: [Double]) {
        let tv = embedder.vector(DurationEstimator.text(task.title, project: task.project))
        let est = task.estimate ?? guess(task).minutes
        let x = CompletionFeatures.vector(task: task, taskVector: tv, moments: moments, estimate: est, now: now)
        return (detector.probability(x), x)
    }

    /// Every ten minutes or so: read the last three hours of moments (off the main thread) and score open tasks.
    func scan() {
        guard !scanning, let store, !openTasks.isEmpty else { return }
        scanning = true
        let tasks = openTasks
        let estimates = Dictionary(tasks.map { ($0.id, $0.estimate ?? guess($0).minutes) }, uniquingKeysWith: { a, _ in a })
        let model = detector
        let embedder = self.embedder
        work.async {
            let now = Date()
            let moments = store.moments(from: now.addingTimeInterval(-3 * 3600)).compactMap { m -> CompletionFeatures.Moment? in
                guard m.mode != WorkMode.idle.rawValue,
                      let v = embedder.vector(ModeCorrections.text(app: m.app, title: m.title, project: m.project)) else { return nil }
                return CompletionFeatures.Moment(at: m.ts, vector: v, project: m.project)
            }
            var out: [UUID: (Double, [Double], Date)] = [:]
            for t in tasks {
                let tv = embedder.vector(DurationEstimator.text(t.title, project: t.project))
                let x = CompletionFeatures.vector(task: t, taskVector: tv, moments: moments, estimate: estimates[t.id] ?? 30, now: now)
                out[t.id] = (model.probability(x), x, now)
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let me = self else { return }
                    me.scanning = false
                    for (id, v) in out { me.doneChecks[id] = (v.0, v.1, v.2) }
                }
            }
        }
    }

    #if DEBUG
    func debugSetCheck(_ id: UUID, p: Double, x: [Double], at: Date) { doneChecks[id] = (p, x, at) }
    #endif

    // MARK: Importance

    private func teachImportance(_ t: TaskSnapshot, y: Double, weight: Double, now: Date) {
        let x = ImportanceFeatures.vector(t, at: now, postponed: postponed[t.id] ?? 0, focusProject: focusProject())
        importanceModel.learn(x, label: y, weight: weight, at: now)
    }

    // MARK: Storage

    private struct Meta: Codable {
        var suggested: [UUID: Double] = [:]
        var confirmed: [UUID: Double] = [:]
        var postponed: [UUID: Int] = [:]
    }

    private func load() {
        guard let store else { return }
        let states = store.learnerStates(prefix: "task.")
        let d = JSONDecoder()
        if let data = states["task.done"], let m = try? d.decode(BayesLogit.self, from: data), m.dimension == CompletionFeatures.count { detector = m }
        if let data = states["task.importance"], let m = try? d.decode(BayesLogit.self, from: data), m.dimension == ImportanceFeatures.count { importanceModel = m }
        if let data = states["task.meta"], let m = try? d.decode(Meta.self, from: data) {
            suggested = m.suggested; confirmed = m.confirmed; postponed = m.postponed
        }
        let est = estimator
        work.async { est.load(store.taskExamples()) }
    }

    private func persistModels() {
        guard let store else { return }
        let done = detector, imp = importanceModel
        work.async {
            let e = JSONEncoder()
            if let a = try? e.encode(done) { store.saveLearner("task.done", a) }
            if let b = try? e.encode(imp) { store.saveLearner("task.importance", b) }
        }
    }

    private func persistMeta() {
        guard let store else { return }
        let meta = Meta(suggested: suggested, confirmed: confirmed, postponed: postponed)
        work.async { if let data = try? JSONEncoder().encode(meta) { store.saveLearner("task.meta", data) } }
    }

    func reset(persist: Bool = true) {
        detector.forget()
        importanceModel.forget()
        seen = [:]; focused = [:]; focusModes = [:]; suggested = [:]; confirmed = [:]; postponed = [:]; doneChecks = [:]; guesses = [:]
        estimator.reset()
        if persist {
            store?.deleteLearners(prefix: "task.")
            store?.deleteTaskExamples()
        }
    }

    // MARK: Words

    nonisolated static func minutesText(_ m: Double) -> String {
        let r = Int((m / 5).rounded() * 5)
        guard r >= 60 else { return "\(max(5, r)) min" }
        let h = r / 60, rest = r % 60
        return rest == 0 ? "\(h) h" : "\(h) h \(rest) min"
    }
}
