#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: renders every presentation offscreen to PNGs for design review.
/// Demo data only — never writes user stores, starts the camera or sends Apple Events.
@MainActor
enum SnapshotHarness {
    static func run(outDir: String) {
        Storage.readOnly = true
        RenderMode.snapshot = true
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let screen = NSScreen.screens.first(where: \.hasNotch) ?? NSScreen.main!
        let geo = NotchGeometry.detect(for: screen)
        seed()

        let art = ProcessInfo.processInfo.environment["ATOLL_ART"].flatMap { NSImage(contentsOfFile: $0) } ?? demoArtwork()
        let safari = AudioApp(id: "com.apple.Safari", name: "Safari", url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"))
        let meeting = CalendarModel.Event(id: "m1", title: "Design Review", start: Date().addingTimeInterval(4 * 60 + 20),
                                          end: Date().addingTimeInterval(34 * 60), isAllDay: false, color: DS.Palette.indigo,
                                          location: nil, meetingURL: URL(string: "https://zoom.us/j/123"))

        let zoom = AudioApp(id: "com.apple.FaceTime", name: "FaceTime", url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FaceTime"))
        let zoomCall = ActivityCenter.Call(app: zoom, since: Date().addingTimeInterval(-754), camera: true)
        let build = CustomActivity.Item(title: "Building Atoll", detail: "Compiling 214 of 880 files", symbol: "hammer.fill",
                                        tint: DS.Palette.indigo, progress: 0.24, state: .running, updated: Date())
        let claudeSessions = [
            ClaudeSessions.Session(id: "a", pid: 1, name: "Rebuild the notch island", folder: "Atoll", cwd: "/x/Atoll", state: .working,
                                   since: Date().addingTimeInterval(-192), viaDesktop: true),
            ClaudeSessions.Session(id: "b", pid: 2, name: "Survey analysis", folder: "workflowsurvey", cwd: "/x/w", state: .idle,
                                   since: Date().addingTimeInterval(-1500), viaDesktop: true),
            ClaudeSessions.Session(id: "c", pid: 3, name: "Taxi booking site", folder: "kerala-taxi-service", cwd: "/x/k", state: .idle,
                                   since: Date().addingTimeInterval(-7200), viaDesktop: true),
        ]
        let claudeWaiting = [ClaudeSessions.Session(id: "a", pid: 1, name: "Rebuild the notch island", folder: "Atoll", cwd: "/x/Atoll",
                                                    state: .waiting, since: Date(), viaDesktop: true)]
        func track() { NowPlayingModel.shared.debugInjectApp(nil); NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: 97, artwork: art) }
        func app() { NowPlayingModel.shared.debugInject(title: "", artist: "", duration: 0, elapsed: 0, artwork: nil, playing: false); NowPlayingModel.shared.debugInjectApp(safari) }
        func silence() { NowPlayingModel.shared.debugInjectApp(nil); NowPlayingModel.shared.debugInject(title: "", artist: "", duration: 0, elapsed: 0, artwork: nil, playing: false) }

        struct Case { let name: String; let live: Bool; let setup: (IslandModel) -> Void }
        let cases: [Case] = [
            Case(name: "01-compact-idle", live: false) { _ in silence(); ActivityCenter.shared.debugSet([]) },
            Case(name: "02-compact-music", live: false) { _ in track(); ActivityCenter.shared.debugSet([.nowPlaying]) },
            Case(name: "03-compact-split-timer-music", live: false) { _ in
                track(); FocusTimer.shared.start(minutes: 25, label: "Focus"); ActivityCenter.shared.debugSet([.timer, .nowPlaying]) },
            Case(name: "04-compact-meeting-download", live: false) { _ in
                FocusTimer.shared.stop()
                DownloadsWatcher.shared.debugSet(.init(name: "Xcode_27.xip", progress: 0.62, bytes: 2_100_000_000))
                ActivityCenter.shared.debugSet([.meeting, .download], meeting: meeting) },
            Case(name: "05-compact-shelf", live: false) { _ in ActivityCenter.shared.debugSet([.shelf]) },
            Case(name: "06-compact-call", live: false) { _ in ActivityCenter.shared.debugSet([.call], call: zoomCall) },
            Case(name: "08-compact-claude", live: false) { _ in ClaudeSessions.shared.debugSet(claudeSessions); ActivityCenter.shared.debugSet([.claude]) },
            Case(name: "09-compact-claude-waiting", live: false) { _ in ClaudeSessions.shared.debugSet(claudeWaiting); ActivityCenter.shared.debugSet([.claude]) },
            Case(name: "07-compact-build", live: false) { _ in CustomActivity.shared.debugSet(build); ActivityCenter.shared.debugSet([.custom]) },
            Case(name: "10-expanded-glance", live: false) { m in silence(); ActivityCenter.shared.debugSet([]); m.debugSetMode(.expanded(.glance)) },
            Case(name: "10b-home-music", live: false) { m in track(); ClaudeSessions.shared.debugSet(claudeSessions); ActivityCenter.shared.debugSet([.nowPlaying]); m.debugSetMode(.expanded(.glance)) },
            Case(name: "11-expanded-music", live: false) { m in track(); ActivityCenter.shared.debugSet([.nowPlaying]); m.debugSetMode(.expanded(.activity(.nowPlaying))) },
            Case(name: "12-expanded-music-app", live: false) { m in app(); ActivityCenter.shared.debugSet([.nowPlaying]); m.debugSetMode(.expanded(.activity(.nowPlaying))) },
            Case(name: "13-expanded-timer", live: false) { m in
                FocusTimer.shared.start(minutes: 25, label: "Focus"); ActivityCenter.shared.debugSet([.timer]); m.debugSetMode(.expanded(.activity(.timer))) },
            Case(name: "14-expanded-meeting", live: false) { m in
                FocusTimer.shared.stop(); ActivityCenter.shared.debugSet([.meeting], meeting: meeting); m.debugSetMode(.expanded(.activity(.meeting))) },
            Case(name: "15-expanded-download", live: false) { m in ActivityCenter.shared.debugSet([.download]); m.debugSetMode(.expanded(.activity(.download))) },
            Case(name: "16-expanded-shelf", live: true) { m in ActivityCenter.shared.debugSet([.shelf]); m.debugSetMode(.expanded(.activity(.shelf))) },
            Case(name: "17-expanded-awake", live: false) { m in KeepAwake.shared.debugSet(true); ActivityCenter.shared.debugSet([.awake]); m.debugSetMode(.expanded(.activity(.awake))) },
            Case(name: "18-expanded-call", live: false) { m in KeepAwake.shared.debugSet(false); ActivityCenter.shared.debugSet([.call], call: zoomCall); m.debugSetMode(.expanded(.activity(.call))) },
            Case(name: "08b-compact-claude-hour", live: false) { _ in
                ClaudeSessions.shared.debugSet([ClaudeSessions.Session(id: "a", pid: 1, name: "Rebuild the notch island", folder: "Atoll", cwd: "/x/Atoll",
                                                                       state: .working, since: Date().addingTimeInterval(-4440), viaDesktop: true)])
                ActivityCenter.shared.debugSet([.claude]) },
            Case(name: "1c-controls", live: true) { m in silence(); ClaudeSessions.shared.debugSet(claudeSessions); ActivityCenter.shared.debugSet([.claude])
                AudioDevices.shared.start(); DisplayControl.shared.start(); m.debugSetMode(.expanded(.controls)) },
            Case(name: "2a-alert-brightness", live: false) { m in m.debugSetMode(.alert, alert: .brightness(0.62)) },
            Case(name: "1a-expanded-claude", live: false) { m in ClaudeSessions.shared.debugSet(claudeSessions); ActivityCenter.shared.debugSet([.claude]); m.debugSetMode(.expanded(.activity(.claude))) },
            Case(name: "1b-home-claude", live: false) { m in silence(); ClaudeSessions.shared.debugSet(claudeSessions); ActivityCenter.shared.debugSet([]); m.debugSetMode(.expanded(.glance)) },
            Case(name: "28-alert-claude-done", live: false) { m in m.debugSetMode(.alert, alert: .claudeFinished(id: "a", name: "Rebuild the notch island", duration: 734)) },
            Case(name: "29-alert-claude-needs", live: false) { m in m.debugSetMode(.alert, alert: .claudeNeedsYou(id: "a", name: "Rebuild the notch island", folder: "Atoll")) },
            Case(name: "2c-alert-update", live: false) { m in m.debugSetMode(.alert, alert: .update(version: "8.1.1")) },
            Case(name: "19-expanded-build", live: false) { m in CustomActivity.shared.debugSet(build); ActivityCenter.shared.debugSet([.custom]); m.debugSetMode(.expanded(.activity(.custom))) },
            Case(name: "20-alert-volume", live: false) { m in KeepAwake.shared.debugSet(false); ActivityCenter.shared.debugSet([]); m.debugSetMode(.alert, alert: .volume(level: 0.62, muted: false)) },
            Case(name: "21-alert-charging", live: false) { m in m.debugSetMode(.alert, alert: .charging(76)) },
            Case(name: "22-alert-track", live: false) { m in track(); m.debugSetMode(.alert, alert: .trackChanged) },
            Case(name: "23-alert-airpods", live: false) { m in
                m.debugSetMode(.alert, alert: .device(.init(name: "AirPods Pro", symbol: "airpodspro", single: nil, left: 92, right: 88, caseLevel: 64, connected: true))) },
            Case(name: "24-alert-download", live: false) { m in m.debugSetMode(.alert, alert: .downloadFinished(URL(fileURLWithPath: "/System/Applications/Calculator.app"))) },
            Case(name: "25-alert-timer", live: false) { m in m.debugSetMode(.alert, alert: .timerFinished("Focus")) },
            Case(name: "26-alert-mic", live: false) { m in m.debugSetMode(.alert, alert: .privacy(camera: false, app: "Zoom")) },
            Case(name: "27-alert-tip", live: false) { m in
                m.debugSetMode(.alert, alert: .tip(symbol: "hand.point.up.left.fill", title: "Rest the pointer here",
                                                   detail: "Atoll opens to show what’s playing and what’s next.", step: 0, total: 3)) },
            Case(name: "30-search-empty", live: true) { m in silence(); ClaudeSessions.shared.debugSet([]); SearchModel.shared.reset(); SearchModel.shared.prepare(); m.debugSetMode(.search) },
            Case(name: "30b-search-foryou", live: true) { m in
                track(); ClaudeSessions.shared.debugSet(claudeWaiting + [claudeSessions[1]]); AudioDevices.shared.start(); DisplayControl.shared.start()
                SearchModel.shared.reset(); SearchModel.shared.prepare(); m.debugSetMode(.search) },
            Case(name: "30c-search-volume", live: true) { m in SearchModel.shared.query = "volume 40"; m.debugSetMode(.search) },
            Case(name: "30d-search-output", live: true) { m in SearchModel.shared.query = "jbl"; m.debugSetMode(.search) },
            Case(name: "30e-search-play", live: true) { m in SearchModel.shared.query = "play AP Dhillon"; m.debugSetMode(.search) },
            Case(name: "30f-search-file", live: true) { m in SearchModel.shared.query = "design"; m.debugSetMode(.search) },
            Case(name: "40-brain-welcome", live: true) { m in BrainAgent.shared.reset(); m.debugSetMode(.expanded(.brain)) },
            Case(name: "41-brain-conversation", live: true) { m in
                BrainAgent.shared.debugSet([
                    .init(role: .you, text: "Start a 25 minute focus and play AP Dhillon"),
                    .init(role: .action, text: "Playing AP Dhillon", symbol: "music.note"),
                    .init(role: .action, text: "Started a 25-minute Focus timer", symbol: "timer"),
                    .init(role: .atoll, text: "Your 25-minute focus has started, and AP Dhillon is playing. I’ll keep the notch quiet until it’s done."),
                    .init(role: .you, text: "What did I get done today?"),
                    .init(role: .atoll, text: "You spent 2h 10m coding — mostly on Atoll in Xcode and Terminal — plus 25 minutes in Claude on workflowsurvey. Claude is still waiting on you there."),
                ])
                m.debugSetMode(.expanded(.brain)) },
            Case(name: "31-search-apps", live: true) { m in SearchModel.shared.query = "not"; m.debugSetMode(.search) },
            Case(name: "32-search-convert", live: true) { m in SearchModel.shared.query = "26.2 mi in km"; m.debugSetMode(.search) },
            Case(name: "33-search-reminder", live: true) { m in SearchModel.shared.query = "remind me to call Sam at 5pm"; m.debugSetMode(.search) },
            Case(name: "34-search-clipboard", live: true) { m in SearchModel.shared.query = ""; SearchModel.shared.scope = .clipboard; m.debugSetMode(.search) },
            Case(name: "35-search-claude-answer", live: true) { m in
                SearchModel.shared.scope = .all
                ClaudeAsk.shared.debugSet(question: "Ask Claude “What does a notch app need to feel native?”",
                                          answer: "Three things:\n\n• **Respond instantly** — move with the pointer, never wait on work.\n• **Grow out of the hardware** — the shape should read as part of the bezel.\n• **Show only what’s live** — music, calls, timers, and your Claude sessions.", phase: .done)
                SearchModel.shared.debugShowAnswer()
                m.debugSetMode(.search) },
            Case(name: "36-search-claude-signin", live: true) { m in
                ClaudeAsk.shared.debugSet(question: "Ask Claude “Summarize what you copied”", answer: "", phase: .signedOut)
                SearchModel.shared.debugShowAnswer()
                m.debugSetMode(.search) },
            Case(name: "37-brain-suggestion", live: false) { m in
                m.debugSetMode(.alert, alert: .brainSuggestion(BrainSuggestion(kind: "meeting", symbol: "calendar.badge.clock", title: "Standup in 8 min",
                    detail: "You’ve been coding on Atoll for 52m — a timer to wrap up?", actionTitle: "Wrap-Up Timer", action: .none, confidence: 0.8))) },
            Case(name: "38-brain-question", live: false) { m in
                m.debugSetMode(.alert, alert: .brainQuestion(BrainQuestion(key: "pref:music.coding", text: "Do you like music while coding?",
                    detail: "I’ll suggest it at the right moment — or never.", options: [.init(label: "Yes", value: "yes"), .init(label: "Sometimes", value: "s"), .init(label: "No", value: "no")]))) },
            Case(name: "39-brain-answer", live: true) { m in
                BrainChat.shared.debugSet(question: "What did I work on today?", answer: "", phase: .thinking)
                SearchModel.shared.showBrainAnswer()
                m.debugSetMode(.search) },
            Case(name: "42-home-flow-question", live: true) { m in
                NowModel.shared.debugRelease()
                track(); ClaudeSessions.shared.debugSet([])
                FlowInbox.shared.debugSet([
                    .init(body: .suggestion(BrainSuggestion(kind: "break", symbol: "cup.and.saucer.fill", title: "Time for a short break",
                          detail: "90 minutes of coding", actionTitle: "Break", action: .none, confidence: 0.6)), added: Date().addingTimeInterval(-1500), expires: .distantFuture),
                    .init(body: .question(BrainQuestion(key: "pref:music.coding", text: "Do you like music while coding?",
                          detail: "I’ll suggest it at the right moment", options: [.init(label: "Yes", value: "yes"), .init(label: "Sometimes", value: "s"), .init(label: "No", value: "no")])),
                          added: Date().addingTimeInterval(-720), expires: .distantFuture),
                ])
                m.debugSetMode(.expanded(.glance)) },
            Case(name: "43-home-flow-suggestion", live: true) { m in
                FlowInbox.shared.debugSet([.init(body: .suggestion(BrainSuggestion(kind: "plan.focus", symbol: "scope", title: "Up next: Write the launch post",
                    detail: "10:40–11:40 · from your plan", actionTitle: "Start Focus", action: .startTimer(minutes: 60, label: "Write the launch post"), confidence: 0.9)),
                    added: Date().addingTimeInterval(-300), expires: .distantFuture)])
                m.debugSetMode(.expanded(.glance)) },
            Case(name: "44-compact-flow", live: false) { m in
                silence(); ActivityCenter.shared.debugSet([.flow]); m.debugSetMode(.compact) },
            Case(name: "45-plan-empty", live: true) { m in
                FlowInbox.shared.debugSet([]); ActivityCenter.shared.debugSet([])
                let cal = Calendar.current
                PlanClock.pinned = cal.date(bySettingHour: 8, minute: 42, second: 0, of: Date())
                let at = { (h: Int, mi: Int) in cal.date(bySettingHour: h, minute: mi, second: 0, of: Date())! }
                CalendarModel.shared.debugSet([
                    .init(id: "s1", title: "Standup", start: at(10, 0), end: at(10, 15), isAllDay: false, color: DS.Palette.green, location: nil, meetingURL: nil),
                    .init(id: "s2", title: "Design Review", start: at(14, 0), end: at(15, 0), isAllDay: false, color: DS.Palette.indigo, location: nil, meetingURL: nil),
                ])
                PlanStore.shared.debugSet(priorities: [Priority(), Priority(minutes: 60), Priority(minutes: 30)], meetings: [])
                m.debugSetMode(.expanded(.plan)) },
            Case(name: "46-plan-filled", live: true) { m in
                let cal = Calendar.current
                let at = { (h: Int, mi: Int) in cal.date(bySettingHour: h, minute: mi, second: 0, of: Date())! }
                PlanStore.shared.debugSet(priorities: [Priority(title: "Write the launch post", minutes: 90), Priority(title: "Review Priya’s PR", minutes: 45),
                                                       Priority(title: "Inbox zero", minutes: 30)],
                                          meetings: [PlanItem(title: "Call with Sam", kind: .meeting, start: at(16, 0), minutes: 30)])
                m.debugSetMode(.expanded(.plan)) },
            Case(name: "47-rewind", live: true) { m in
                PlanClock.pinned = nil
                let cal = Calendar.current
                let at = { (h: Int, mi: Int) in cal.date(bySettingHour: h, minute: mi, second: 0, of: Date())! }
                var ms: [BrainStore.Moment] = []
                let plan: [(Int, Int, String, String, String, String, String)] = [
                    (9, 0, "communicating", "", "Mail", "Inbox", ""), (9, 20, "coding", "Atoll", "Xcode", "IslandModel.swift", "Midnight City — M83"),
                    (10, 30, "meeting", "", "Zoom", "Standup", ""), (10, 50, "coding", "Atoll", "Xcode", "PlanView.swift", "Intro — The xx"),
                    (12, 30, "media", "", "Safari", "YouTube", ""), (13, 30, "writing", "Launch", "Pages", "Launch post.pages", "Weightless — Marconi Union"),
                    (15, 0, "meeting", "", "Zoom", "Design Review", ""), (16, 0, "coding", "Atoll", "Xcode", "Rooms.swift", "Midnight City — M83"),
                ]
                var id: Int64 = 1
                for (i, p) in plan.enumerated() {
                    let end = i + 1 < plan.count ? at(plan[i + 1].0, plan[i + 1].1) : at(17, 0)
                    var t = at(p.0, p.1)
                    while t < end {
                        ms.append(BrainStore.Moment(id: id, ts: t, mode: p.2, project: p.3, bundle: "com.apple.dt.Xcode", app: p.4, title: p.5,
                                                    document: p.5.hasSuffix(".swift") ? "file:///Users/me/Atoll/Sources/\(p.5)" : "", track: p.6,
                                                    claude: p.3 == "Atoll" ? "Atoll" : ""))
                        id += 1
                        t = t.addingTimeInterval(300)
                    }
                }
                RewindModel.shared.debugSet(ms, index: ms.firstIndex { cal.component(.hour, from: $0.ts) == 14 && cal.component(.minute, from: $0.ts) == 10 } ?? 0)
                m.debugSetMode(.expanded(.rewind)) },
            Case(name: "48-day", live: true) { m in
                let cal = Calendar.current
                let at = { (h: Int, mi: Int) in cal.date(bySettingHour: h, minute: mi, second: 0, of: Date())! }
                let spans: [(Int, Int, Int, Int, WorkMode)] = [(8, 40, 9, 20, .communicating), (9, 20, 10, 30, .coding), (10, 30, 10, 50, .meeting),
                    (10, 50, 12, 30, .coding), (12, 30, 13, 20, .media), (13, 30, 15, 0, .writing), (15, 0, 16, 0, .meeting), (16, 0, 18, 10, .coding)]
                var story = DayStory(date: Date(), start: at(8, 0), end: at(20, 0))
                story.spans = spans.enumerated().map { RewindModel.Span(id: $0.offset, start: at($0.element.0, $0.element.1), end: at($0.element.2, $0.element.3), mode: $0.element.4) }
                story.meetings = [DateInterval(start: at(10, 30), end: at(10, 50)), DateInterval(start: at(15, 0), end: at(16, 0))]
                story.songs = stride(from: 0, to: 34, by: 1).map { DayStory.Song(at: at(9, 25).addingTimeInterval(Double($0) * 820), artist: ["M83", "The xx", "Marconi Union", "Bonobo"][$0 % 4]) }
                story.finished = [at(11, 40), at(14, 15)]
                story.focus = 6.1 * 3600
                story.active = 8.9 * 3600
                story.modes = [.init(mode: .coding, seconds: 5.4 * 3600), .init(mode: .writing, seconds: 1.5 * 3600), .init(mode: .meeting, seconds: 1.3 * 3600)]
                story.topProject = "Atoll"
                story.priorities = (2, 3)
                story.headline = DayStory.headline(modes: story.modes, focus: story.focus, meetings: 2, songs: 34, project: "Atoll")
                DayArtModel.shared.debugSet(story)
                m.debugSetMode(.expanded(.day)) },
            Case(name: "49-voice", live: true) { m in
                BrainAgent.shared.reset()
                VoiceInput.shared.debugSet(state: .listening, transcript: "Move my 3 o’clock to tomorrow and play something calm", level: 0.6)
                m.debugSetMode(.expanded(.brain)) },
            Case(name: "49b-meeting-notes", live: true) { m in
                VoiceInput.shared.debugSet(state: .idle, transcript: "", level: 0)
                let zoom = AudioApp(id: "us.zoom.xos", name: "Zoom", url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FaceTime"))
                ActivityCenter.shared.debugSet([.call], call: ActivityCenter.Call(app: zoom, since: Date().addingTimeInterval(-754), camera: true))
                MeetingCompanion.shared.debugSet(state: .recording, lines: [
                    .init(speaker: .them, text: "So we ship pricing on Friday, and Sam owns the deck.", at: Date()),
                ], title: "Design Review")
                m.debugSetMode(.expanded(.activity(.call))) },
            Case(name: "49c-meeting-consent", live: true) { m in
                MeetingCompanion.shared.debugSet(state: .consenting, lines: [], title: "Design Review")
                m.debugSetMode(.expanded(.activity(.call))) },
            Case(name: "10c-now-plan", live: true) { m in
                track(); ClaudeSessions.shared.debugSet(claudeSessions); FlowInbox.shared.debugSet([])
                PlanClock.pinned = Calendar.current.date(bySettingHour: 8, minute: 40, second: 0, of: Date())
                PlanStore.shared.debugSet(priorities: [
                    Priority(title: "Send the deck to Sam", minutes: 45, source: "From Design Review", draft: "Send the deck to Sam"),
                    Priority(title: "Finish pricing page", minutes: 45, source: "Unfinished yesterday", draft: "Finish pricing page"),
                    Priority(title: "Continue Atoll", minutes: 90, source: "Your main project this week — 9h 20m", draft: "Continue Atoll")], meetings: [])
                NowModel.shared.debugSet(.plan)
                m.debugSetMode(.expanded(.glance)) },
            Case(name: "10d-now-focus", live: true) { m in
                PlanClock.pinned = nil
                FocusTimer.shared.start(minutes: 50, label: "Write the launch post")
                NowModel.shared.debugSet(.focus("Write the launch post"))
                m.debugSetMode(.expanded(.glance)) },
            Case(name: "10e-now-meeting", live: true) { m in
                FocusTimer.shared.stop()
                let e = CalendarModel.Event(id: "dr", title: "Design Review", start: Date().addingTimeInterval(6 * 60), end: Date().addingTimeInterval(36 * 60),
                                            isAllDay: false, color: DS.Palette.green, location: nil, meetingURL: URL(string: "https://zoom.us/j/1"))
                NowModel.shared.debugSet(.meeting(e))
                m.debugSetMode(.expanded(.glance)) },
            Case(name: "10f-now-next", live: true) { m in
                NowModel.shared.debugSet(.next(PlanItem(title: "Review Priya’s PR", kind: .focus, start: Date().addingTimeInterval(25 * 60), minutes: 45)))
                m.debugSetMode(.expanded(.glance)) },
            Case(name: "10g-now-evening", live: true) { m in
                NowModel.shared.debugSet(.evening)
                m.debugSetMode(.expanded(.glance)) },
            Case(name: "46b-plan-drafted", live: true) { m in
                NowModel.shared.debugSet(nil)
                m.debugSetMode(.expanded(.plan)) },
            Case(name: "51-sheet", live: true) { m in
                NowModel.shared.debugRelease(); track()
                var learned = Patterns(computed: Date(), days: 18)
                learned.focusByHour = [0, 0, 0, 0, 0, 0, 2, 8, 22, 46, 52, 38, 12, 9, 18, 24, 20, 10, 6, 4, 2, 0, 0, 0]
                learned.bestStart = 9; learned.bestEnd = 11; learned.focusLength = 52; learned.musicLift = 1.3
                learned.insights = learned.sentences()
                PatternsModel.shared.debugSet(learned)
                m.debugSetMode(.expanded(.sheet)) },
            Case(name: "51b-sheet-brief", live: true) { m in
                FlowSheet.startPage = .brief
                let h = { (x: Double) in Date().addingTimeInterval(-x * 3600) }
                NewsStore.shared.debugSet([
                    NewsItem(title: "Apple’s on-device models get faster in macOS 27", link: URL(string: "https://a.com/1")!, source: "Apple Newsroom", date: h(1), summary: "", relevance: 0.52),
                    NewsItem(title: "SwiftUI’s new rendering path, explained by the people who built it", link: URL(string: "https://a.com/2")!, source: "Hacker News", date: h(2), summary: "", relevance: 0.47),
                    NewsItem(title: "The best notch apps for your MacBook, ranked", link: URL(string: "https://a.com/3")!, source: "The Verge", date: h(3), summary: "", relevance: 0.2),
                    NewsItem(title: "A quieter way to plan your week", link: URL(string: "https://a.com/4")!, source: "The Verge", date: h(5), summary: "", relevance: 0.1),
                ])
                m.debugSetMode(.expanded(.sheet)) },
            Case(name: "51c-sheet-learn", live: true) { m in
                FlowSheet.startPage = .learn
                LearnStore.shared.debugSet([StudyCard(question: "Why does a parked SwiftUI view at 0 opacity cost a redraw when shown?",
                                                      answer: "Core Animation drops a fully transparent layer’s backing store, so it must render again on the first visible frame.",
                                                      source: "Notes on smooth animation", due: Date().addingTimeInterval(-60))])
                m.debugSetMode(.expanded(.sheet)) },
            Case(name: "10h-now-reading", live: true) { m in
                FlowSheet.startPage = .today
                NowModel.shared.debugSet(.reading("How SwiftUI decides what to redraw — a deep dive", browser: "Chrome"))
                m.debugSetMode(.expanded(.glance)) },
            Case(name: "52-lens-event", live: true) { m in
                let d = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!)!
                m.debugSetMode(.alert, alert: .lens(LensItem(source: "Copied text", snippet: "Lunch with Sam tomorrow at 1pm",
                                                              actions: [.addEvent(d, "Lunch with Sam"), .remind("Lunch with Sam tomorrow at 1pm")]))) },
            Case(name: "53-lens-file", live: true) { m in
                m.debugSetMode(.alert, alert: .lens(LensItem(source: "Launch brief.pdf", snippet: "Mac Flow 7.4 — the notch that thinks. Goals for launch week: press, creators, a film…",
                                                              actions: [.summarize("x"), .tasks("x")]))) },
            Case(name: "40-drop", live: false) { m in SearchModel.shared.reset(); m.debugSetMode(.drop) },
            Case(name: "41-mirror", live: false) { m in m.debugSetMode(.mirror) },
        ]

        // ATOLL_SNAP_ONLY=10b,1c renders just those (by name prefix) — for iterating on one screen.
        let only = ProcessInfo.processInfo.environment["ATOLL_SNAP_ONLY"]?.split(separator: ",").map(String.init)
        for c in cases where only.map({ $0.contains { c.name.hasPrefix($0) } }) ?? true {
            let model = IslandModel(geometry: geo, isPrimary: true)
            spin(0.05)
            c.setup(model)
            spin(c.name.hasPrefix("31") ? 1.3 : 0.2)
            if c.live { renderLive(model, name: c.name, outDir: outDir) } else { render(model, name: c.name, outDir: outDir) }
        }
        FocusTimer.shared.stop()
        PlanClock.pinned = nil
        renderWindow(WelcomeView(onContinue: {}), size: CGSize(width: 500, height: 600), name: "50-welcome", outDir: outDir)
        print("snapshots ok → \(outDir)")
    }

    private static func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    private static func seed() {
        ClipboardHistory.shared.debugReplace([
            ClipItem(text: "https://developer.apple.com/design/human-interface-guidelines/live-activities", date: Date().addingTimeInterval(-120), appBundleID: "com.apple.Safari"),
            ClipItem(text: "#5E5CE6", date: Date().addingTimeInterval(-700)),
            ClipItem(text: "Ship Atoll 3 on Friday", date: Date().addingTimeInterval(-1800), appBundleID: "com.apple.Notes"),
            ClipItem(text: "git commit -m \"Live Activities\"", date: Date().addingTimeInterval(-5000), appBundleID: "com.apple.Terminal"),
        ])
        ShelfModel.shared.clear()
        ShelfModel.shared.add(urls: ["/System/Applications/Calculator.app", "/System/Applications/Notes.app", "/private/etc/hosts"].map { URL(fileURLWithPath: $0) })
        Prefs.shared.weatherEnabled = true
        WeatherService.shared.debugSet(.init(temp: 27, code: 2, isDay: true, high: 31, low: 24, place: "Kochi", updated: Date(), hours: [], fahrenheit: false))
        spin(0.8)
    }

    private static func root(_ model: IslandModel) -> some View {
        let canvas = IslandModel.maxCanvas(for: model.geometry)
        return ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.30, green: 0.36, blue: 0.56), Color(red: 0.55, green: 0.42, blue: 0.56)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.white.opacity(0.2)).frame(height: model.notch.height)
            IslandView(model: model)
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, .dark)
    }

    private static func render(_ model: IslandModel, name: String, outDir: String) {
        let r = ImageRenderer(content: root(model))
        r.scale = 2
        r.colorMode = .nonLinear
        guard let cg = r.cgImage else { return }
        save(NSBitmapImageRep(cgImage: cg), name, outDir)
    }

    /// Scroll views and text fields only draw inside a real window.
    private static func renderLive(_ model: IslandModel, name: String, outDir: String) {
        let canvas = IslandModel.maxCanvas(for: model.geometry)
        let host = NSHostingView(rootView: root(model))
        host.frame = NSRect(origin: .zero, size: canvas)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        win.orderFrontRegardless()
        spin(0.9)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        save(rep, name, outDir)
        win.orderOut(nil)
    }

    private static func renderWindow<V: View>(_ view: V, size: CGSize, name: String, outDir: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.contentView = host
        win.appearance = NSAppearance(named: .aqua)
        win.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        win.orderFrontRegardless()
        spin(0.8)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        save(rep, name, outDir)
        win.orderOut(nil)
    }

    private static func save(_ rep: NSBitmapImageRep, _ name: String, _ outDir: String) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png"))
    }

    private static func demoArtwork() -> NSImage {
        let img = NSImage(size: NSSize(width: 200, height: 200))
        img.lockFocus()
        NSGradient(colors: [NSColor(red: 0.98, green: 0.45, blue: 0.3, alpha: 1), NSColor(red: 0.55, green: 0.2, blue: 0.85, alpha: 1)])?
            .draw(in: NSRect(x: 0, y: 0, width: 200, height: 200), angle: -45)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 60, y: 60, width: 80, height: 80)).fill()
        img.unlockFocus()
        return img
    }
}
#endif
