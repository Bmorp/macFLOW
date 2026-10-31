import AppKit
import SwiftUI
import CoreAudio

/// Things you can tell Atoll to do by typing them — "volume 40", "airpods", "play AP Dhillon", "night shift" —
/// plus your projects and Claude sessions by name. Each runs at once, right from search.
enum SmartCommand: Equatable {
    case volume(Double)
    case mute(Bool)
    case brightness(Double)
    case nightShift(Bool)
    case trueTone(Bool)
    case output(id: AudioDeviceID, name: String, symbol: String)
    case play, pause, next, previous
    case playArtist(String)
    case join(url: URL, title: String)
    case project(name: String, apps: [String], detail: String)
    case claude(id: String, name: String, detail: String)
    case plan
    case rewind
    case day
    /// "t review deck tomorrow 3pm 45m": a new task, as understood so far.
    case addTask(TaskDraft, typed: String)
    /// The Tasks place.
    case tasks
    /// An open task found by name.
    case openTask(id: UUID, title: String, detail: String)
    /// The Smart Workspace on a section: "servers", "devices", "system", "clipboard", "summarise my active work".
    case workspace(WorkspaceSection)
    /// The newest file in Downloads, of a kind if asked ("latest pdf").
    case latestDownload(url: URL, date: Date)
    /// "focus mode": a focus block, with notifications held.
    case focusMode
    /// "stop 3000": stop a local server, after a confirmation.
    case stopServer(pid: Int32, port: Int, process: String)

    /// What kind of command this is (the brief's command architecture): reading something, changing something on this
    /// Mac, or going through an integration. Anything that can lose work asks first.
    enum Category { case readOnly, localAction, integration }
    var category: Category {
        switch self {
        case .workspace, .latestDownload, .rewind, .day, .tasks, .openTask, .project, .claude: .readOnly
        case .join: .integration
        default: .localAction
        }
    }
    var asksFirst: Bool { if case .stopServer = self { return true }; return false }

    var id: String {
        switch self {
        case .volume(let v): "vol:\(Int(v * 100))"
        case .mute(let m): "mute:\(m)"
        case .brightness(let b): "bri:\(Int(b * 100))"
        case .nightShift(let on): "ns:\(on)"
        case .trueTone(let on): "tt:\(on)"
        case .output(let id, _, _): "out:\(id)"
        case .play: "play"
        case .pause: "pause"
        case .next: "next"
        case .previous: "prev"
        case .playArtist(let a): "artist:\(a)"
        case .join(let u, _): "join:\(u)"
        case .project(let n, _, _): "proj:\(n)"
        case .claude(let id, _, _): "claude:\(id)"
        case .plan: "plan"
        case .rewind: "rewind"
        case .day: "day"
        case .addTask(_, let typed): "task.add:\(typed)"
        case .tasks: "tasks"
        case .workspace(let w): "ws:\(w.rawValue)"
        case .latestDownload(let url, _): "latest:\(url.path)"
        case .focusMode: "focus"
        case .stopServer(_, let port, _): "stop:\(port)"
        case .openTask(let id, _, _): "task:\(id)"
        }
    }

    var title: String {
        switch self {
        case .volume(let v): "Set Volume to \(Int((v * 100).rounded()))%"
        case .mute(let m): m ? "Mute Sound" : "Unmute Sound"
        case .brightness(let b): "Set Brightness to \(Int((b * 100).rounded()))%"
        case .nightShift(let on): on ? "Turn On Night Shift" : "Turn Off Night Shift"
        case .trueTone(let on): on ? "Turn On True Tone" : "Turn Off True Tone"
        case .output(_, let name, _): "Play Sound on \(name)"
        case .play: "Play"
        case .pause: "Pause"
        case .next: "Next Track"
        case .previous: "Previous Track"
        case .playArtist(let a): "Play \(a)"
        case .join(_, let t): "Join \(t)"
        case .project(let n, _, _): "Open \(n)"
        case .claude(_, let n, _): n
        case .plan: "Plan Your Day"
        case .rewind: "Rewind Today"
        case .day: "See Your Day"
        case .addTask(let d, _): "New Task: \(d.title)"
        case .tasks: "Tasks"
        case .workspace(let w): w == .overview ? "Your Active Work" : w == .system ? "System Monitor" : w == .clipboard ? "Clipboard History" : w.title
        case .latestDownload(let url, _): url.lastPathComponent
        case .focusMode: "Start a Focus Block"
        case .stopServer(_, let port, let process): "Stop \(process) on :\(port)"
        case .openTask(_, let t, _): t
        }
    }

    @MainActor var subtitle: String? {
        switch self {
        case .volume, .brightness: nil
        case .mute: SystemVolume.shared.muted ? "Sound is muted" : AudioDevices.shared.currentOutput?.name
        case .nightShift, .trueTone: "Display"
        case .output: AudioDevices.shared.output == outputID ? "In use" : "Switch output"
        case .play, .pause, .next, .previous:
            NowPlayingModel.shared.hasTrack ? "\(NowPlayingModel.shared.title) · \(NowPlayingModel.shared.artist)" : nil
        case .playArtist: InsightModel.shared.insight.taste.topSource.map { "In \($0)" } ?? "Search in Music"
        case .join: "Video call"
        case .project(_, _, let d): d
        case .claude(_, _, let d): d
        case .plan:
            if let next = PlanStore.shared.plan.next, PlanStore.shared.plan.started {
                "Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))"
            } else {
                "Priorities and meetings, fitted into your day"
            }
        case .rewind: "Scrub back to any moment and reopen it"
        case .day: "Today, drawn — focus, meetings and music"
        case .addTask(let d, _): d.hasDetails ? TaskFormat.parts(of: d).joined(separator: " · ") : "Add it to your tasks"
        case .tasks: TaskCapture.summary
        case .workspace(let w):
            switch w {
            case .overview: "Activities, notifications and what's next"
            case .system: "CPU, memory, network and heat"
            case .devices: "Audio, AirPods and Bluetooth"
            case .clipboard: "Search what you copied"
            case .developer: "Repositories, servers, CI and reviews"
            case .intelligence: "Ask Flow"
            case .settings: "Mac Flow's settings"
            }
        case .latestDownload(_, let date): "Newest in Downloads · \(date.formatted(.relative(presentation: .named)))"
        case .focusMode: "25 minutes · only important notifications interrupt"
        case .stopServer: "Asks before stopping · like Ctrl-C in its terminal"
        case .openTask(_, _, let d): d
        }
    }

    private var outputID: AudioDeviceID? { if case .output(let id, _, _) = self { return id }; return nil }

    var symbol: String {
        switch self {
        case .volume(let v): v < 0.01 ? "speaker.slash.fill" : v < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        case .mute(let m): m ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightness: "sun.max.fill"
        case .nightShift: "moon.fill"
        case .trueTone: "circle.lefthalf.filled"
        case .output(_, _, let s): s
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .next: "forward.fill"
        case .previous: "backward.fill"
        case .playArtist: "music.note"
        case .join: "video.fill"
        case .project: "folder.fill"
        case .claude: "asterisk"
        case .plan: "sun.horizon.fill"
        case .rewind: "clock.arrow.circlepath"
        case .day: "circle.circle"
        case .addTask: "plus.circle"
        case .tasks: "checklist"
        case .openTask: "circle"
        case .workspace(let w): w.symbol
        case .latestDownload: "arrow.down.doc"
        case .focusMode: "timer"
        case .stopServer: "stop.circle"
        }
    }

    @MainActor var tint: Color {
        switch self {
        case .volume, .mute, .output: Color(red: 0.36, green: 0.62, blue: 1)
        case .brightness, .trueTone: Color(red: 1, green: 0.8, blue: 0.25)
        case .nightShift: DS.Palette.orange
        case .play, .pause, .next, .previous, .playArtist: NowPlayingModel.shared.accent
        case .join: DS.Palette.green
        case .project: DS.Palette.indigo
        case .claude: ClaudeSessions.tint
        case .plan: PlanView.morning
        case .rewind, .day: BrainStyle.tint
        case .addTask, .tasks, .openTask: TaskStyle.tint
        case .workspace: FlowTone.accent
        case .latestDownload: DS.Palette.blue
        case .focusMode: DS.Palette.orange
        case .stopServer: DS.Palette.red
        }
    }

    /// A level to preview inline (volume, brightness).
    var level: Double? {
        switch self {
        case .volume(let v), .brightness(let v): v
        default: nil
        }
    }

    var actionHint: String {
        switch self {
        case .project, .claude, .plan, .rewind, .day, .tasks, .openTask, .workspace, .latestDownload: "Open"
        case .focusMode: "Start"
        case .stopServer: "Stop…"
        case .addTask: "Add"
        case .join: "Join"
        case .output: "Switch"
        default: "Do It"
        }
    }

    /// Runs it. Returns a confirmation to show, or nil when the island should close.
    @MainActor func perform() -> String? {
        switch self {
        case .volume(let v):
            IslandManager.shared.noteOwnVolumeChange()
            SystemVolume.shared.set(v)
            return "Volume \(Int((v * 100).rounded()))%"
        case .mute(let m):
            SystemVolume.shared.setMuted(m)
            return m ? "Muted" : "Sound On"
        case .brightness(let b):
            DisplayControl.shared.setBrightness(b)
            return "Brightness \(Int((b * 100).rounded()))%"
        case .nightShift(let on):
            DisplayControl.shared.setNightShift(on)
            return on ? "Night Shift On" : "Night Shift Off"
        case .trueTone(let on):
            DisplayControl.shared.setTrueTone(on)
            return on ? "True Tone On" : "True Tone Off"
        case .output(let id, let name, _):
            if let d = AudioDevices.shared.outputs.first(where: { $0.id == id }) { AudioDevices.shared.useOutput(d) }
            return "Playing on \(name)"
        case .play, .pause:
            NowPlayingModel.shared.playPause()
            return self == .play ? "Playing" : "Paused"
        case .next:
            NowPlayingModel.shared.next()
            return "Next Track"
        case .previous:
            NowPlayingModel.shared.previous()
            return "Previous Track"
        case .playArtist(let a):
            BrainEngine.shared.perform(.playArtist(a))
            return nil
        case .join(let url, _):
            BrainEngine.shared.perform(.joinMeeting(url))
            return nil
        case .project(let name, let apps, _):
            // Its room, if one's saved: the documents too, not just the apps.
            BrainEngine.shared.perform(RoomStore.shared.projectRoom(name).map { .resumeRoom($0.key) } ?? .openApps(apps))
            return nil
        case .claude(let id, _, _):
            ClaudeSessions.shared.open(ClaudeSessions.shared.sessions.first { $0.id == id })
            return nil
        case .plan:
            IslandManager.shared.openPlan()   // the island moves to the planner; SearchModel leaves it open
            return nil
        case .rewind:
            IslandManager.shared.primary?.model.open(.rewind)
            return nil
        case .day:
            IslandManager.shared.primary?.model.open(.day)
            return nil
        case .addTask(let d, let typed):
            guard let t = TaskStore.shared.add(d, typed: typed, source: .search) else { return nil }
            return TaskCapture.added(t)
        case .tasks:
            TasksModel.shared.show(nil)
            return nil
        case .openTask(let id, _, _):
            TasksModel.shared.show(id)
            return nil
        case .workspace(let w):
            IslandManager.shared.primary?.model.openWorkspace(w)
            return nil
        case .latestDownload(let url, _):
            NSWorkspace.shared.open(url)
            return nil
        case .focusMode:
            if !FocusTimer.shared.isActive { FocusTimer.shared.start(minutes: 25, label: "Focus") }
            IslandManager.shared.primary?.model.select(.activity(.timer))
            return nil
        case .stopServer(let pid, let port, let process):
            DevStatus.shared.stop(DevStatus.Server(pid: pid, process: process, port: port))
            return nil
        }
    }

    /// The newest file in Downloads (by when it arrived), optionally of one kind.
    static func newestDownload(kind: Set<String>?) -> (URL, Date)? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.addedToDirectoryDateKey, .creationDateKey],
                                                       options: [.skipsHiddenFiles]) else { return nil }
        return files.compactMap { url -> (URL, Date)? in
            let ext = url.pathExtension.lowercased()
            guard ext != "download", ext != "crdownload", kind.map({ $0.contains(ext) }) ?? true else { return nil }
            let v = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            return (url, v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast)
        }
        .max { $0.1 < $1.1 }
    }

    /// Commands that move the island to another of its places rather than closing it.
    var staysInIsland: Bool {
        switch self {
        case .plan, .rewind, .day, .tasks, .openTask, .workspace, .focusMode: true
        default: false
        }
    }

    // MARK: Understanding what you typed

    @MainActor static func parse(_ q: String) -> [SmartCommand] {
        let lower = q.lowercased().trimmingCharacters(in: .whitespaces)
        var out: [SmartCommand] = []
        func number(after words: [String]) -> Double? {
            for w in words where lower.hasPrefix(w) {
                let rest = lower.dropFirst(w.count).trimmingCharacters(in: CharacterSet(charactersIn: " %to"))
                if let n = Double(rest), (0...100).contains(n) { return n / 100 }
            }
            return nil
        }
        if let v = number(after: ["volume", "vol", "sound"]) { out.append(.volume(v)) }
        if let b = number(after: ["brightness", "bright", "screen"]), DisplayControl.shared.canSetBrightness { out.append(.brightness(b)) }
        if ["mute", "silence", "quiet"].contains(lower) { out.append(.mute(true)) }
        if ["unmute", "sound on"].contains(lower) { out.append(.mute(false)) }
        if lower.hasPrefix("night"), DisplayControl.shared.hasNightShift {
            out.append(.nightShift(lower.hasSuffix("off") ? false : lower.hasSuffix("on") ? true : !DisplayControl.shared.nightShift))
        }
        if lower.hasPrefix("true tone"), DisplayControl.shared.hasTrueTone {
            out.append(.trueTone(lower.hasSuffix("off") ? false : lower.hasSuffix("on") ? true : !DisplayControl.shared.trueTone))
        }
        // Outputs by name ("jbl", "airpods", "speakers").
        if lower.count >= 3 {
            for d in AudioDevices.shared.outputs {
                let n = d.name.lowercased()
                let alias = (lower == "speakers" && d.transport == kAudioDeviceTransportTypeBuiltIn)
                    || (lower == "headphones" && (d.transport == kAudioDeviceTransportTypeBluetooth || d.transport == kAudioDeviceTransportTypeBluetoothLE))
                if alias || n.hasPrefix(lower) || n.contains(" " + lower) || (lower.count >= 4 && n.contains(lower)) {
                    out.append(.output(id: d.id, name: d.name, symbol: d.symbol))
                }
            }
        }
        // Playback.
        let np = NowPlayingModel.shared
        switch lower {
        case "play", "resume": out.append(.play)
        case "pause", "stop": out.append(.pause)
        case "next", "skip", "next song", "next track": out.append(.next)
        case "previous", "prev", "back", "previous song": out.append(.previous)
        default:
            if lower.hasPrefix("play "), lower.count > 6 {
                out.append(.playArtist(String(q.trimmingCharacters(in: .whitespaces).dropFirst(5))))
            }
        }
        if (lower == "music" || lower == "song"), np.hasTrack { out.append(np.isPlaying ? .pause : .play) }
        // Meetings.
        if "join".hasPrefix(lower) || lower.hasPrefix("join") || lower == "meeting",
           let e = CalendarModel.shared.events.first(where: { !$0.isAllDay && $0.end > Date() && $0.start.timeIntervalSinceNow < 3600 && $0.meetingURL != nil }),
           let url = e.meetingURL {
            out.append(.join(url: url, title: e.title))
        }
        // Tasks: "t …", "task …", "todo …" add one; "tasks" opens them; a task's name finds it.
        if let c = TaskCapture.command(q) {
            out.insert(.addTask(c.draft, typed: c.typed), at: 0)
        } else {
            if TaskCapture.opensTasks(lower) { out.append(.tasks) }
            out += TaskCapture.find(lower).map { .openTask(id: $0.id, title: $0.title, detail: $0.detail) }
        }
        // The workspace, by what you'd call each part.
        let sections: [(WorkspaceSection, [String])] = [
            (.overview, ["workspace", "overview", "active work", "summarise my active work", "summarize my active work", "what am i working on", "notifications"]),
            (.system, ["system monitor", "system", "cpu", "memory", "ram", "network speed", "thermal", "activity monitor"]),
            (.devices, ["devices", "bluetooth", "connected devices", "show my connected devices"]),
            (.clipboard, ["clipboard", "clipboard history", "copied"]),
            (.developer, ["developer", "servers", "running servers", "show my running servers", "repos", "repositories", "git", "ci",
                          "deploys", "deployments", "pull requests", "prs", "reviews", "docker", "containers"]),
        ]
        for (section, words) in sections where lower.count >= 2 && words.contains(where: { $0 == lower || ($0.hasPrefix(lower) && lower.count >= 3) || (lower.count > 8 && lower.contains($0)) }) {
            out.append(.workspace(section))
        }
        // "latest pdf", "find my latest downloaded pdf", "last download".
        if ["latest", "last ", "newest", "recent download"].contains(where: lower.contains), ["download", "pdf", "file", "image", "zip", "dmg"].contains(where: lower.contains) {
            let kind: Set<String>? = lower.contains("pdf") ? ["pdf"] : lower.contains("image") ? ["png", "jpg", "jpeg", "heic", "gif", "webp"]
                : lower.contains("zip") ? ["zip"] : lower.contains("dmg") ? ["dmg"] : nil
            if let (url, date) = newestDownload(kind: kind) { out.append(.latestDownload(url: url, date: date)) }
        }
        if ["focus mode", "switch to focus mode", "deep work", "start focus"].contains(where: { $0.hasPrefix(lower) && lower.count >= 5 || lower.contains($0) }) {
            out.append(.focusMode)
        }
        // "stop 3000", "kill :8000": a local server, found by port.
        let words = lower.split(separator: " ")
        if words.count == 2, ["stop", "kill"].contains(String(words[0])), let port = Int(words[1].trimmingCharacters(in: CharacterSet(charactersIn: ":"))),
           let server = DevStatus.listeningServers().first(where: { $0.port == port }) {
            out.insert(.stopServer(pid: server.pid, port: port, process: server.process), at: 0)
        }
        // Planning the day.
        if lower.count >= 3, "plan my day".hasPrefix(lower) || lower.hasPrefix("plan") || ["my day", "today", "replan", "schedule"].contains(lower) {
            out.append(.plan)
        }
        // Rewind and your day.
        if lower.count >= 3, "rewind".hasPrefix(lower) || lower.hasPrefix("what was i") || lower == "earlier" || lower == "history" {
            out.append(.rewind)
        }
        if ["my day", "your day", "today", "day", "how was my day"].contains(lower) { out.append(.day) }
        // Projects and Claude sessions, by name.
        if lower.count >= 2 {
            for p in InsightModel.shared.insight.projects where p.name.lowercased().contains(lower) && !p.apps.isEmpty {
                let detail = p.today > 0 ? "\(BrainEngine.duration(p.today)) today · \(p.appNames.prefix(2).joined(separator: ", "))"
                                         : "Last worked on \(InsightModel.ago(p.lastSeen)) · \(p.appNames.prefix(2).joined(separator: ", "))"
                out.append(.project(name: p.name, apps: p.apps, detail: detail))
                if out.count > 6 { break }
            }
            for s in ClaudeSessions.shared.sessions where s.name.lowercased().contains(lower) || s.folder.lowercased().contains(lower) {
                let state = s.state == .waiting ? "Needs you" : s.state == .working ? "Working" : "Idle"
                out.append(.claude(id: s.id, name: s.name, detail: "Claude · \(state) · \(s.folder)"))
            }
        }
        return out
    }
}

/// A card in "For You": something the Brain thinks you'll want right now.
struct Suggestion: Identifiable, Equatable {
    enum Action: Equatable {
        case brain(BrainAction)
        case smart(SmartCommand)
        case ask(prompt: String, title: String)
        case openPlayer
    }
    let id: String
    let eyebrow: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var artwork: Bool = false
    let action: Action

    @MainActor static func forYou() -> [Suggestion] {
        var out: [Suggestion] = []
        let insight = InsightModel.shared
        for loop in insight.loops {
            switch loop.kind {
            case .claude:
                out.append(Suggestion(id: loop.id, eyebrow: "Claude needs you", title: loop.detail.components(separatedBy: " · ").first ?? loop.title,
                                      detail: "Waiting for your answer", symbol: "asterisk", tint: ClaudeSessions.tint, action: .brain(.openClaude)))
            case .meeting:
                out.append(Suggestion(id: loop.id, eyebrow: "Next meeting", title: loop.title, detail: loop.detail.capitalized,
                                      symbol: "video.fill", tint: DS.Palette.green, action: .brain(loop.action)))
            case .resume:
                out.append(Suggestion(id: loop.id, eyebrow: "Pick up", title: loop.title.replacingOccurrences(of: "Pick up ", with: ""),
                                      detail: loop.detail, symbol: "arrow.uturn.forward", tint: DS.Palette.indigo, action: .brain(loop.action)))
            }
        }
        let np = NowPlayingModel.shared
        if np.mode == .track {
            out.append(Suggestion(id: "np", eyebrow: np.isPlaying ? "Now playing" : "Paused", title: np.title, detail: np.artist,
                                  symbol: "music.note", tint: np.accent, artwork: true, action: .smart(np.isPlaying ? .pause : .play)))
        } else if let artist = insight.insight.taste.byMode[WorkContext.shared.mode]?.first ?? insight.insight.taste.topArtists.first?.name {
            let doing = WorkContext.shared.mode.label.lowercased()
            out.append(Suggestion(id: "taste", eyebrow: "For \(doing)", title: artist, detail: "What you usually play",
                                  symbol: "music.note", tint: DS.Palette.red, action: .smart(.playArtist(artist))))
        }
        if let s = ClaudeSessions.shared.sessions.first(where: { $0.state == .working }) {
            out.append(Suggestion(id: "cw:\(s.id)", eyebrow: "Claude is working", title: s.name, detail: s.folder,
                                  symbol: "asterisk", tint: ClaudeSessions.tint, action: .smart(.claude(id: s.id, name: s.name, detail: ""))))
        }
        if let clip = ClipboardHistory.shared.items.first, clip.kind == .text, clip.date.timeIntervalSinceNow > -15 * 60 {
            let text = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= 24 {
                let looksLikeError = WorkContext.looksLikeError(text)
                out.append(Suggestion(id: "clip:\(clip.id)", eyebrow: looksLikeError ? "Copied an error" : "Just copied",
                                      title: looksLikeError ? "Ask Claude to fix it" : "Explain it",
                                      detail: text.replacingOccurrences(of: "\n", with: " "),
                                      symbol: looksLikeError ? "ladybug.fill" : "text.quote", tint: ClaudeSessions.tint,
                                      action: .ask(prompt: (looksLikeError ? "What causes this error and how do I fix it? Be brief and concrete.\n\n" : "Explain this clearly and briefly:\n\n") + String(text.prefix(6000)),
                                                   title: looksLikeError ? "Fix the error you copied" : "Explain what you copied")))
            }
        }
        // De-duplicate (a Claude session can be both waiting and working), keep the three most useful.
        var seen = Set<String>()
        return Array(out.filter { seen.insert($0.title).inserted }.prefix(3))
    }
}
