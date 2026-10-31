import SwiftUI

/// Something you can do to a live activity, from wherever it's shown: a chip, the workspace, Return on its page.
struct ActivityAction: Identifiable {
    let title: String
    var symbol: String? = nil
    let run: @MainActor () -> Void
    var id: String { title }
}

/// One live activity as every surface sees it: what it is, how far along, what state it's in, and what you can do.
/// Built fresh from the services that own each activity, so it can never disagree with them.
struct ActivitySnapshot: Identifiable {
    enum State { case running, paused, waiting, attention }

    let kind: ActivityKind
    let title: String
    let detail: String
    /// The short live value a chip shows: "18:42", "62%", "5 min".
    let value: String
    /// 0…1 when the activity has a measurable end.
    let progress: Double?
    let state: State
    let symbol: String
    let tint: Color
    let primary: ActivityAction?
    let secondary: [ActivityAction]

    var id: String { kind.rawValue }
}

extension ActivityKind {
    /// The activity as it is right now, or nil when it isn't live.
    @MainActor func snapshot(now: Date = Date()) -> ActivitySnapshot? {
        switch self {
        case .timer:
            let t = FocusTimer.shared
            guard t.isActive else { return nil }
            let paused = t.phase == .paused
            return .init(kind: self, title: t.label, detail: paused ? "Paused" : "Ends \(now.addingTimeInterval(t.remaining).formatted(date: .omitted, time: .shortened))",
                         value: t.clock, progress: t.progress, state: paused ? .paused : .running, symbol: "timer", tint: DS.Palette.orange,
                         primary: ActivityAction(title: paused ? "Resume" : "Pause", symbol: paused ? "play.fill" : "pause.fill") { FocusTimer.shared.togglePause() },
                         secondary: [ActivityAction(title: "Add 5 Minutes", symbol: "plus") { FocusTimer.shared.add(minutes: 5) },
                                     ActivityAction(title: "Stop", symbol: "xmark") { FocusTimer.shared.stop() }])

        case .download:
            guard let a = DownloadsWatcher.shared.active else { return nil }
            return .init(kind: self, title: a.name, detail: "Downloading", value: DownloadPresentation.percent(a), progress: a.progress,
                         state: .running, symbol: "arrow.down.circle", tint: DS.Palette.blue,
                         primary: ActivityAction(title: "Show Downloads", symbol: "folder") {
                             NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
                         }, secondary: [])

        case .meeting:
            guard let e = ActivityCenter.shared.meeting else { return nil }
            let mins = max(0, Int((e.start.timeIntervalSince(now) / 60).rounded(.up)))
            return .init(kind: self, title: e.title, detail: CalendarModel.timeRange(e), value: e.isNow ? "Now" : "\(mins) min",
                         progress: nil, state: e.isNow ? .attention : .waiting, symbol: "calendar", tint: DS.Palette.green,
                         primary: ActivityAction(title: e.meetingURL != nil ? "Join" : "Open", symbol: e.meetingURL != nil ? "video.fill" : "calendar") {
                             CalendarModel.shared.open(e)
                         }, secondary: [])

        case .call:
            guard let c = ActivityCenter.shared.call else { return nil }
            let s = Int(now.timeIntervalSince(c.since))
            return .init(kind: self, title: c.app.name, detail: c.camera ? "Camera on" : "Microphone on",
                         value: String(format: "%d:%02d", s / 60, s % 60), progress: nil, state: .running,
                         symbol: c.camera ? "video.fill" : "phone.fill", tint: DS.Palette.green,
                         primary: ActivityAction(title: "Show \(c.app.name)", symbol: "arrow.up.forward") {
                             if let url = c.app.url { NSWorkspace.shared.open(url) }
                         }, secondary: [])

        case .claude:
            guard let s = ClaudeSessions.shared.featured else { return nil }
            let waiting = s.state == .waiting
            let m = Int(now.timeIntervalSince(s.since) / 60)
            return .init(kind: self, title: s.name, detail: waiting ? "Needs you" : "Working in \(s.folder)",
                         value: waiting ? "Needs you" : m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m", progress: nil,
                         state: waiting ? .attention : .running, symbol: "asterisk", tint: ClaudeSessions.tint,
                         primary: ActivityAction(title: "Open", symbol: "arrow.up.forward") { ClaudeSessions.shared.open(s) }, secondary: [])

        case .custom:
            guard let item = CustomActivity.shared.current else { return nil }
            return .init(kind: self, title: item.title, detail: item.detail ?? "", value: item.progress.map { "\(Int($0 * 100))%" } ?? "",
                         progress: item.progress, state: .running, symbol: item.symbol, tint: item.tint, primary: nil, secondary: [])

        case .nowPlaying:
            let m = NowPlayingModel.shared
            guard m.isLive else { return nil }
            return .init(kind: self, title: m.mode == .app ? (m.otherApp?.name ?? "Audio") : m.title, detail: m.artist,
                         value: m.isPlaying ? "Playing" : "Paused", progress: nil, state: m.isPlaying ? .running : .paused,
                         symbol: "music.note", tint: m.accent,
                         primary: ActivityAction(title: m.isPlaying ? "Pause" : "Play", symbol: m.isPlaying ? "pause.fill" : "play.fill") { NowPlayingModel.shared.playPause() },
                         secondary: [ActivityAction(title: "Next", symbol: "forward.fill") { NowPlayingModel.shared.next() },
                                     ActivityAction(title: "Previous", symbol: "backward.fill") { NowPlayingModel.shared.previous() }])

        case .shelf:
            let items = ShelfModel.shared.items
            guard !items.isEmpty else { return nil }
            return .init(kind: self, title: items.count == 1 ? items[0].url.lastPathComponent : "\(items.count) files", detail: "On the shelf",
                         value: "", progress: nil, state: .waiting, symbol: "tray.full", tint: DS.Palette.cyan,
                         primary: ActivityAction(title: "Quick Look", symbol: "eye") { ShelfModel.shared.quickLook(ShelfModel.shared.targets) },
                         secondary: [ActivityAction(title: "Show in Finder", symbol: "folder") { ShelfModel.shared.reveal(ShelfModel.shared.items) }])

        case .awake:
            let k = KeepAwake.shared
            guard k.isOn else { return nil }
            let m = Int(now.timeIntervalSince(k.since ?? now) / 60)
            return .init(kind: self, title: "Keeping awake", detail: "The Mac won't sleep", value: m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m",
                         progress: nil, state: .running, symbol: "cup.and.saucer.fill", tint: DS.Palette.orange,
                         primary: ActivityAction(title: "Turn Off", symbol: "power") { KeepAwake.shared.disable() }, secondary: [])

        case .flow:
            let n = FlowInbox.shared.items.count
            guard n > 0 else { return nil }
            return .init(kind: self, title: n == 1 ? "Flow has something for you" : "Flow has \(n) things for you", detail: "Waiting on Home",
                         value: "\(n)", progress: nil, state: .attention, symbol: "sparkle", tint: BrainStyle.tint, primary: nil, secondary: [])
        }
    }
}
