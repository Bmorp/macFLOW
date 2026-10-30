import Foundation

// The Brain's models of your tasks: how long one will take (from how long ones like it took you), whether you've
// finished one (from what you've been doing), and which matter most (from what you finish first, put off, or drop).

/// How long a task will take, learned from the focused time your finished tasks actually took.
///
/// The tasks most like it by meaning (title embeddings) vote, weighted by how alike they are, in log-minutes; then
/// two corrections learned from your history: how far its project usually runs from that, and — when you gave an
/// estimate yourself — how far your own estimates usually run from what happens.
final class DurationEstimator: @unchecked Sendable {
    struct Example: Sendable {
        let vector: [Float]
        let task: BrainStore.TaskExample
        /// log(actual) − what the estimator said before it learned this one.
        let residual: Double
    }

    private let embedder: TextEmbedder
    private let lock = NSLock()
    private var examples: [Example] = []
    /// How wrong each estimate was when its task finished (|log error|), for the trend in Settings.
    private(set) var errors: [(at: Date, error: Double)] = []
    static let fallback = 30.0
    static let cap = 2000

    init(embedder: TextEmbedder) { self.embedder = embedder }

    var count: Int { lock.lock(); defer { lock.unlock() }; return examples.count }

    static func text(_ title: String, project: String?) -> String { [project ?? "", title].filter { !$0.isEmpty }.joined(separator: " · ") }

    struct Guess: Sendable, Equatable {
        var minutes: Double
        var low: Double
        var high: Double
        var confidence: Double
        var why: String
        /// The kNN part alone, before project and estimate corrections (what residuals are measured against).
        var neighbourLog: Double
    }

    /// The estimate. Blocking (it embeds the title): fine on a background queue, or for a cached title.
    func estimate(title: String, project: String?, mode: WorkMode? = nil, userEstimate: Double? = nil) -> Guess {
        lock.lock()
        let all = examples
        lock.unlock()
        let logs = all.map { log(max(1, $0.task.minutes)) }
        let global = logs.isEmpty ? log(Self.fallback) : logs.sorted()[logs.count / 2]
        var weight = 0.0, sum = 0.0, spread = 0.0
        var nearest: (sim: Float, title: String)?
        var support = 0
        if let v = embedder.vector(Self.text(title, project: project)), !all.isEmpty {
            let near = all.map { (TextEmbedder.cosine(v, $0.vector), $0) }.filter { $0.0 >= 0.35 }.sorted { $0.0 > $1.0 }.prefix(6)
            for (s, e) in near {
                let w = Double(s * s * s)
                weight += w
                sum += w * log(max(1, e.task.minutes))
                support += 1
            }
            if weight > 0 {
                let mean = sum / weight
                for (s, e) in near { spread += Double(s * s * s) * pow(log(max(1, e.task.minutes)) - mean, 2) }
                spread = (spread / weight).squareRoot()
            }
            nearest = near.first.map { ($0.0, $0.1.task.title) }
        }
        // The neighbours, pulled gently toward your typical task.
        let w0 = 0.3
        let neighbourLog = (sum + w0 * global) / (weight + w0)
        var est = neighbourLog
        // Your project's habit: how far its tasks run from what their neighbours said.
        if let p = project, !p.isEmpty {
            let r = all.filter { $0.task.project == p }.map(\.residual)
            if !r.isEmpty { est += r.reduce(0, +) / (Double(r.count) + 2) }
        }
        if let m = mode {
            let r = all.filter { $0.task.mode == m.rawValue }.map(\.residual)
            if !r.isEmpty { est += 0.5 * r.reduce(0, +) / (Double(r.count) + 3) }
        }
        // Your own estimate, corrected by how yours usually turn out.
        var biasLine: String?
        if let u = userEstimate, u > 0 {
            let pairs = all.compactMap { e in e.task.estimate.map { log(max(1, e.task.minutes)) - log(max(1, $0)) } }
            let bias = pairs.reduce(0, +) / (Double(pairs.count) + 3)
            let mine = log(u) + bias
            est = weight >= 1 ? 0.6 * mine + 0.4 * est : mine
            if pairs.count >= 3, abs(bias) > 0.1 {
                let pct = Int((abs(exp(bias) - 1) * 100).rounded())
                biasLine = bias > 0 ? "your estimates usually run \(pct)% short" : "you usually finish \(pct)% early"
            }
        }
        let sigma = (weight * spread + 0.6) / (weight + 1)
        let minutes = exp(est)
        let confidence = min(0.95, (1 - exp(-weight)) * exp(-sigma))
        let m = TaskBrain.minutesText(minutes)
        let why: String
        if let biasLine { why = "About \(m) — \(biasLine)" }
        else if let n = nearest, support > 0 {
            why = "Like “\(n.title.prefix(28))”\(support > 1 ? " and \(support - 1) more" : ""), about \(m)"
        } else if !all.isEmpty { why = "About your usual task, \(m)" }
        else { why = "A first guess — Flow learns from the time you spend" }
        return Guess(minutes: minutes, low: exp(est - 1.28 * sigma), high: exp(est + 1.28 * sigma), confidence: confidence, why: why,
                     neighbourLog: neighbourLog)
    }

    /// A finished task: what it really took. The estimate it would have had is scored first, so the trend is honest.
    func learn(_ t: BrainStore.TaskExample) {
        guard t.minutes >= 1, let v = embedder.vector(Self.text(t.title, project: t.project)) else { return }
        let before = estimate(title: t.title, project: t.project.isEmpty ? nil : t.project, userEstimate: t.estimate)
        let actual = log(max(1, t.minutes))
        lock.lock()
        examples.append(Example(vector: v, task: t, residual: actual - before.neighbourLog))
        if examples.count > Self.cap { examples.removeFirst(examples.count - Self.cap) }
        errors.append((t.ts, abs(log(before.minutes) - actual)))
        if errors.count > 500 { errors.removeFirst(errors.count - 500) }
        lock.unlock()
    }

    /// Rebuilds from saved examples (on launch), oldest first, so residuals mean what they meant.
    func load(_ saved: [BrainStore.TaskExample]) {
        reset()
        for t in saved { learn(t) }
    }

    func reset() {
        lock.lock(); examples = []; errors = []; lock.unlock()
    }

    /// Median relative error of the estimates made for tasks finished in a window.
    func medianError(since: Date, until: Date = .distantFuture) -> Double? {
        lock.lock()
        let e = errors.filter { $0.at >= since && $0.at < until }.map { exp($0.error) - 1 }.sorted()
        lock.unlock()
        return e.isEmpty ? nil : e[e.count / 2]
    }
}

/// Whether a task is done, from what you've been doing: how like the task your recent moments were, how long you
/// spent on it against its estimate, and whether you've moved on. A Bayesian logistic regression your answers to
/// "Done with X?" train.
enum CompletionFeatures {
    static let count = 7

    struct Moment: Sendable {
        let at: Date
        let vector: [Float]
        let project: String
    }

    /// `minutes`: how long each moment stood for (until the next one, capped).
    static func vector(task: TaskSnapshot, taskVector: [Float]?, moments: [Moment], estimate: Double, now: Date) -> [Double] {
        var x = [Double](repeating: 0, count: count)
        x[0] = 1
        let est = max(15, estimate)
        var best: Float = 0, matched = 0.0
        var lastMatch: Date?
        if let tv = taskVector {
            for (i, m) in moments.enumerated() {
                let s = TextEmbedder.cosine(tv, m.vector)
                best = max(best, s)
                guard s >= 0.5 else { continue }
                let next = i + 1 < moments.count ? moments[i + 1].at : now
                matched += min(10, max(0, next.timeIntervalSince(m.at) / 60))
                lastMatch = max(lastMatch ?? m.at, m.at)
            }
        }
        x[1] = Double(best)
        x[2] = min(2, matched / est)
        x[3] = lastMatch.map { now.timeIntervalSince($0) >= 10 * 60 ? 1 : 0 } ?? 0
        if let p = task.project, !p.isEmpty, moments.contains(where: { $0.project == p }) { x[4] = 1 }
        x[5] = min(2, task.actual / 60 / est)
        x[6] = task.status == .active ? 1 : 0
        return x
    }

    /// A task untouched reads as not done; worked on about as long as planned, then left, reads as done.
    static let priorMean: [Double] = [-2.2, 1.5, 1.2, 1.0, 0.6, 1.2, 0.3]
    static let priorVariance = [Double](repeating: 1, count: count)
}

/// Which tasks matter most to you, learned from what you do: finishing one first counts for it (and a little against
/// those you left open), starting one counts for it, putting one off or dropping it counts against.
enum ImportanceFeatures {
    static let sources: [TaskSource] = [.typed, .voice, .search, .lens, .meeting, .plan, .reminders, .flow, .drop]
    static let count = 15 + sources.count

    static func vector(_ t: TaskSnapshot, at now: Date, postponed: Int, focusProject: String?, calendar: Calendar = .current) -> [Double] {
        var x = [Double](repeating: 0, count: count)
        x[0] = 1
        x[1 + t.priority.rawValue] = 1                                     // 1…4
        let due: Int
        if let d = t.due {
            if d < now { due = 1 }
            else if calendar.isDate(d, inSameDayAs: now) { due = 2 }
            else if d.timeIntervalSince(now) < 3 * 86_400 { due = 3 }
            else { due = 4 }
        } else { due = 0 }
        x[5 + due] = 1                                                     // 5…9
        if let s = t.scheduled, calendar.isDate(s, inSameDayAs: now) { x[10] = 1 }
        x[11] = min(1.2, log1p(max(0, now.timeIntervalSince(t.created) / 86_400)) / log1p(30))
        x[12] = Double(min(postponed, 3)) / 3
        x[13] = t.estimate.map { min(1.2, log1p($0) / log1p(240)) } ?? 0
        if let p = t.project, let f = focusProject, !f.isEmpty, p.caseInsensitiveCompare(f) == .orderedSame { x[14] = 1 }
        if let i = sources.firstIndex(of: t.source) { x[15 + i] = 1 }
        return x
    }

    /// What people mostly mean: high priority and due soon matter, things put off matter less.
    static let priorMean: [Double] = {
        var m = [Double](repeating: 0, count: count)
        m[0] = -0.6
        m[2] = -0.4; m[3] = 0.4; m[4] = 1.0                                // low, medium, high
        m[6] = 1.0; m[7] = 0.8; m[8] = 0.4                                 // overdue, today, soon
        m[10] = 0.6; m[11] = -0.2; m[12] = -0.8; m[14] = 0.8
        m[15 + sources.firstIndex(of: .meeting)!] = 0.2
        return m
    }()
    static let priorVariance = [Double](repeating: 0.5, count: count)
}
