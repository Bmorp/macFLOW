import Foundation
import AppKit
import QuickLookThumbnailing

/// Files you've used most recently, from a live Spotlight query (metadata only, no file access).
@MainActor
final class RecentFiles: ObservableObject {
    static let shared = RecentFiles()

    @Published private(set) var items: [FileHit] = []

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    #if DEBUG
    func debugSet(_ list: [FileHit]) { items = list }
    #endif

    func start() {
        guard query == nil else { return }
        let q = NSMetadataQuery()
        let since = Date().addingTimeInterval(-7 * 86_400) as NSDate
        q.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@ AND kMDItemContentType != 'com.apple.application-bundle' AND kMDItemContentType != 'public.folder'", since)
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        q.notificationBatchingInterval = 1
        nonisolated(unsafe) let live = q
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect(live) }
            })
        }
        query = q
        q.start()
    }

    private func collect(_ q: NSMetadataQuery) {
        q.disableUpdates()
        defer { q.enableUpdates() }
        var out: [FileHit] = []
        for i in 0..<min(q.resultCount, 60) {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.contains("/Library/"), !path.contains("/."), !path.contains(".app/") else { continue }
            out.append(FileHit(id: path,
                               name: item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String ?? (path as NSString).lastPathComponent,
                               contentType: item.value(forAttribute: NSMetadataItemContentTypeKey) as? String,
                               modified: item.value(forAttribute: "kMDItemLastUsedDate") as? Date,
                               size: nil))
            if out.count == 8 { break }
        }
        if out != items {
            items = out
            out.forEach { loadThumbnail($0.id) }
        }
    }

    /// Quick Look thumbnails of the files themselves (photos, PDFs, documents), loaded off the main thread.
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    private func loadThumbnail(_ path: String) {
        guard thumbnails[path] == nil else { return }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 88, height: 88),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbnails[path] = image }
        }
    }
}
