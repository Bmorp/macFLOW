import Foundation

/// "This was writing, not browsing": the corrections you make to what Flow thought you were doing, generalised by
/// meaning. Each correction is the moment (app, project, window title) embedded on this Mac, with the mode you gave
/// it; a new moment close to corrected ones takes their mode, ahead of `Understanding`'s rules, when they agree.
///
/// One correction settles that exact window; two that agree settle the app's other windows like it.
final class ModeCorrections: @unchecked Sendable {
    static let shared = ModeCorrections(store: BrainStore.shared, embedder: .shared)

    struct Verdict: Equatable, Sendable {
        let mode: WorkMode
        /// Share of the neighbours' (similarity-weighted) vote.
        let confidence: Double
        let support: Int
        let similarity: Double
    }

    private struct Example {
        let vector: [Float]
        let bundle: String
        let mode: WorkMode
    }

    private let store: BrainStore?
    private let embedder: TextEmbedder
    private let queue = DispatchQueue(label: "atoll.brain.corrections", qos: .utility)
    private let lock = NSLock()
    private var examples: [Example] = []
    private var records: [BrainStore.Correction] = []
    private var cache: [String: WorkMode?] = [:]
    private var computing: Set<String> = []
    private var loaded = false
    /// Called (on the main queue) when a correction might change the mode of what's on screen.
    var onChange: (@MainActor @Sendable () -> Void)?

    init(store: BrainStore?, embedder: TextEmbedder) {
        self.store = store
        self.embedder = embedder
        store?.onErase { [weak self] in self?.reset(persist: false) }
    }

    static func text(app: String, title: String, project: String) -> String {
        [app, project, title].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Similarity of two moments: what they say, and whether they're the same app.
    private static func similarity(_ v: [Float], _ bundle: String, _ e: Example) -> Double {
        0.6 * Double(TextEmbedder.cosine(v, e.vector)) + (bundle == e.bundle ? 0.4 : 0)
    }

    // MARK: Correcting

    /// `ModeCorrections.correct(moment:to:)`: what Rewind and the day ring call when you say "this was writing".
    static func correct(moment: BrainStore.Moment, to mode: WorkMode, alongWith run: [BrainStore.Moment] = []) {
        shared.correct(moment: moment, to: mode, alongWith: run)
    }

    /// You said this moment (and the run of moments like it after it) was really `mode`. Rewrites them in the
    /// record, and learns from it at once.
    func correct(moment: BrainStore.Moment, to mode: WorkMode, alongWith run: [BrainStore.Moment] = []) {
        let c = BrainStore.Correction(ts: Date(), bundle: moment.bundle, app: moment.app, title: moment.title, project: moment.project,
                                      from: moment.mode, to: mode.rawValue)
        store?.save(c)
        store?.relabelMoments(([moment] + run).map(\.id).filter { $0 > 0 }, mode: mode.rawValue)
        let text = Self.text(app: moment.app, title: moment.title, project: moment.project)
        let learn = { [self] in
            loadIfNeeded()
            guard let v = embedder.vector(text) else { return }
            lock.lock()
            examples.append(Example(vector: v, bundle: moment.bundle, mode: mode))
            records.append(c)
            cache.removeAll()
            let notify = onChange
            lock.unlock()
            if let notify { DispatchQueue.main.async { notify() } }
        }
        if store == nil { learn() } else { queue.async(execute: learn) }
    }

    // MARK: Predicting

    /// What the corrections say about a moment, or nil when they say nothing confident. Blocking: off the main thread.
    func predict(app: String, bundle: String, title: String, project: String) -> Verdict? {
        loadIfNeeded()
        lock.lock()
        let all = examples
        lock.unlock()
        guard !all.isEmpty, let v = embedder.vector(Self.text(app: app, title: title, project: project)) else { return nil }
        let near = all.map { (Self.similarity(v, bundle, $0), $0) }.filter { $0.0 >= 0.7 }.sorted { $0.0 > $1.0 }.prefix(7)
        guard let best = near.first else { return nil }
        var votes: [WorkMode: (w: Double, n: Int)] = [:]
        for (s, e) in near {
            let w = pow(s, 4)
            votes[e.mode, default: (0, 0)].w += w
            votes[e.mode, default: (0, 0)].n += 1
        }
        let total = votes.values.reduce(0) { $0 + $1.w }
        guard let win = votes.max(by: { $0.value.w < $1.value.w }), total > 0 else { return nil }
        let share = win.value.w / total
        // That exact window, or two corrections that agree.
        guard share >= 0.7, best.0 >= 0.92 || win.value.n >= 2 else { return nil }
        return Verdict(mode: win.key, confidence: share, support: win.value.n, similarity: best.0)
    }

    /// For the main thread: the override for what's on screen if it's known; otherwise works it out in the background
    /// (and calls `onChange` if it turns out to matter).
    func override(app: String, bundle: String, title: String, project: String) -> WorkMode? {
        let key = bundle + "|" + title + "|" + project
        lock.lock()
        // Nothing corrected yet: the rules decide, at no cost.
        if loaded && examples.isEmpty { lock.unlock(); return nil }
        if let hit = cache[key] { lock.unlock(); return hit }
        let start = computing.insert(key).inserted
        lock.unlock()
        guard start else { return nil }
        queue.async { [self] in
            let verdict = predict(app: app, bundle: bundle, title: title, project: project)
            lock.lock()
            computing.remove(key)
            if cache.count > 500 { cache.removeAll() }
            cache[key] = .some(verdict?.mode)
            lock.unlock()
            if verdict != nil, let onChange { DispatchQueue.main.async { onChange() } }
        }
        return nil
    }

    // MARK: What it knows

    /// Corrections, grouped by app: "Notion is for writing", with how many times you said so.
    func summary() -> [(bundle: String, app: String, mode: WorkMode, count: Int)] {
        loadIfNeeded()
        lock.lock()
        let all = records
        lock.unlock()
        var groups: [String: (app: String, modes: [WorkMode: Int])] = [:]
        for r in all {
            guard let m = WorkMode(rawValue: r.to) else { continue }
            groups[r.bundle, default: (r.app, [:])].modes[m, default: 0] += 1
        }
        return groups.compactMap { bundle, g in
            g.modes.max { $0.value < $1.value }.map { (bundle, g.app, $0.key, $0.value) }
        }.sorted { $0.count > $1.count }
    }

    func forget(bundle: String) {
        store?.deleteCorrections(bundle: bundle)
        lock.lock()
        let keep = examples.indices.filter { examples[$0].bundle != bundle }
        examples = keep.map { examples[$0] }
        records.removeAll { $0.bundle == bundle }
        cache.removeAll()
        lock.unlock()
        if let onChange { DispatchQueue.main.async { onChange() } }
    }

    func reset(persist: Bool = true) {
        if persist { store?.deleteCorrections(bundle: nil) }
        lock.lock()
        examples = []
        records = []
        cache = [:]
        loaded = true
        lock.unlock()
    }

    private func loadIfNeeded() {
        lock.lock()
        guard !loaded else { lock.unlock(); return }
        loaded = true
        lock.unlock()
        guard let store else { return }
        let saved = store.corrections()
        var out: [Example] = []
        for c in saved {
            guard let m = WorkMode(rawValue: c.to), let v = embedder.vector(Self.text(app: c.app, title: c.title, project: c.project)) else { continue }
            out.append(Example(vector: v, bundle: c.bundle, mode: m))
        }
        lock.lock()
        examples = out + examples
        records = saved + records
        cache.removeAll()
        lock.unlock()
    }
}
