import AppKit
import SwiftUI
import Darwin

/// Your Claude sessions, live — read from the small status files Claude Code keeps for each running session
/// (`~/.claude/sessions/<pid>.json`: name, folder, status, when it changed). Conversations are never read.
@MainActor
final class ClaudeSessions: ObservableObject {
    static let shared = ClaudeSessions()

    enum State: Equatable, Sendable {
        case working
        case waiting
        case idle
    }

    struct Session: Identifiable, Equatable, Sendable {
        let id: String
        let pid: pid_t
        let name: String
        let folder: String
        let cwd: String
        let state: State
        /// When the current state began.
        let since: Date
        let viaDesktop: Bool
    }

    /// Waiting first, then working, then the most recently active.
    @Published private(set) var sessions: [Session] = []
    var working: [Session] { sessions.filter { $0.state == .working } }
    var waiting: [Session] { sessions.filter { $0.state == .waiting } }
    /// The session the island features: whoever needs you, else whoever's been working longest.
    var featured: Session? { waiting.first ?? working.min { $0.since < $1.since } }

    /// A session finished something that took a while.
    var onFinish: ((Session, TimeInterval) -> Void)?
    /// A session is waiting for you.
    var onNeedsYou: ((Session) -> Void)?

    nonisolated static let tint = Color(red: 0.85, green: 0.47, blue: 0.34)

    private let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions", isDirectory: true)
    private var timer: Timer?
    private var source: DispatchSourceFileSystemObject?
    private var previous: [String: (State, Date)] = [:]
    private var enabled = false

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            watchDirectory()
            reload()
        } else {
            timer?.invalidate()
            timer = nil
            source?.cancel()
            source = nil
            sessions = []
            previous = [:]
        }
    }

    /// New and removed sessions arrive as directory events; status changes are polled — briskly while
    /// something is working, lazily otherwise.
    private func watchDirectory() {
        let fd = Darwin.open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reload() } }
            s.setCancelHandler { Darwin.close(fd) }
            s.resume()
            source = s
        }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let busy = sessions.contains { $0.state != .idle }
        let t = Timer(timeInterval: busy ? 1.5 : 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
        t.tolerance = busy ? 0.3 : 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var reading = false

    func reload() {
        guard enabled, !reading else { return }
        reading = true
        let directory = self.directory
        DispatchQueue.global(qos: .utility).async {
            let found = Self.read(directory)
            DispatchQueue.main.async {
                let me = ClaudeSessions.shared
                me.reading = false
                me.apply(found)
                me.schedule()
            }
        }
    }

    nonisolated private static func read(_ directory: URL) -> [Session] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var found: [Session] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), data.count < 64_000,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let s = parse(json, fallbackID: url.deletingPathExtension().lastPathComponent),
                  kill(s.pid, 0) == 0 || errno == EPERM else { continue }
            found.append(s)
        }
        return found
    }

    private func apply(_ list: [Session]) {
        guard enabled else { return }
        var found = list
        found.sort { a, b in
            func rank(_ s: State) -> Int { s == .waiting ? 0 : s == .working ? 1 : 2 }
            return rank(a.state) != rank(b.state) ? rank(a.state) < rank(b.state) : a.since > b.since
        }
        noticeTransitions(found)
        if found != sessions {
            // Only a session arriving or leaving reshapes the island; a status change just updates in place.
            if found.map(\.id) != sessions.map(\.id) { withAnimation(Motion.morph) { sessions = found } } else { sessions = found }
        }
    }

    /// One status file → a session. Unknown statuses that mention waiting or approval count as "needs you".
    nonisolated static func parse(_ json: [String: Any], fallbackID: String) -> Session? {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value else { return nil }
        let id = json["sessionId"] as? String ?? fallbackID
        let cwd = json["cwd"] as? String ?? ""
        let status = (json["status"] as? String ?? "idle").lowercased()
        let state: State = ["busy", "working", "running", "thinking"].contains(status) ? .working
            : ["await", "wait", "approval", "input", "permission"].contains(where: { status.contains($0) }) ? .waiting
            : .idle
        let changedMs = (json["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? (json["updatedAt"] as? NSNumber)?.doubleValue ?? 0
        let name = (json["name"] as? String).map(CustomActivity.clean).flatMap { $0.isEmpty ? nil : $0 }
        return Session(id: id, pid: pid, name: name ?? URL(fileURLWithPath: cwd).lastPathComponent,
                       folder: folderName(cwd), cwd: cwd, state: state,
                       since: changedMs > 0 ? Date(timeIntervalSince1970: changedMs / 1000) : Date(),
                       viaDesktop: (json["entrypoint"] as? String)?.contains("desktop") ?? false)
    }

    private func noticeTransitions(_ list: [Session]) {
        for s in list {
            if let (old, since) = previous[s.id], old != s.state {
                if s.state == .waiting { onNeedsYou?(s) }
                if old == .working, s.state == .idle {
                    let took = s.since.timeIntervalSince(since)
                    if took >= 20 { onFinish?(s, took) }
                }
            }
            // Keep the start of a working stretch, not every refresh.
            if previous[s.id]?.0 != s.state { previous[s.id] = (s.state, s.since) }
        }
        let alive = Set(list.map(\.id))
        previous = previous.filter { alive.contains($0.key) }
    }

    /// The folder people recognise: the last component, or the project for an app-made workspace.
    nonisolated private static func folderName(_ cwd: String) -> String {
        let last = URL(fileURLWithPath: cwd).lastPathComponent
        return last.hasPrefix("scratch-") ? "Untitled session" : last
    }

    // MARK: Opening

    nonisolated static let desktopBundleID = "com.anthropic.claudefordesktop"

    /// Brings forward wherever the session lives: the Claude app, or the terminal or editor running it.
    func open(_ s: Session?) {
        if let s, !s.viaDesktop, let app = Self.owningApp(of: s.pid) {
            app.activate()
            return
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.desktopBundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.desktopBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Walks up the process tree to the app that owns a CLI session (Terminal, iTerm, VS Code…).
    private static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let parent = info.kp_eproc.e_ppid
            if parent <= 1 || parent == current { return nil }
            current = parent
        }
        return nil
    }

    #if DEBUG || ATOLL_PROBE
    func debugSet(_ list: [Session]) { enabled = true; sessions = list }
    #endif
}
