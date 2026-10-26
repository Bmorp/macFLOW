import AppKit
import ApplicationServices
import Combine

/// A room: the Mac as it was for one piece of work — the apps on screen, the documents and pages open in them,
/// what was playing and the Claude session in front. Saved as a block ends (and every few minutes per project);
/// set again in one tap: those documents open, everything else hides, the music comes back, a quiet timer starts.
struct Room: Codable, Identifiable, Equatable {
    var id: String { key }
    /// What it's for: a plan block's title, or "project:<name>".
    var key: String
    var title: String
    /// Apps on screen, front-most first (bundle identifiers).
    var apps: [String] = []
    /// Per app, the documents (file URLs) and pages (web URLs) open in its windows.
    var documents: [String: [String]] = [:]
    var track: Track?
    var claude: String?
    var saved = Date()

    struct Track: Codable, Equatable {
        var title: String
        var artist: String
        var source: String
        /// Spotify's own identifier, when that's what was playing — it plays the exact song.
        var uri: String?
    }

    static func key(for title: String) -> String {
        title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    var documentCount: Int { documents.values.reduce(0) { $0 + $1.count } }

    /// "Xcode, Safari · 3 documents · M83" — what setting it will bring back.
    var summary: String {
        var parts: [String] = []
        let names = apps.prefix(3).compactMap(Desk.appName)
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        if documentCount > 0 { parts.append(documentCount == 1 ? "1 document" : "\(documentCount) documents") }
        if let t = track { parts.append(t.artist.isEmpty ? t.title : t.artist) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The desk (what's on screen, through Accessibility)

/// Reads which apps have windows on screen and what's open in them. Accessibility asks each app over IPC, so it all
/// runs off the main thread with short timeouts. Never reads pixels or window contents — only the document each
/// window says it's showing, and only at the Context level and above, skipping private windows and apps you excluded.
enum Desk {
    struct Snapshot: Sendable {
        var apps: [String] = []
        var documents: [String: [String]] = [:]
    }

    static func appName(_ bundle: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Apps with a normal window on screen, front-most first.
    nonisolated static func visibleApps(excluding: Set<String>) -> [(pid: pid_t, bundle: String)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var seen = Set<pid_t>(), out: [(pid_t, String)] = []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, !seen.contains(pid),
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bundle = app.bundleIdentifier, !excluding.contains(bundle) else { continue }
            seen.insert(pid)
            out.append((pid, bundle))
        }
        return out
    }

    /// The documents and pages open in an app's windows (front window first).
    nonisolated static func documents(pid: pid_t, bundle: String) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        var out: [String] = []
        for w in windows.prefix(6) {
            var title: CFTypeRef?, doc: CFTypeRef?, minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
            if Understanding.isPrivate(bundle: bundle, title: title as? String ?? "") { continue }
            if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimized) == .success, (minimized as? Bool) == true { continue }
            guard AXUIElementCopyAttributeValue(w, kAXDocumentAttribute as CFString, &doc) == .success,
                  let s = doc as? String, let url = URL(string: s), ["file", "http", "https"].contains(url.scheme ?? "") else { continue }
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// The whole desk. `withDocuments` needs Accessibility.
    nonisolated static func snapshot(excluding: Set<String>, withDocuments: Bool) -> Snapshot {
        var snap = Snapshot()
        for (pid, bundle) in visibleApps(excluding: excluding).prefix(8) {
            snap.apps.append(bundle)
            if withDocuments {
                let docs = documents(pid: pid, bundle: bundle)
                if !docs.isEmpty { snap.documents[bundle] = docs }
            }
        }
        return snap
    }
}

// MARK: - Rooms

@MainActor
final class RoomStore: ObservableObject {
    static let shared = RoomStore()

    @Published private(set) var rooms: [String: Room] = [:]
    /// The room being worked in (set by `setRoom`), until its timer ends.
    @Published private(set) var active: String?
    private static let file = "rooms.json"
    private let queue = DispatchQueue(label: "atoll.rooms", qos: .utility)

    init() {
        rooms = Storage.load([String: Room].self, from: Self.file) ?? [:]
    }

    private var level: BrainLevel { BrainLevel(rawValue: Prefs.shared.brainLevel) ?? .essentials }

    /// Whether rooms can be saved at all (Flow observing), and with documents (Context, Accessibility).
    var canCapture: Bool { level != .off && !(Prefs.shared.brainPausedUntil.map { $0 > Date() } ?? false) }
    var withDocuments: Bool { level.rawValue >= BrainLevel.context.rawValue && InputControl.isTrusted }

    /// The best room for a piece of work: its own, else its project's (by name in the title).
    func room(for title: String) -> Room? {
        if let r = rooms[Room.key(for: title)] { return r }
        let lower = title.lowercased()
        if let p = InsightModel.shared.insight.projects.first(where: { lower.contains($0.name.lowercased()) }) {
            return rooms["project:" + Room.key(for: p.name)]
        }
        return nil
    }

    func projectRoom(_ name: String) -> Room? { rooms["project:" + Room.key(for: name)] }

    /// Saves the desk as it is now under `key`.
    func capture(key: String, title: String, completion: ((Room) -> Void)? = nil) {
        guard canCapture else { return }
        let excluded = Set(Prefs.shared.brainExcluded).union([Bundle.main.bundleIdentifier ?? ""])
        let docs = withDocuments
        let np = NowPlayingModel.shared
        let track: Room.Track? = np.mode == .track && np.isPlaying && !np.title.isEmpty
            ? Room.Track(title: np.title, artist: np.artist, source: np.source?.rawValue ?? "", uri: nil) : nil
        let claude = ClaudeSessions.shared.featured.flatMap { Date().timeIntervalSince($0.since) < 3600 || $0.state != .idle ? $0.cwd : nil }
        queue.async {
            let snap = Desk.snapshot(excluding: excluded, withDocuments: docs)
            var uri: String?
            if track?.source == MediaSource.spotify.rawValue { uri = Script.run("tell application id \"com.spotify.client\" to id of current track") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !snap.apps.isEmpty else { return }
                    var t = track
                    t?.uri = uri
                    let room = Room(key: key, title: title, apps: snap.apps, documents: snap.documents, track: t, claude: claude)
                    let me = RoomStore.shared
                    me.rooms[key] = room
                    me.trim()
                    Storage.save(me.rooms, to: Self.file)
                    completion?(room)
                }
            }
        }
    }

    /// Keeps the 60 most recent rooms.
    private func trim() {
        guard rooms.count > 60 else { return }
        for old in rooms.values.sorted(by: { $0.saved < $1.saved }).prefix(rooms.count - 60) { rooms[old.key] = nil }
    }

    func forget(_ key: String) {
        rooms[key] = nil
        Storage.save(rooms, to: Self.file)
    }

    // MARK: Setting a room

    /// "Set the room" for a piece of work: its documents open, everything else hides, its music plays, Focus turns on
    /// (through your Shortcut) and a quiet timer runs for the block. With no room saved yet, it starts the timer and
    /// music, and saves the room when the block ends — so next time it's all there.
    func setRoom(title: String, minutes: Int) {
        let room = room(for: title)
        if let room { restore(room, hideOthers: Prefs.shared.roomHidesOthers) }
        if room?.track == nil, !NowPlayingModel.shared.isPlaying, let artist = musicForWork(title) {
            BrainEngine.shared.perform(.playArtist(artist))
        }
        FocusShortcuts.run(Prefs.shared.focusShortcutOn)
        active = Room.key(for: title)
        FocusTimer.shared.start(minutes: minutes, label: title)
    }

    /// Back where it was: documents in their apps, the rest of the room's apps, the song, the Claude session.
    func restore(_ room: Room, hideOthers: Bool) {
        let ws = NSWorkspace.shared
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        for bundle in room.apps.reversed() {   // front-most last, so it ends up in front
            guard let appURL = ws.urlForApplication(withBundleIdentifier: bundle) else { continue }
            let urls = (room.documents[bundle] ?? []).compactMap(URL.init(string:))
                .filter { !$0.isFileURL || FileManager.default.fileExists(atPath: $0.path) }
            if urls.isEmpty {
                ws.openApplication(at: appURL, configuration: config)
            } else {
                ws.open(urls, withApplicationAt: appURL, configuration: config)
            }
        }
        if let front = room.apps.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSRunningApplication.runningApplications(withBundleIdentifier: front).first?.activate()
            }
        }
        if hideOthers {
            let keep = Set(room.apps).union([Bundle.main.bundleIdentifier ?? ""])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                    guard let b = app.bundleIdentifier, !keep.contains(b), !app.isHidden else { continue }
                    app.hide()
                }
            }
        }
        if let t = room.track, !NowPlayingModel.shared.isPlaying { play(t) }
        if let cwd = room.claude, let s = ClaudeSessions.shared.sessions.first(where: { $0.cwd == cwd }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { ClaudeSessions.shared.open(s) }
        }
    }

    private func play(_ t: Room.Track) {
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        if t.source == MediaSource.spotify.rawValue, let uri = t.uri {
            let script = "tell application id \"com.spotify.client\" to play track \"\(q(uri))\""
            queue.async { _ = Script.run(script) }
        } else if t.source == MediaSource.music.rawValue {
            let script = """
            tell application id "com.apple.Music"
                set found to (every track of playlist 1 whose name is "\(q(t.title))" and artist is "\(q(t.artist))")
                if found is not {} then play item 1 of found
            end tell
            """
            queue.async { _ = Script.run(script) }
        } else {
            BrainEngine.shared.perform(.playArtist(t.artist))
        }
    }

    /// Your usual artist for this kind of work, if Flow has learned one.
    private func musicForWork(_ title: String) -> String? {
        let insight = InsightModel.shared.insight
        let lower = title.lowercased()
        let mode = insight.projects.first(where: { lower.contains($0.name.lowercased()) })?.mode
            ?? (["write", "post", "draft", "doc", "essay"].contains { lower.contains($0) } ? .writing
                : ["code", "fix", "build", "review", "pr", "bug"].contains { lower.contains($0) } ? .coding : nil)
        guard let mode else { return nil }
        return insight.taste.byMode[mode]?.first
    }

    /// A block's timer ended: save the room as you left it, and let Focus go.
    func blockEnded(_ label: String) {
        FocusShortcuts.run(Prefs.shared.focusShortcutOff)
        let key = Room.key(for: label)
        defer { if active == key { active = nil } }
        guard active == key || PlanStore.shared.plan.items.contains(where: { $0.kind == .focus && Room.key(for: $0.title) == key }) else { return }
        capture(key: key, title: label)
    }
}

// MARK: - Moments

/// Writes a moment every five minutes while you're at the Mac, and whenever the app or project changes —
/// the record Rewind scrubs through. Also keeps each project's room fresh, so "pick up where I left off" works
/// even without a plan.
@MainActor
final class MomentRecorder {
    static let shared = MomentRecorder()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var last: BrainStore.Moment?
    private var pending: DispatchWorkItem?
    private var lastProjectRoom: [String: Date] = [:]

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 300, repeats: true) { _ in MainActor.assumeIsolated { MomentRecorder.shared.record(force: true) } }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let ctx = WorkContext.shared
        Publishers.Merge3(ctx.$bundle.map { _ in () }, ctx.$project.map { _ in () }, ctx.$title.map { _ in () })
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.soon() }
            .store(in: &cancellables)
    }

    /// Changes come in bursts (app, then title): settle first.
    private func soon() {
        pending?.cancel()
        let w = DispatchWorkItem { MomentRecorder.shared.record(force: false) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    private func record(force: Bool) {
        let ctx = WorkContext.shared
        guard ctx.level != .off, !(Prefs.shared.brainPausedUntil.map { $0 > Date() } ?? false), !ctx.isIdle,
              !ctx.bundle.isEmpty, !Prefs.shared.brainExcluded.contains(ctx.bundle),
              !Understanding.isPrivate(bundle: ctx.bundle, title: ctx.title) else { return }
        let np = NowPlayingModel.shared
        var m = BrainStore.Moment(ts: Date(), mode: ctx.mode.rawValue, project: ctx.project ?? "", bundle: ctx.bundle, app: ctx.appName,
                                  title: ctx.level == .essentials ? "" : ctx.title,
                                  track: np.mode == .track && np.isPlaying ? "\(np.title) — \(np.artist)" : "",
                                  claude: ClaudeSessions.shared.featured.map { $0.folder } ?? "")
        if !force, let last, last.bundle == m.bundle, last.title == m.title, last.project == m.project { return }
        let withDocs = RoomStore.shared.withDocuments
        let bundle = ctx.bundle
        // Only the app the moment is about: if something else is in front (Mac Flow's own Settings, say), no document.
        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.bundleIdentifier == bundle ? front?.processIdentifier : nil
        DispatchQueue.global(qos: .utility).async {
            if withDocs, let pid { m.document = Desk.documents(pid: pid, bundle: bundle).first ?? "" }
            BrainStore.shared.record(m)
        }
        last = m
        // A project's room, refreshed at most every ten minutes while you work on it.
        if let p = ctx.project, !p.isEmpty, Date().timeIntervalSince(lastProjectRoom[p] ?? .distantPast) > 600 {
            lastProjectRoom[p] = Date()
            RoomStore.shared.capture(key: "project:" + Room.key(for: p), title: p)
        }
    }
}

// MARK: - Focus, through your Shortcut

/// macOS doesn't let apps turn Focus on. A Shortcut can: pick one in Settings › Flow › Rooms and Mac Flow runs it
/// when a room is set (and its partner when the block ends).
enum FocusShortcuts {
    static func run(_ name: String) {
        guard !name.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }

    /// Your shortcuts, by name (for the Settings pickers).
    static func list(_ completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var names: [String] = []
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
            }
            DispatchQueue.main.async { completion(names) }
        }
    }
}

/// A small AppleScript runner for background queues (the caller picks the queue).
enum Script {
    nonisolated static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }
}
