import AppKit
import SwiftUI

struct AppEntry: Identifiable, Hashable {
    let id: String          // bundle path
    let name: String
    let url: URL
    let bundleID: String?
    let searchName: String
    let initials: String

    init(url: URL, name: String, bundleID: String?) {
        self.id = url.path
        self.url = url
        self.name = name
        self.bundleID = bundleID
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        self.searchName = folded
        self.initials = folded
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." || $0 == "_" })
            .compactMap(\.first)
            .map(String.init)
            .joined()
    }
}

/// Indexes installed apps and ranks them for instant launching.
@MainActor
final class AppCatalog: ObservableObject {
    static let shared = AppCatalog()

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var pinned: [String] = []      // paths
    @Published private(set) var recents: [String] = []     // paths

    private var launchCounts: [String: Int] = [:]
    private var lastScan = Date.distantPast
    private let iconCache = NSCache<NSString, NSImage>()
    private let d = UserDefaults.standard

    private static let defaultPins = [
        "com.apple.finder", "com.apple.Safari", "com.apple.mail", "com.apple.MobileSMS",
        "com.apple.Notes", "com.apple.iCal", "com.apple.Music", "com.apple.Photos",
        "com.apple.systempreferences", "com.apple.Terminal", "com.apple.AppStore", "com.apple.reminders",
    ]

    init() {
        pinned = d.stringArray(forKey: "pinnedApps") ?? []
        recents = d.stringArray(forKey: "recentApps") ?? []
        launchCounts = d.dictionary(forKey: "launchCounts") as? [String: Int] ?? [:]
        if d.stringArray(forKey: "pinnedApps") == nil {
            pinned = Self.defaultPins.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
            d.set(pinned, forKey: "pinnedApps")
        }
        refresh()
    }

    func refreshIfStale() {
        if Date().timeIntervalSince(lastScan) > 90 { refresh() }
    }

    func refresh() {
        lastScan = Date()
        Task.detached(priority: .utility) {
            let found = AppCatalog.scan()
            await MainActor.run { AppCatalog.shared.apps = found }
        }
    }

    nonisolated static func scan() -> [AppEntry] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let roots = [
            "/Applications", "/Applications/Utilities", "/System/Applications",
            "/System/Applications/Utilities", "\(home)/Applications",
            "/System/Library/CoreServices/Applications",
        ]
        var seenBundles = Set<String>()
        var seenPaths = Set<String>()
        var result: [AppEntry] = []

        func consider(_ url: URL) {
            guard !seenPaths.contains(url.path) else { return }
            seenPaths.insert(url.path)
            let bundle = Bundle(url: url)
            let bid = bundle?.bundleIdentifier
            if let bid {
                guard !seenBundles.contains(bid) else { return }
                seenBundles.insert(bid)
            }
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            result.append(AppEntry(url: url, name: name, bundleID: bid))
        }

        consider(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root),
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    consider(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let nested = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    nested.filter { $0.pathExtension == "app" }.forEach(consider)
                }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Lookup

    func entry(forPath path: String) -> AppEntry? {
        if let e = apps.first(where: { $0.id == path }) { return e }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        return AppEntry(url: url, name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                        bundleID: Bundle(url: url)?.bundleIdentifier)
    }

    var pinnedEntries: [AppEntry] { pinned.compactMap(entry(forPath:)) }
    var recentEntries: [AppEntry] { recents.compactMap(entry(forPath:)) }

    func icon(for entry: AppEntry) -> NSImage { icon(forPath: entry.id) }

    func icon(forPath path: String) -> NSImage {
        if let cached = iconCache.object(forKey: path as NSString) { return cached }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 64, height: 64)
        iconCache.setObject(img, forKey: path as NSString)
        return img
    }

    // MARK: - Search

    func search(_ query: String, limit: Int = 8) -> [AppEntry] {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return apps.compactMap { e -> (AppEntry, Int)? in
            guard let s = Self.score(q, e) else { return nil }
            return (e, s + min((launchCounts[e.id] ?? 0) * 6, 120))
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    private static func score(_ q: String, _ e: AppEntry) -> Int? {
        let name = e.searchName
        if name == q { return 1000 }
        if name.hasPrefix(q) { return 900 - name.count }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
        if words.contains(where: { $0.hasPrefix(q) }) { return 720 - name.count }
        if q.count >= 2, e.initials.hasPrefix(q) { return 680 }
        if name.contains(q) { return 520 - name.count }
        // Loose letter matching only when it starts at a word, so "not" never finds "Screenshot".
        if q.count >= 2, words.contains(where: { $0.first == q.first }), isSubsequence(q, of: name) { return 240 - name.count }
        return nil
    }

    private static func isSubsequence(_ q: String, of s: String) -> Bool {
        var it = s.makeIterator()
        for c in q {
            var found = false
            while let n = it.next() { if n == c { found = true; break } }
            if !found { return false }
        }
        return true
    }

    // MARK: - Actions

    func launch(_ entry: AppEntry) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: entry.url, configuration: config)
        launchCounts[entry.id, default: 0] += 1
        recents.removeAll { $0 == entry.id }
        recents.insert(entry.id, at: 0)
        if recents.count > 18 { recents.removeLast(recents.count - 18) }
        d.set(launchCounts, forKey: "launchCounts")
        d.set(recents, forKey: "recentApps")
    }

    func isPinned(_ entry: AppEntry) -> Bool { pinned.contains(entry.id) }

    func togglePin(_ entry: AppEntry) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if let i = pinned.firstIndex(of: entry.id) { pinned.remove(at: i) } else { pinned.append(entry.id) }
        }
        d.set(pinned, forKey: "pinnedApps")
    }

    func pin(path: String) {
        guard !pinned.contains(path) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { pinned.append(path) }
        d.set(pinned, forKey: "pinnedApps")
    }

    func movePin(from: String, to: String) {
        guard let a = pinned.firstIndex(of: from), let b = pinned.firstIndex(of: to), a != b else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            pinned.move(fromOffsets: IndexSet(integer: a), toOffset: b > a ? b + 1 : b)
        }
        d.set(pinned, forKey: "pinnedApps")
    }

    func reveal(_ entry: AppEntry) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
}
