import AppKit
import ApplicationServices
import Combine

/// How much the Brain may observe. You choose; it never goes further.
enum BrainLevel: Int, CaseIterable, Identifiable {
    case off, essentials, context, everything
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .essentials: "Essentials"
        case .context: "Context"
        case .everything: "Everything"
        }
    }
    var detail: String {
        switch self {
        case .off: "Flow observes nothing and makes no suggestions."
        case .essentials: "Which apps you use and for how long, what you play, your calendar, Claude sessions, calls, and the kind of thing you copy. No permissions needed."
        case .context: "Also window, document and web page titles — so Flow knows the project and the task, not just the app. Needs Accessibility."
        case .everything: "Also the words on screen in the window you’re using, read on this Mac and condensed. Needs Screen Recording."
        }
    }
}

/// What you're doing right now, kept live from the senses, condensed into work sessions as you go.
@MainActor
final class WorkContext: ObservableObject {
    static let shared = WorkContext()

    enum Change {
        case modeChanged(from: WorkMode, to: WorkMode, after: TimeInterval)
        case returned(after: TimeInterval)
        case episodeEnded(BrainStore.Episode)
        case appOpened(bundle: String)
        case clipboard(kind: String)
    }

    @Published private(set) var appName = ""
    @Published private(set) var bundle = ""
    @Published private(set) var title = ""
    @Published private(set) var mode: WorkMode = .other
    @Published private(set) var project: String?
    /// When the current mode began (brief detours don't reset it).
    @Published private(set) var modeSince = Date()
    @Published private(set) var isIdle = false
    /// Copied text that looks like an error — held in memory only, for a few minutes.
    private(set) var recentError: (text: String, at: Date)?

    var onChange: ((Change) -> Void)?

    private let store = BrainStore.shared
    private var appSince = Date()
    private var appSwitches: [Date] = []
    private var pendingMode: (mode: WorkMode, since: Date)?
    private var idleSince: Date?
    private var windowTimer: Timer?
    private var idleTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    // The work session being condensed.
    private var episodeStart = Date()
    private var episodeMode: WorkMode = .other
    private var episodeProject: String?
    /// Seconds per app bundle in the current session, and the names people know them by.
    private var episodeApps: [String: TimeInterval] = [:]
    private(set) var appNames: [String: String] = [:]

    var level: BrainLevel { BrainLevel(rawValue: Prefs.shared.brainLevel) ?? .essentials }
    var switchesLast15Minutes: Int { appSwitches.filter { $0.timeIntervalSinceNow > -900 }.count }
    var modeDuration: TimeInterval { Date().timeIntervalSince(modeSince) }

    private func observing() -> Bool {
        guard level != .off else { return false }
        if let until = Prefs.shared.brainPausedUntil, until > Date() { return false }
        return true
    }

    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app) }
        }
        let idle = Timer(timeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkIdle() } }
        idle.tolerance = 5
        RunLoop.main.add(idle, forMode: .common)
        idleTimer = idle
        let window = Timer(timeInterval: 4, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.readWindow() } }
        window.tolerance = 1
        RunLoop.main.add(window, forMode: .common)
        windowTimer = window

        NowPlayingModel.shared.$trackChangeTick.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.trackChanged() }
            .store(in: &cancellables)
        ClipboardHistory.shared.$items.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] items in self?.copied(items.first) }
            .store(in: &cancellables)
        activated(NSWorkspace.shared.frontmostApplication)
    }

    // MARK: Apps

    private func activated(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let now = Date()
        closeAppSegment(now)
        appName = app.localizedName ?? ""
        bundle = app.bundleIdentifier ?? ""
        title = ""
        appSince = now
        appSwitches.append(now)
        appSwitches.removeAll { $0.timeIntervalSinceNow < -900 }
        if observing() { onChange?(.appOpened(bundle: bundle)) }
        reclassify()
    }

    private func closeAppSegment(_ now: Date) {
        guard !bundle.isEmpty, observing(), !Prefs.shared.brainExcluded.contains(bundle) else { return }
        let duration = now.timeIntervalSince(appSince)
        guard duration >= 2, !Understanding.isPrivate(bundle: bundle, title: title) else { return }
        store.record(.init(ts: appSince, kind: "app", app: appName, bundle: bundle, title: level == .essentials ? "" : title,
                           detail: project ?? "", duration: duration))
        episodeApps[bundle, default: 0] += duration
        appNames[bundle] = appName
    }

    // MARK: Windows (Context and Everything)

    private var readingWindow = false

    /// Accessibility asks the other app over IPC, and a busy app can stall it — so it runs off the main thread.
    private func readWindow() {
        guard observing(), level.rawValue >= BrainLevel.context.rawValue, !readingWindow, InputControl.isTrusted,
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundle,
              !Prefs.shared.brainExcluded.contains(bundle) else { return }
        readingWindow = true
        let pid = app.processIdentifier
        let forBundle = bundle
        DispatchQueue.global(qos: .utility).async {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.5)
            var window: CFTypeRef?
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window {
                AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value)
            }
            let raw = value as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = WorkContext.shared
                    me.readingWindow = false
                    guard let raw, me.bundle == forBundle else { return }
                    me.windowTitleRead(CustomActivity.clean(raw))
                }
            }
        }
    }

    private func windowTitleRead(_ newTitle: String) {
        guard newTitle != title else { return }
        if Understanding.isPrivate(bundle: bundle, title: newTitle) { title = ""; return }
        // Close the old title's stretch so time is attributed to the right document.
        closeAppSegment(Date())
        appSince = Date()
        title = newTitle
        store.record(.init(ts: Date(), kind: "window", app: appName, bundle: bundle, title: newTitle))
        reclassify()
    }

    // MARK: Understanding

    private var knownProjects: [String] {
        var names = ClaudeSessions.shared.sessions.map(\.folder).filter { $0 != "Untitled session" }
        names += store.facts().filter { $0.key.hasPrefix("project:") }.map { String($0.key.dropFirst(8)) }
        return Array(Set(names))
    }

    private var overrides: [String: WorkMode] {
        var out: [String: WorkMode] = [:]
        for f in store.facts() where f.key.hasPrefix("mode:") {
            out[String(f.key.dropFirst(5))] = WorkMode(rawValue: f.value)
        }
        return out
    }

    private func reclassify() {
        var next = Understanding.mode(bundle: bundle, title: title, overrides: overrides)
        if ActivityCenter.shared.call != nil { next = .meeting }
        let proj = Understanding.project(bundle: bundle, title: title, known: knownProjects)
            ?? (next == .coding ? ClaudeSessions.shared.featured?.folder : nil)
        if let proj, proj != "Untitled session", proj != project { project = proj }
        settle(next)
    }

    /// A mode becomes current after 90 s, so a quick look at Messages doesn't break a coding streak.
    private var settledOnce = false

    private func settle(_ next: WorkMode) {
        let now = Date()
        // The first reading after launch (or coming back) is taken as-is.
        if !settledOnce || mode == .other && modeDuration < 5 {
            settledOnce = true
            mode = next
            modeSince = now
            episodeMode = next
            pendingMode = nil
            return
        }
        if next == mode { pendingMode = nil; return }
        if let p = pendingMode, p.mode == next {
            guard now.timeIntervalSince(p.since) >= 90 else { return }
            let previous = mode, lasted = now.timeIntervalSince(modeSince)
            mode = next
            modeSince = p.since
            pendingMode = nil
            if observing() { onChange?(.modeChanged(from: previous, to: next, after: lasted)) }
            rollEpisode(at: p.since)
        } else {
            pendingMode = (next, now)
            // Re-check once the debounce has passed, even if nothing else happens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 91) { [weak self] in self?.reclassify() }
        }
    }

    // MARK: Work sessions

    private func rollEpisode(at boundary: Date) {
        let length = boundary.timeIntervalSince(episodeStart)
        if length >= 180, episodeMode != .idle, observing() {
            let apps = episodeApps.sorted { $0.value > $1.value }.prefix(4).map(\.key)
            let names = apps.map { appNames[$0] ?? $0 }
            let where_ = episodeProject.map { " on \($0)" } ?? ""
            let ep = BrainStore.Episode(start: episodeStart, end: boundary, mode: episodeMode.rawValue, project: episodeProject ?? "",
                                        apps: apps, summary: "\(episodeMode.label)\(where_) in \(names.joined(separator: ", "))")
            store.save(ep)
            if let p = episodeProject { store.setFact("project:\(p)", "seen", source: "learned", confidence: 0.6) }
            onChange?(.episodeEnded(ep))
        }
        episodeStart = boundary
        episodeMode = mode
        episodeProject = project
        episodeApps = [:]
    }

    // MARK: Away and back

    private func checkIdle() {
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        if idle >= 300, !isIdle {
            isIdle = true
            idleSince = Date().addingTimeInterval(-idle)
            closeAppSegment(idleSince!)
            mode = .idle
            rollEpisode(at: idleSince!)
        } else if idle < 30, isIdle, let since = idleSince {
            isIdle = false
            let away = Date().timeIntervalSince(since)
            if observing() {
                store.record(.init(ts: since, kind: "idle", duration: away))
                onChange?(.returned(after: away))
            }
            appSince = Date()
            modeSince = Date()
            mode = .other
            reclassify()
        }
    }

    // MARK: Music and clipboard

    private var lastTrack: (key: String, at: Date)?

    private func trackChanged() {
        guard observing() else { return }
        let np = NowPlayingModel.shared
        guard np.hasTrack else { return }
        let key = "\(np.title)|\(np.artist)"
        var detail = "\(np.album)|\(np.source?.name ?? "")|\(mode.rawValue)"
        if let last = lastTrack, Date().timeIntervalSince(last.at) < 30 {
            store.record(.init(ts: last.at, kind: "skip", app: "", title: last.key))
            detail += "|after-skip"
        }
        lastTrack = (key, Date())
        store.record(.init(ts: Date(), kind: "media", app: np.source?.name ?? "", title: np.title, detail: "\(np.artist)|\(detail)"))
    }

    private func copied(_ item: ClipItem?) {
        guard observing(), let item else { return }
        let kind: String
        let text = item.text
        if Self.looksLikeError(text) {
            kind = "error"
            recentError = (String(text.prefix(4000)), Date())
        } else {
            kind = "\(item.flavor)"
        }
        // The kind only — never what you copied.
        store.record(.init(ts: Date(), kind: "clipboard", app: appName, bundle: bundle, detail: kind))
        onChange?(.clipboard(kind: kind))
    }

    func consumeError() -> String? {
        guard let e = recentError, e.at.timeIntervalSinceNow > -300 else { return nil }
        recentError = nil
        return e.text
    }

    nonisolated static func looksLikeError(_ text: String) -> Bool {
        let t = text.lowercased()
        let signals = ["error:", "exception", "traceback", "fatal", "failed with", "undefined is not", "cannot find", "stack trace",
                       "segmentation fault", "panic:", "npm err", "errno", "uncaught", "warning:"]
        return text.count > 20 && signals.contains(where: t.contains)
    }

    #if DEBUG
    func debugSet(app: String, bundle b: String, title t: String, mode m: WorkMode, project p: String?, since: Date) {
        appName = app; bundle = b; title = t; mode = m; project = p; modeSince = since
    }
    #endif
}
