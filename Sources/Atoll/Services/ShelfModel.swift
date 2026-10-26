import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing
import Quartz

struct ShelfItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var added: Date

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { FileManager.default.displayName(atPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// A holding tray for files: drop in, drag out anywhere, Quick Look, zip, share, AirDrop.
@MainActor
final class ShelfModel: ObservableObject {
    static let shared = ShelfModel()

    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published var selection: Set<UUID> = []
    @Published private(set) var busy = false

    private let fileName = "shelf.json"
    @Published private var sizes: [String: Int64] = [:]

    init() {
        items = (Storage.load([ShelfItem].self, from: fileName) ?? []).filter(\.exists)
        items.forEach { loadThumbnail($0); measure($0) }
    }

    /// The selected items, or everything when nothing is selected.
    var targets: [ShelfItem] {
        let sel = items.filter { selection.contains($0.id) }
        return sel.isEmpty ? items : sel
    }

    /// Size of the current targets (selection or everything); folders and apps are measured recursively.
    var sizeLabel: String {
        let list = targets
        let known = list.compactMap { sizes[$0.path] }
        guard !list.isEmpty else { return "" }
        let text = ByteCountFormatter.string(fromByteCount: known.reduce(0, +), countStyle: .file)
        return known.count < list.count ? "\(text)…" : text
    }

    private func measure(_ item: ShelfItem) {
        guard sizes[item.path] == nil else { return }
        let url = item.url
        Task.detached(priority: .utility) {
            let bytes = ShelfModel.diskSize(of: url)
            await MainActor.run { ShelfModel.shared.sizes[url.path] = bytes }
        }
    }

    nonisolated private static func diskSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard v.isDirectory == true else { return Int64(v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        var visited = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL, visited < 200_000 {
            visited += 1
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    // MARK: - Adding & removing

    @discardableResult
    func add(providers: [NSItemProvider], completion: (([URL]) -> Void)? = nil) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in fileProviders {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.add(urls: urls)
            completion?(urls)
        }
        return true
    }

    func add(urls: [URL]) {
        var added = false
        for url in urls where !items.contains(where: { $0.path == url.path }) {
            let item = ShelfItem(path: url.path, added: Date())
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { items.insert(item, at: 0) }
            loadThumbnail(item)
            measure(item)
            added = true
        }
        if added { save() }
    }

    func remove(_ item: ShelfItem) {
        selection.remove(item.id)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { items.removeAll { $0.id == item.id } }
        save()
    }

    func clear() {
        selection.removeAll()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { items.removeAll() }
        save()
    }

    // MARK: - Selection

    func tap(_ item: ShelfItem, extend: Bool) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            if extend {
                if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            } else {
                selection = selection == [item.id] ? [] : [item.id]
            }
        }

    }

    // MARK: - Actions

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ list: [ShelfItem]) { NSWorkspace.shared.activateFileViewerSelecting(list.map(\.url)) }

    func copyPath(_ item: ShelfItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }

    func copyFiles(_ list: [ShelfItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(list.map { $0.url as NSURL })
    }

    func airDrop(_ list: [ShelfItem]) { Self.airDrop(urls: list.map(\.url)) }

    static func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    static func airDrop(urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()
        if service.canPerform(withItems: urls) { service.perform(withItems: urls) }
    }

    func quickLook(_ list: [ShelfItem]) {
        QuickLookController.shared.show(list.map(\.url))
    }

    /// Native share sheet anchored at the pointer.
    func share(_ list: [ShelfItem], in view: NSView?) {
        guard let view, let window = view.window, !list.isEmpty else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let picker = NSSharingServicePicker(items: list.map(\.url))
        NSApp.activate()
        picker.show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    /// Zips the targets into an archive that lands back on the shelf (originals untouched).
    func zip(_ list: [ShelfItem], completion: @escaping (URL?) -> Void) {
        guard !list.isEmpty else { return completion(nil) }
        busy = true
        let dir = Storage.directory.appendingPathComponent("Archives", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = list.count == 1 ? list[0].url.deletingPathExtension().lastPathComponent : "Archive"
        let out = dir.appendingPathComponent("\(base) \(stamp.string(from: Date())).zip")
        let paths = list.map(\.path)
        Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = URL(fileURLWithPath: (paths[0] as NSString).deletingLastPathComponent)
            p.arguments = ["-r", "-q", "-y", out.path] + paths.map { ($0 as NSString).lastPathComponent }
            // Files from different folders: fall back to junked paths.
            let sameFolder = Set(paths.map { ($0 as NSString).deletingLastPathComponent }).count == 1
            if !sameFolder { p.arguments = ["-r", "-q", "-j", out.path] + paths }
            var ok = false
            if (try? p.run()) != nil {
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            }
            let succeeded = ok
            await MainActor.run {
                ShelfModel.shared.busy = false
                if succeeded { ShelfModel.shared.add(urls: [out]) }
                completion(succeeded ? out : nil)
            }
        }
    }

    func icon(for item: ShelfItem) -> NSImage {
        thumbnails[item.path] ?? IconCache.file(item.path)
    }

    private func loadThumbnail(_ item: ShelfItem) {
        let request = QLThumbnailGenerator.Request(fileAt: item.url,
                                                   size: CGSize(width: 112, height: 112),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbnails[item.path] = image }
        }
    }

    private func save() { Storage.save(items, to: fileName) }
}

/// Drives the system Quick Look panel. The notch panel forwards QL control to this object.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private(set) var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        NSApp.activate()
        IslandManager.shared.keyPanelForQuickLook()?.makeKey()
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
