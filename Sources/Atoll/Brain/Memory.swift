import Foundation
import NaturalLanguage

/// Flow's long memory: what you worked on, hour by hour; what each meeting decided; the days' shapes; what you told it.
/// Each memory is a sentence and its meaning as a vector (Apple's on-device sentence embedding), so Flow can find
/// "when did I last work on pricing?" by meaning, not keywords — and bring the relevant past into what it says.
/// Kept in Mac Flow's folder, never sent anywhere; forgotten with the rest of the Brain.
final class Memory: @unchecked Sendable {
    static let shared = Memory()

    struct Entry: Codable, Equatable {
        let id: String
        let date: Date
        let kind: String        // work, meeting, day, told, plan
        let text: String
        let vector: [Float]
    }

    struct Hit: Equatable {
        let entry: Entry
        let score: Float
    }

    private let queue = DispatchQueue(label: "atoll.memory", qos: .utility)
    private var entries: [Entry] = []
    private var ids = Set<String>()
    private var loaded = false
    private lazy var embedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)
    private static let file = "memory.json"
    private static let cap = 4000

    var count: Int { queue.sync { entries.count } }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        entries = Storage.load([Entry].self, from: Self.file) ?? []
        ids = Set(entries.map(\.id))
    }

    /// The meaning of a sentence, normalised (so a dot product is the cosine).
    private func vector(_ text: String) -> [Float]? {
        guard let v = embedding?.vector(for: text) else { return nil }
        let f = v.map { Float($0) }
        let norm = sqrt(f.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? f.map { $0 / norm } : nil
    }

    /// Remembers sentences not already known (by id). Runs on Memory's own queue.
    func remember(_ items: [(id: String, date: Date, kind: String, text: String)]) {
        queue.async {
            self.loadIfNeeded()
            var added = false
            for item in items where !self.ids.contains(item.id) {
                guard let v = self.vector(item.text) else { continue }
                self.entries.append(Entry(id: item.id, date: item.date, kind: item.kind, text: item.text, vector: v))
                self.ids.insert(item.id)
                added = true
            }
            guard added else { return }
            if self.entries.count > Self.cap {
                self.entries.sort { $0.date < $1.date }
                self.entries.removeFirst(self.entries.count - Self.cap)
                self.ids = Set(self.entries.map(\.id))
            }
            Storage.save(self.entries, to: Self.file)
        }
    }

    /// The memories closest in meaning to a question, best first — newer ones win ties.
    func recall(_ question: String, limit: Int = 6, kinds: Set<String>? = nil, completion: @escaping @Sendable ([Hit]) -> Void) {
        queue.async {
            self.loadIfNeeded()
            guard let q = self.vector(question) else { completion([]); return }
            let now = Date()
            var hits: [Hit] = []
            for e in self.entries where kinds?.contains(e.kind) ?? true {
                var dot: Float = 0
                for i in 0..<min(q.count, e.vector.count) { dot += q[i] * e.vector[i] }
                // A gentle preference for recent memories: a month old costs 0.05.
                let age = Float(now.timeIntervalSince(e.date) / (30 * 86_400))
                hits.append(Hit(entry: e, score: dot - min(0.1, age * 0.05)))
            }
            completion(Array(hits.sorted { $0.score > $1.score }.prefix(limit).filter { $0.score > 0.25 }))
        }
    }

    /// Recall, waiting for the answer (for Flow's tools, which are already off the main thread).
    func recall(_ question: String, limit: Int = 6) async -> [Hit] {
        await withCheckedContinuation { c in recall(question, limit: limit) { c.resume(returning: $0) } }
    }

    /// Every memory, on Memory's queue (for things computed from all of them, like your interests).
    func allEntries(_ body: @escaping @Sendable ([Entry]) -> Void) {
        queue.async {
            self.loadIfNeeded()
            body(self.entries)
        }
    }

    /// The sentence embedding, on Memory's queue (it isn't documented as thread-safe).
    func withEmbedding(_ body: @escaping @Sendable (_ embed: (String) -> [Float]?) -> Void) {
        queue.async { body { self.vector($0) } }
    }

        func forgetEverything() {
        queue.async {
            self.entries = []
            self.ids = []
            Storage.save(self.entries, to: Self.file)
        }
    }

    /// Memories as lines Flow can read.
    static func lines(_ hits: [Hit]) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, h:mm a"
        return hits.map { "- \(f.string(from: $0.entry.date)): \($0.entry.text)" }.joined(separator: "\n")
    }
}

// MARK: - What goes into memory

/// Every hour or so, condenses what's new into memories: an hour of work at a time (from Rewind's moments), each
/// session's summary, finished priorities, meeting notes and what you told Flow.
@MainActor
final class MemoryKeeper {
    static let shared = MemoryKeeper()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { MemoryKeeper.shared.collect() }
        let t = Timer(timeInterval: 3600, repeats: true) { _ in MainActor.assumeIsolated { MemoryKeeper.shared.collect() } }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func collect() {
        guard Prefs.shared.brainLevel != BrainLevel.off.rawValue else { return }
        let plan = PlanStore.shared.plan
        let facts = BrainStore.shared.facts().filter { $0.key.hasPrefix("told:") || $0.key == "meeting:last" }
        DispatchQueue.global(qos: .utility).async {
            let since = Date().addingTimeInterval(-3 * 86_400)
            let store = BrainStore.shared
            var items: [(id: String, date: Date, kind: String, text: String)] = []
            // An hour of work: what you were on, in which apps, with which documents and music.
            let moments = store.moments(from: since)
            let cal = Calendar.current
            let byHour = Dictionary(grouping: moments) { cal.dateInterval(of: .hour, for: $0.ts)?.start ?? $0.ts }
            for (hour, ms) in byHour where hour.addingTimeInterval(3600) < Date() {
                items.append((id: "hour.\(Int(hour.timeIntervalSince1970))", date: hour, kind: "work", text: Self.describe(hour: hour, ms)))
            }
            for ep in store.episodes(since: since, limit: 300) where ep.end.timeIntervalSince(ep.start) >= 10 * 60 {
                let mode = WorkMode(rawValue: ep.mode)?.label ?? "Working"
                let text = "\(mode)\(ep.project.isEmpty ? "" : " on \(ep.project)") for \(BrainEngine.duration(ep.end.timeIntervalSince(ep.start))): \(ep.summary)"
                items.append((id: "ep.\(ep.id)", date: ep.start, kind: "work", text: text))
            }
            for item in plan.items where item.kind == .focus && item.done {
                items.append((id: "done.\(item.id)", date: item.start, kind: "plan", text: "Finished “\(item.title)” (planned \(item.minutes) min)"))
            }
            for f in facts {
                items.append((id: "fact.\(f.key).\(Int(f.updated.timeIntervalSince1970))", date: f.updated, kind: f.key.hasPrefix("told") ? "told" : "meeting", text: f.value))
            }
            Memory.shared.remember(items)
        }
    }

    /// "10–11 AM: coding on Atoll in Xcode (IslandModel.swift, PlanView.swift), listening to M83."
    nonisolated static func describe(hour: Date, _ ms: [BrainStore.Moment]) -> String {
        let modes = Dictionary(grouping: ms, by: \.mode).max { $0.value.count < $1.value.count }?.key ?? "other"
        let projects = Array(Set(ms.map(\.project).filter { !$0.isEmpty })).prefix(2)
        let apps = Array(NSOrderedSet(array: ms.map(\.app).filter { !$0.isEmpty }).array as? [String] ?? []).prefix(3)
        let docs = Array(NSOrderedSet(array: ms.compactMap { URL(string: $0.document)?.lastPathComponent }.filter { !$0.isEmpty }).array as? [String] ?? []).prefix(3)
        let titles = Array(NSOrderedSet(array: ms.map(\.title).filter { !$0.isEmpty }).array as? [String] ?? []).prefix(2)
        let tracks = Array(Set(ms.map(\.track).filter { !$0.isEmpty })).prefix(2)
        let f = DateFormatter()
        f.dateFormat = "h a"
        var s = "\(f.string(from: hour))–\(f.string(from: hour.addingTimeInterval(3600))): \((WorkMode(rawValue: modes)?.label ?? "Working").lowercased())"
        if !projects.isEmpty { s += " on \(projects.joined(separator: " and "))" }
        if !apps.isEmpty { s += " in \(apps.joined(separator: ", "))" }
        if !docs.isEmpty { s += " (\(docs.joined(separator: ", ")))" } else if !titles.isEmpty { s += " (\(titles.joined(separator: "; ").prefix(120)))" }
        if !tracks.isEmpty { s += ", listening to \(tracks.joined(separator: " and "))" }
        return s
    }
}
