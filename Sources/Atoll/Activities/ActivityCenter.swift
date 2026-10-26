import SwiftUI
import Combine

/// A task or event with a beginning and an end, shown in the island while it lasts.
enum ActivityKind: String, CaseIterable, Hashable {
    case call, claude, timer, custom, meeting, download, nowPlaying, shelf, awake
    /// Flow has something waiting for you (a missed question or suggestion): its star, until you've seen to it.
    case flow

    /// The glyph that stands for this activity in the island's tab switcher.
    @MainActor var tabSymbol: String {
        switch self {
        case .call: ActivityCenter.shared.call?.camera == true ? "video.fill" : "phone.fill"
        case .claude: "asterisk"
        case .timer: "timer"
        case .custom: CustomActivity.shared.current?.symbol ?? "hammer.fill"
        case .meeting: "calendar"
        case .download: "arrow.down"
        case .nowPlaying: "music.note"
        case .shelf: "tray.full.fill"
        case .awake: "cup.and.saucer.fill"
        case .flow: "sparkles"
        }
    }

    /// Higher wins the compact presentation; the runner-up takes the minimal bubble.
    var priority: Int {
        switch self {
        case .call: 95
        case .claude: 92
        case .timer: 90
        case .custom: 85
        case .meeting: 80
        case .download: 70
        case .nowPlaying: 60
        case .shelf: 30
        case .awake: 20
        case .flow: 10
        }
    }

    @MainActor var tint: Color {
        switch self {
        case .call: DS.Palette.green
        case .claude: ClaudeSessions.tint
        case .custom: CustomActivity.shared.current?.tint ?? DS.Palette.indigo
        case .timer: DS.Palette.orange
        case .meeting: DS.Palette.green
        case .download: DS.Palette.blue
        case .nowPlaying: NowPlayingModel.shared.mode == .app ? DS.Palette.cyan : NowPlayingModel.shared.accent
        case .shelf: DS.Palette.cyan
        case .awake: DS.Palette.yellow
        case .flow: BrainStyle.tint
        }
    }

    /// Leading/trailing element width in the compact presentation (kept symmetric for balance).
    @MainActor func compactWing(notchHeight h: CGFloat) -> CGFloat {
        switch self {
        case .nowPlaying: h + 10
        case .call: 58
        // "1h 14m" needs more room than "3m": grow only when the hours appear.
        case .claude:
            (ClaudeSessions.shared.featured.map { $0.state == .waiting || ($0.state == .working && Date().timeIntervalSince($0.since) >= 3600) } ?? false) ? 88 : 64
        case .custom: 54
        case .timer, .meeting: 54
        case .download: 50
        case .shelf: 46
        case .awake: 44
        case .flow: 40
        }
    }

    /// Height of the open presentation below the notch: one row, except the shelf's file tiles — and a call or
    /// meeting with the companion strip (time left, agenda, notes).
    @MainActor var rowHeight: CGFloat {
        switch self {
        case .shelf: 96
        case .nowPlaying: 78
        case .download: 74
        case .call, .meeting: DS.Size.rowHeight + (MeetingCompanion.shared.showsStrip ? MeetingCompanionStrip.height : 0)
        default: DS.Size.rowHeight
        }
    }
}

/// Composes the live activities from every service and ranks them.
@MainActor
final class ActivityCenter: ObservableObject {
    static let shared = ActivityCenter()

    @Published private(set) var live: [ActivityKind] = []
    @Published private(set) var meeting: CalendarModel.Event?
    /// The app you're on a call in, detected from microphone or camera use.
    @Published private(set) var call: Call?

    struct Call: Equatable {
        let app: AudioApp
        let since: Date
        let camera: Bool
    }

    /// Apps whose microphone use almost always means a call.
    private static let callApps: Set<String> = [
        "us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark",
        "com.skype.skype", "ru.keepcoder.Telegram", "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "com.google.Chrome.canary",
    ]
    private var callEndWork: DispatchWorkItem?

    var primary: ActivityKind? { live.first }
    var secondary: ActivityKind? { live.dropFirst().first }

    private var cancellables = Set<AnyCancellable>()
    private var clock: Timer?
    private var mediaLastLive = Date.distantPast

    init() {
        let triggers: [AnyPublisher<Void, Never>] = [
            FocusTimer.shared.$phase.map { _ in () }.eraseToAnyPublisher(),
            NowPlayingModel.shared.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            NowPlayingModel.shared.$title.map { _ in () }.eraseToAnyPublisher(),
            NowPlayingModel.shared.$otherApp.map { _ in () }.eraseToAnyPublisher(),
            DownloadsWatcher.shared.$active.map { _ in () }.eraseToAnyPublisher(),
            ShelfModel.shared.$items.map { _ in () }.eraseToAnyPublisher(),
            KeepAwake.shared.$isOn.map { _ in () }.eraseToAnyPublisher(),
            CalendarModel.shared.$events.map { _ in () }.eraseToAnyPublisher(),
            AudioActivity.shared.$micApps.map { _ in () }.eraseToAnyPublisher(),
            AudioActivity.shared.$cameraInUse.map { _ in () }.eraseToAnyPublisher(),
            CustomActivity.shared.$current.map { _ in () }.eraseToAnyPublisher(),
            ClaudeSessions.shared.$sessions.map { _ in () }.eraseToAnyPublisher(),
            Prefs.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            FlowInbox.shared.$items.map { $0.isEmpty }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.recompute() }
            .store(in: &cancellables)

        // Meetings enter their window with time, not with an event.
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t
        recompute()
    }

    #if DEBUG
    private var debugOverride = false
    func debugSet(_ list: [ActivityKind], meeting m: CalendarModel.Event? = nil, call c: Call? = nil) {
        debugOverride = true
        meeting = m
        call = c
        live = list
    }
    #endif

    func recompute() {
        #if DEBUG
        if debugOverride { return }
        #endif
        let prefs = Prefs.shared
        var list: [ActivityKind] = []

        updateCall()
        if prefs.calls, call != nil { list.append(.call) }
        if prefs.claude, ClaudeSessions.shared.featured != nil { list.append(.claude) }
        if FocusTimer.shared.isActive { list.append(.timer) }
        if CustomActivity.shared.current != nil { list.append(.custom) }

        let upcoming = prefs.meetings ? Self.currentMeeting() : nil
        if upcoming != meeting { meeting = upcoming }
        if upcoming != nil { list.append(.meeting) }

        if prefs.downloads, DownloadsWatcher.shared.active != nil { list.append(.download) }

        // Bridge the brief silence between tracks so the island doesn't flicker.
        let media = NowPlayingModel.shared
        if prefs.nowPlaying {
            if media.isLive {
                mediaLastLive = Date()
                list.append(.nowPlaying)
            } else if Date().timeIntervalSince(mediaLastLive) < 2 {
                list.append(.nowPlaying)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak self] in self?.recompute() }
            }
        }

        if prefs.shelfInNotch, !ShelfModel.shared.items.isEmpty { list.append(.shelf) }
        if KeepAwake.shared.isOn { list.append(.awake) }
        if prefs.brainSuggestions, !FlowInbox.shared.items.isEmpty { list.append(.flow) }

        list.sort { $0.priority > $1.priority }
        if list != live {
            withAnimation(Motion.split) { live = list }
        }
    }

    /// A call is an app on this list using the microphone, or any app using both microphone and camera.
    /// Ends a few seconds after the microphone goes quiet, so a brief mute or device switch doesn't flicker.
    private func updateCall() {
        let audio = AudioActivity.shared
        let candidate = audio.micApps.first { Self.callApps.contains($0.id) }
            ?? (audio.cameraInUse ? audio.micApps.first : nil)
        if let app = candidate {
            callEndWork?.cancel()
            callEndWork = nil
            if call?.app.id != app.id || call?.camera != audio.cameraInUse {
                call = Call(app: app, since: call?.app.id == app.id ? call!.since : Date(), camera: audio.cameraInUse)
            }
        } else if call != nil, callEndWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.callEndWork = nil
                if AudioActivity.shared.micApps.isEmpty { self.call = nil; self.recompute() }
            }
            callEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    /// A meeting starting within ten minutes, or in progress.
    static func currentMeeting(now: Date = Date()) -> CalendarModel.Event? {
        CalendarModel.shared.events.first { e in
            !e.isAllDay && e.end > now && e.start.timeIntervalSince(now) <= 600
        }
    }
}
