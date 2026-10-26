import AppKit
import UniformTypeIdentifiers

struct FileHit: Identifiable, Equatable {
    let id: String          // path
    let name: String
    let contentType: String?
    let modified: Date?
    let size: Int64?

    var url: URL { URL(fileURLWithPath: id) }

    var folder: String {
        let parent = (id as NSString).deletingLastPathComponent
        return parent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Icon by type only — never touches the file, so no folder-access prompts.
    @MainActor var icon: NSImage { IconCache.type(contentType, isFolder: url.hasDirectoryPath) }

    var kind: String {
        contentType.flatMap { UTType($0)?.localizedDescription } ?? "Document"
    }
}

/// Spotlight-backed file search across the home folder (metadata only).
///
/// Everything Spotlight runs on a background queue: the query, its notifications, and reading results. Attributes are
/// fetched in one batch with the results (`valueListAttributes`) instead of one XPC round trip per attribute per item —
/// which, on the main thread, froze the island for up to 1.6 s while you typed.
@MainActor
final class FileSearch: ObservableObject {
    static let shared = FileSearch()

    @Published private(set) var hits: [FileHit] = []

    private var query: NSMetadataQuery?
    private var pending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    /// Bumped for every new query; results from an older one are dropped.
    private var generation = 0

    nonisolated private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "atoll.spotlight"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Your folders — everything in the home folder except Library and hidden ones — so matches buried in app data
    /// never crowd out the files you'd actually open.
    nonisolated(unsafe) private static var cachedScopes: (at: Date, value: [Any])?
    nonisolated private static var scopes: [Any] {
        if let c = cachedScopes, Date().timeIntervalSince(c.at) < 300 { return c.value }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let items = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let folders = items.filter { $0.lastPathComponent != "Library" && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
        let value: [Any] = folders.isEmpty ? [NSMetadataQueryUserHomeScope] : folders
        cachedScopes = (Date(), value)
        return value
    }

    nonisolated private static let attributes = [NSMetadataItemPathKey, NSMetadataItemDisplayNameKey, NSMetadataItemContentTypeKey,
                                                  NSMetadataItemFSContentChangeDateKey, NSMetadataItemFSSizeKey, "kMDItemLastUsedDate"]

    func search(_ text: String) {
        pending?.cancel()
        let t = text.trimmingCharacters(in: .whitespaces)
        guard Prefs.shared.fileSearch, t.count >= 2, Calculator.evaluate(t) == nil else {
            stop()
            if !hits.isEmpty { hits = [] }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.run(t) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func stop() {
        generation += 1
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let q = query {
            nonisolated(unsafe) let old = q
            Self.queue.addOperation { old.stop() }
        }
        query = nil
    }

    private func run(_ text: String) {
        stop()
        let gen = generation
        let escaped = text
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(fromMetadataQueryString:
            "kMDItemDisplayName == \"*\(escaped)*\"cd && kMDItemContentType != \"com.apple.application-bundle\" && kMDItemContentType != \"com.apple.systempreference.prefpane\"")
        q.searchScopes = Self.scopes
        q.valueListAttributes = Self.attributes
        q.notificationBatchingInterval = 0.15
        q.operationQueue = Self.queue
        nonisolated(unsafe) let liveQuery = q
        let lower = text.lowercased()
        let nc = NotificationCenter.default
        // One early look while gathering (so results appear quickly), then the final one.
        nonisolated(unsafe) var lookedEarly = false
        observers.append(nc.addObserver(forName: .NSMetadataQueryGatheringProgress, object: q, queue: Self.queue) { _ in
            guard !lookedEarly else { return }
            lookedEarly = true
            Self.collect(liveQuery, lower: lower, generation: gen, final: false)
        })
        observers.append(nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: Self.queue) { _ in
            Self.collect(liveQuery, lower: lower, generation: gen, final: true)
        })
        query = q
        Self.queue.addOperation { liveQuery.start() }
        // Broad queries can gather for a while; settle for what we have after a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            Self.queue.addOperation { Self.collect(liveQuery, lower: lower, generation: gen, final: true) }
        }
    }

    /// Runs on the Spotlight queue. Ranks every result from the batched attributes (name, dates — no round trips),
    /// then asks for paths only for the best few: the path isn't part of a value list.
    nonisolated private static func collect(_ q: NSMetadataQuery, lower: String, generation gen: Int, final: Bool) {
        guard q.isStarted, !q.isStopped else { return }
        q.disableUpdates()
        var ranked: [(index: Int, name: String, score: Double)] = []
        let count = min(q.resultCount, 600)
        for i in 0..<count {
            let name = q.value(ofAttribute: NSMetadataItemDisplayNameKey, forResultAt: i) as? String ?? ""
            let used = q.value(ofAttribute: "kMDItemLastUsedDate", forResultAt: i) as? Date
            let modified = q.value(ofAttribute: NSMetadataItemFSContentChangeDateKey, forResultAt: i) as? Date
            var score = (used ?? modified ?? .distantPast).timeIntervalSince1970 / 1e6
            if name.lowercased().hasPrefix(lower) { score += 10_000 }
            ranked.append((i, name, score))
        }
        ranked.sort { $0.score > $1.score }
        var found: [FileHit] = []
        for r in ranked.prefix(200) {
            guard let item = q.result(at: r.index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if path.contains("/Library/") || path.contains("/.") || path.contains(".app/") || path.contains("/node_modules/") { continue }
            found.append(FileHit(id: path, name: r.name.isEmpty ? (path as NSString).lastPathComponent : r.name,
                                 contentType: q.value(ofAttribute: NSMetadataItemContentTypeKey, forResultAt: r.index) as? String,
                                 modified: q.value(ofAttribute: NSMetadataItemFSContentChangeDateKey, forResultAt: r.index) as? Date,
                                 size: (q.value(ofAttribute: NSMetadataItemFSSizeKey, forResultAt: r.index) as? NSNumber)?.int64Value))
            if found.count == 6 { break }
        }
        q.enableUpdates()
        if final { q.stop() }
        let top = found

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let me = FileSearch.shared
                guard gen == me.generation else { return }
                if top != me.hits { me.hits = top }
            }
        }
    }
}
