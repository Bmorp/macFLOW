import AppKit
import SwiftUI

/// Watches ~/Downloads for in-flight browser downloads and newly finished files.
/// Opt-in: reading Downloads asks for the user's permission once.
@MainActor
final class DownloadsWatcher: ObservableObject {
    static let shared = DownloadsWatcher()

    struct Active: Equatable {
        var name: String
        var progress: Double?      // nil = indeterminate
        var bytes: Int64
    }

    @Published private(set) var active: Active?
    @Published private(set) var lastFinished: URL?

    var onFinished: ((URL) -> Void)?

    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var known = Set<String>()
    private var progressTimer: Timer?
    /// A partial file that stops changing (an abandoned `.crdownload`) is re-checked every few seconds,
    /// not listed out of ~/Downloads every 0.8 s forever.
    private var lastActive: Active?
    private var unchangedScans = 0
    private var running = false

    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload", "filepart"]

    func setEnabled(_ on: Bool) { on ? start() : stop() }

    private func start() {
        guard !running else { return }
        fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        running = true
        known = Set(listing().map(\.lastPathComponent))
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
        scan()
    }

    private func stop() {
        guard running else { return }
        running = false
        source?.cancel()
        source = nil
        progressTimer?.invalidate()
        progressTimer = nil
        active = nil
    }

    private func listing() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder,
                                                      includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    private func scan() {
        let items = listing()
        let names = Set(items.map(\.lastPathComponent))
        let partials = items.filter { Self.partialExtensions.contains($0.pathExtension.lowercased()) }

        // Newly completed: a real file that wasn't there before and was created just now.
        let fresh = items.filter {
            !known.contains($0.lastPathComponent) && !Self.partialExtensions.contains($0.pathExtension.lowercased())
        }
        for url in fresh {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) < 120 {
                lastFinished = url
                onFinished?(url)
            }
        }
        known = names

        if let p = partials.first {
            updateActive(p)
            unchangedScans = active == lastActive ? unchangedScans + 1 : 0
            lastActive = active
            let interval: TimeInterval = unchangedScans > 40 ? 5 : 0.8
            if progressTimer?.timeInterval != interval {
                progressTimer?.invalidate()
                let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scan() }
                }
                t.tolerance = interval * 0.2
                RunLoop.main.add(t, forMode: .common)
                progressTimer = t
            }
        } else {
            lastActive = nil
            unchangedScans = 0
            if active != nil { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { active = nil } }
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func updateActive(_ url: URL) {
        var name = url.deletingPathExtension().lastPathComponent
        var progress: Double?
        var bytes: Int64 = 0
        if url.pathExtension.lowercased() == "download" {
            // Safari keeps real progress in the bundle's Info.plist.
            let plist = url.appendingPathComponent("Info.plist")
            if let dict = NSDictionary(contentsOf: plist) as? [String: Any] {
                let done = (dict["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.doubleValue ?? 0
                let total = (dict["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.doubleValue ?? 0
                if total > 0 { progress = min(1, done / total) }
                bytes = Int64(done)
                if let path = dict["DownloadEntryPath"] as? String { name = (path as NSString).lastPathComponent }
            }
        } else {
            bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let next = Active(name: name, progress: progress, bytes: bytes)
        if next != active {
            if active == nil {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { active = next }
            } else {
                active = next
            }
        }
    }

    #if DEBUG
    func debugSet(_ a: Active?) { active = a }
    #endif

    nonisolated static func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
