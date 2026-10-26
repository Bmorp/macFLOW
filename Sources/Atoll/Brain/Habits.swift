import AppKit
import NaturalLanguage

/// Flow's model of your habits: what you do next, learned from what you did next in situations like this one.
/// Each moment you switched to something else becomes an example — the situation (the app, the window, the project,
/// as meaning, through Apple's on-device sentence embedding; and the time of day) and what came next. Asked "what now?",
/// it finds the past situations closest to this one and lets them vote. Retrained every few hours from your own
/// history, on this Mac; nothing leaves it.
final class Habits: @unchecked Sendable {
    static let shared = Habits()

    struct Example {
        let vector: [Float]      // situation meaning + time features, normalised
        let next: String         // bundle identifier
        let nextName: String
        let project: String
        let when: Date
    }

    struct Prediction: Equatable {
        let bundle: String
        let name: String
        let project: String
        /// Share of the (similarity-weighted) neighbours that agree.
        let confidence: Double
        let support: Int
    }

    private let queue = DispatchQueue(label: "atoll.habits", qos: .utility)
    private var examples: [Example] = []
    private lazy var embedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)
    private(set) var trainedAt = Date.distantPast
    /// Readable habits, for Settings and Flow ("After Zoom you usually open Xcode").
    private(set) var sentences: [String] = []

    var count: Int { queue.sync { examples.count } }

    /// The situation as a vector: what it means, and when it is (time as a point on a circle, so 11 PM is near 1 AM).
    private func vector(app: String, title: String, project: String, mode: String, at date: Date) -> [Float]? {
        let text = [app, project, title, mode].filter { !$0.isEmpty }.joined(separator: " · ")
        guard !text.isEmpty, let v = embedding?.vector(for: text) else { return nil }
        let cal = Calendar.current
        let hour = Double(cal.component(.hour, from: date)) + Double(cal.component(.minute, from: date)) / 60
        let angle = hour / 24 * 2 * .pi
        let weekend: Float = [1, 7].contains(cal.component(.weekday, from: date)) ? 1 : 0
        // Time carries real weight but doesn't drown the meaning.
        var f = v.map { Float($0) } + [Float(cos(angle)) * 0.6, Float(sin(angle)) * 0.6, weekend * 0.4]
        let norm = sqrt(f.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { f = f.map { $0 / norm } }
        return f
    }

    /// Learns from the last three weeks of moments: every change of app is "in this situation, you went to that".
    func train() {
        queue.async {
            let moments = BrainStore.shared.moments(from: Date().addingTimeInterval(-21 * 86_400), limit: 20_000)
            var out: [Example] = []
            for (a, b) in zip(moments, moments.dropFirst()) where a.bundle != b.bundle && !b.bundle.isEmpty
                && b.ts.timeIntervalSince(a.ts) < 20 * 60 && b.mode != "idle" {
                guard let v = self.vector(app: a.app, title: a.title, project: a.project, mode: a.mode, at: b.ts) else { continue }
                out.append(Example(vector: v, next: b.bundle, nextName: b.app, project: b.project, when: b.ts))
            }
            self.examples = Array(out.suffix(4000))
            self.trainedAt = Date()
            self.sentences = Self.describe(moments)
        }
    }

    /// What you'll likely do next, from here. Nil unless the neighbours mostly agree.
    func predict(app: String, bundle: String, title: String, project: String, mode: String, at date: Date = Date(),
                 completion: @escaping @Sendable (Prediction?) -> Void) {
        queue.async {
            guard self.examples.count >= 30, let q = self.vector(app: app, title: title, project: project, mode: mode, at: date) else {
                completion(nil); return
            }
            var scored: [(Float, Example)] = []
            for e in self.examples {
                var dot: Float = 0
                for i in 0..<min(q.count, e.vector.count) { dot += q[i] * e.vector[i] }
                scored.append((dot, e))
            }
            let k = scored.sorted { $0.0 > $1.0 }.prefix(14).filter { $0.0 > 0.55 && $0.1.next != bundle }
            guard k.count >= 6 else { completion(nil); return }
            var votes: [String: (w: Float, n: Int, e: Example)] = [:]
            for (s, e) in k {
                let cur = votes[e.next]
                votes[e.next] = ((cur?.w ?? 0) + s, (cur?.n ?? 0) + 1, cur?.e ?? e)
            }
            let total = votes.values.reduce(0) { $0 + $1.w }
            guard let best = votes.max(by: { $0.value.w < $1.value.w }), total > 0 else { completion(nil); return }
            completion(Prediction(bundle: best.key, name: best.value.e.nextName, project: best.value.e.project,
                                  confidence: Double(best.value.w / total), support: best.value.n))
        }
    }

    /// The clearest transitions, as sentences: from an app you use a lot, where you go next more than half the time.
    static func describe(_ moments: [BrainStore.Moment]) -> [String] {
        var from: [String: [String: Int]] = [:]
        var names: [String: String] = [:]
        for (a, b) in zip(moments, moments.dropFirst()) where a.bundle != b.bundle && !a.bundle.isEmpty && !b.bundle.isEmpty
            && b.ts.timeIntervalSince(a.ts) < 20 * 60 {
            from[a.bundle, default: [:]][b.bundle, default: 0] += 1
            names[a.bundle] = a.app
            names[b.bundle] = b.app
        }
        var out: [(Int, String)] = []
        for (a, nexts) in from {
            let total = nexts.values.reduce(0, +)
            guard total >= 6, let top = nexts.max(by: { $0.value < $1.value }), Double(top.value) / Double(total) >= 0.5,
                  let an = names[a], let bn = names[top.key], !an.isEmpty, !bn.isEmpty else { continue }
            out.append((total, "After \(an) you usually go to \(bn) (\(Int(Double(top.value) / Double(total) * 100))% of the time)."))
        }
        return out.sorted { $0.0 > $1.0 }.prefix(4).map(\.1)
    }
}

extension Memory {
    /// Your interests, as one vector: the meaning of what you've worked on and read lately, newer weighing more.
    func interest(completion: @escaping @Sendable ([Float]?) -> Void) {
        allEntries { entries in
            let now = Date()
            let recent = entries.filter { ["work", "read", "learn", "told", "meeting"].contains($0.kind) && now.timeIntervalSince($0.date) < 21 * 86_400 }
            guard recent.count >= 5, let dims = recent.first?.vector.count else { completion(nil); return }
            var sum = [Float](repeating: 0, count: dims)
            for e in recent {
                let w = Float(exp(-now.timeIntervalSince(e.date) / (7 * 86_400)))   // a week's half-life, roughly
                for i in 0..<min(dims, e.vector.count) { sum[i] += e.vector[i] * w }
            }
            let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
            completion(norm > 0 ? sum.map { $0 / norm } : nil)
        }
    }

    /// How close a piece of text is to a vector (e.g. your interests): cosine, −1…1.
    func closeness(of texts: [String], to target: [Float], completion: @escaping @Sendable ([Float]) -> Void) {
        withEmbedding { embed in
            let scores: [Float] = texts.map { t in
                guard let v = embed(t) else { return -1 }
                var dot: Float = 0
                for i in 0..<min(v.count, target.count) { dot += v[i] * target[i] }
                return dot
            }
            completion(scores)
        }
    }
}
