#if DEBUG
import AppKit
import SwiftUI

/// v3 ("one day"): the newest surfaces as film frames — the morning plan, Now and its room, Lens, Claude, the meeting
/// and its notes, talking to Flow, the day ring drawing itself in, Rewind — and StandBy at 4K.
extension FilmHarness {
    nonisolated(unsafe) static var dayProgress: Double?

    static func v3(_ want: (String) -> Bool) {
        let fps30 = { (d: Double) in samples(d, fps: 30) }
        let cal = Calendar.current
        let at = { (h: Int, mi: Int) in cal.date(bySettingHour: h, minute: mi, second: 0, of: Date())! }
        func silence() {
            NowPlayingModel.shared.debugInjectApp(nil)
            NowPlayingModel.shared.debugInject(title: "", artist: "", duration: 0, elapsed: 0, artwork: nil, playing: false)
        }
        func focusTimer(_ remaining: Double) {
            if !FocusTimer.shared.isActive { FocusTimer.shared.start(minutes: 90, label: "Finish the blog post") }
            FocusTimer.shared.debugFreeze(remaining: remaining)
            setLive([.timer])
        }
        silence(); call = nil; setLive([])
        FlowInbox.shared.debugSet([])
        let idle = snap()

        // Morning: the plan Flow drafted overnight.
        if want("v3plan") {
            PlanClock.pinned = at(7, 58)
            CalendarModel.shared.debugSet([
                .init(id: "s1", title: "Standup", start: at(10, 0), end: at(10, 15), isAllDay: false, color: DS.Palette.green, location: nil, meetingURL: nil),
                .init(id: "s2", title: "Design Review", start: at(14, 0), end: at(15, 0), isAllDay: false, color: DS.Palette.indigo, location: nil, meetingURL: nil),
            ])
            PlanStore.shared.debugSet(priorities: [
                Priority(title: "Finish the blog post", minutes: 90, source: "Unfinished yesterday", draft: "Finish the blog post"),
                Priority(title: "Send the deck to Sam", minutes: 45, source: "From Design Review", draft: "Send the deck to Sam"),
                Priority(title: "Continue Mac Flow", minutes: 60, source: "Your main project this week — 9h 20m", draft: "Continue Mac Flow")],
                                      meetings: [])
            NowModel.shared.debugSet(nil)
            let plan = snap(.expanded(.plan))
            transition("p_open", idle, plan, spring: openSpring, times: fps30(0.7), live: true)
            hold("p_hold", plan, count: 1, live: true)
            transition("p_close", plan, idle, spring: closeSpring, times: fps30(0.5), live: true)
            PlanClock.pinned = nil
        }

        // Up next, with its room; one click sets it and the focus block starts.
        if want("v3next") {
            let title = "Finish the blog post"
            RoomStore.shared.debugSetRoom(Room(key: Room.key(for: title), title: title, apps: ["com.apple.iWork.Pages", "com.apple.Safari"]))
            NowModel.shared.debugSet(.next(PlanItem(title: title, kind: .focus, start: at(10, 25), minutes: 90)))
            let home = snap(.expanded(.glance))
            transition("n_open", idle, home, spring: openSpring, times: fps30(0.7), live: true)
            hold("n_hold", home, count: 1, live: true)
            focusTimer(5400)
            NowModel.shared.debugSet(.focus(title))
            let focus = snap()
            transition("n_close", home, focus, spring: closeSpring, times: fps30(0.5), live: true)
            hold("n_tick", focus, count: 8) { i in FocusTimer.shared.debugFreeze(remaining: 5400 - Double(i)) }
        }

        // Flow Lens: something copied with an obvious next step.
        if want("v3lens") {
            focusTimer(4210)
            let focus = snap()
            let d = cal.date(byAdding: .day, value: 1, to: at(13, 0))!
            let lens = snap(.alert, alert: .lens(LensItem(source: "Copied text", snippet: "Lunch with Sam tomorrow at 1pm",
                                                         actions: [.addEvent(d, "Lunch with Sam"), .remind("Lunch with Sam tomorrow at 1pm")])))
            transition("l_open", focus, lens, spring: openSpring, times: fps30(0.6), live: true)
            hold("l_hold", lens, count: 1, live: true)
            let text = "Lunch with Sam · \(d.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
            let added = snap(.alert, alert: .message(symbol: "calendar.badge.checkmark", text: text, tint: DS.Palette.green))
            transition("l_added", lens, added, spring: closeSpring, times: fps30(0.5), live: true)
            hold("l_addedHold", added, count: 1)
            transition("l_close", added, focus, spring: closeSpring, times: fps30(0.5))
        }

        // Claude finishes something long while you focus.
        if want("v3claude") {
            focusTimer(2890)
            let focus = snap()
            let done = snap(.alert, alert: .claudeFinished(id: "a", name: "Refactor the settings window", duration: 734))
            transition("c_open", focus, done, spring: openSpring, times: fps30(0.6))
            hold("c_hold", done, count: 1)
            transition("c_close", done, focus, spring: closeSpring, times: fps30(0.5))
        }

        // The meeting: Join, then notes taken on this Mac.
        if want("v3meet") {
            FocusTimer.shared.stop(); setLive([])
            let e = CalendarModel.Event(id: "dr", title: "Design Review", start: Date().addingTimeInterval(5 * 60), end: Date().addingTimeInterval(35 * 60),
                                        isAllDay: false, color: DS.Palette.green, location: nil,
                                        meetingURL: URL(string: "https://facetime.apple.com/join#v=1&p=demo"))
            NowModel.shared.debugSet(.meeting(e))
            let home = snap(.expanded(.glance))
            transition("m_open", idle, home, spring: openSpring, times: fps30(0.7), live: true)
            hold("m_hold", home, count: 1, live: true)
            Prefs.shared.meetingNotes = true
            call = ActivityCenter.Call(app: facetime, since: Date().addingTimeInterval(-42), camera: true)
            setLive([.call])
            NowModel.shared.debugSet(nil)
            MeetingCompanion.shared.debugSet(state: .consenting, lines: [], title: "Design Review")
            let consent = snap(.expanded(.activity(.call)))
            transition("m_call", home, consent, spring: morphSpring, times: fps30(0.6), live: true)
            hold("m_consent", consent, count: 1, live: true)
            MeetingCompanion.shared.debugSet(state: .recording, lines: [], title: "Design Review")
            let rec = snap(.expanded(.activity(.call)))
            transition("m_rec", consent, rec, spring: morphSpring, times: fps30(0.4), live: true)
            let said = "So we ship pricing on Friday, and Sam owns the deck."
            let words = said.split(separator: " ").map(String.init)
            hold("m_notes", rec, count: words.count + 1, live: true) { i in
                let text = words.prefix(i).joined(separator: " ")
                MeetingCompanion.shared.debugSet(state: .recording, lines: text.isEmpty ? [] : [.init(speaker: .them, text: text, at: Date())],
                                                 title: "Design Review")
            }
            MeetingCompanion.shared.debugSet(state: .idle, lines: [], title: "")
            call = nil; setLive([])
        }

        // Evening: hold the notch and ask.
        if want("v3voice") {
            BrainAgent.shared.reset()
            VoiceInput.shared.debugSet(state: .listening, transcript: "", level: 0.15)
            let voice = snap(.expanded(.brain))
            transition("v_open", idle, voice, spring: openSpring, times: fps30(0.6), live: true)
            let words = "What did I get done today?".split(separator: " ").map(String.init)
            let levels: [Float] = [0.18, 0.62, 0.74, 0.48, 0.81, 0.66, 0.52, 0.3]
            hold("v_talk", voice, count: words.count + 3, live: true) { i in
                VoiceInput.shared.debugSet(state: .listening, transcript: words.prefix(i).joined(separator: " "), level: levels[i % levels.count])
            }
            VoiceInput.shared.debugSet(state: .idle, transcript: "", level: 0)
        }

        // Your day, drawn as a ring.
        if want("v3day") {
            let spans: [(Int, Int, Int, Int, WorkMode)] = [(8, 0, 8, 40, .communicating), (8, 40, 10, 0, .writing), (10, 0, 10, 15, .meeting),
                (10, 15, 12, 30, .coding), (12, 30, 13, 20, .media), (13, 30, 14, 0, .writing), (14, 0, 15, 0, .meeting), (15, 0, 18, 20, .coding)]
            var story = DayStory(date: Date(), start: at(7, 58), end: at(20, 0))
            story.spans = spans.enumerated().map { RewindModel.Span(id: $0.offset, start: at($0.element.0, $0.element.1), end: at($0.element.2, $0.element.3), mode: $0.element.4) }
            story.meetings = [DateInterval(start: at(10, 0), end: at(10, 15)), DateInterval(start: at(14, 0), end: at(15, 0))]
            story.songs = stride(from: 0, to: 34, by: 1).map { DayStory.Song(at: at(8, 45).addingTimeInterval(Double($0) * 900), artist: ["M83", "The xx", "Bonobo", "Tycho"][$0 % 4]) }
            story.finished = [at(10, 0), at(12, 20), at(16, 40)]
            story.focus = 6.1 * 3600
            story.active = 8.9 * 3600
            story.modes = [.init(mode: .coding, seconds: 5.4 * 3600), .init(mode: .writing, seconds: 1.7 * 3600), .init(mode: .meeting, seconds: 1.25 * 3600)]
            story.topProject = "Mac Flow"
            story.priorities = (3, 3)
            story.headline = DayStory.headline(modes: story.modes, focus: story.focus, meetings: 2, songs: 34, project: "Mac Flow")
            DayArtModel.shared.debugSet(story)
            dayProgress = 0
            let day = snap(.expanded(.day))
            transition("d_open", idle, day, spring: openSpring, times: fps30(0.6), live: true)
            let n = 45
            hold("d_draw", day, count: n, live: true) { i in
                let x = Double(i) / Double(n - 1)
                dayProgress = 1 - pow(1 - x, 3)
            }
            dayProgress = nil
        }

        // Rewind: scrub through the day.
        if want("v3rewind") {
            var ms: [BrainStore.Moment] = []
            let plan: [(Int, Int, String, String, String, String, String)] = [
                (8, 0, "communicating", "", "Mail", "Inbox", ""), (8, 40, "writing", "Launch", "Pages", "Launch post.pages", "Weightless — Marconi Union"),
                (10, 0, "meeting", "", "FaceTime", "Standup", ""), (10, 15, "coding", "Mac Flow", "Xcode", "PlanView.swift", "Midnight City — M83"),
                (12, 30, "media", "", "Safari", "YouTube", ""), (13, 30, "writing", "Launch", "Pages", "Launch post.pages", "Intro — The xx"),
                (14, 0, "meeting", "", "FaceTime", "Design Review", ""), (15, 0, "coding", "Mac Flow", "Xcode", "Rooms.swift", "Midnight City — M83"),
            ]
            var id: Int64 = 1
            for (i, p) in plan.enumerated() {
                let end = i + 1 < plan.count ? at(plan[i + 1].0, plan[i + 1].1) : at(18, 20)
                var t = at(p.0, p.1)
                while t < end {
                    ms.append(BrainStore.Moment(id: id, ts: t, mode: p.2, project: p.3, bundle: "com.apple.dt.Xcode", app: p.4, title: p.5,
                                                document: p.5.hasSuffix(".swift") ? "file:///Users/me/Mac Flow/Sources/\(p.5)" : "", track: p.6,
                                                claude: p.3 == "Mac Flow" ? "Mac Flow" : ""))
                    id += 1
                    t = t.addingTimeInterval(300)
                }
            }
            let first = ms.firstIndex { cal.component(.hour, from: $0.ts) == 9 } ?? 0
            let last = ms.firstIndex { cal.component(.hour, from: $0.ts) == 15 && cal.component(.minute, from: $0.ts) == 30 } ?? ms.count - 1
            RewindModel.shared.debugSet(ms, index: first)
            let rewind = snap(.expanded(.rewind))
            transition("r_open", idle, rewind, spring: openSpring, times: fps30(0.6), live: true)
            let n = 40
            hold("r_scrub", rewind, count: n, live: true) { i in
                let x = Double(i) / Double(n - 1)
                let e = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
                RewindModel.shared.debugSet(ms, index: first + Int((Double(last - first) * e).rounded()))
            }
            transition("r_close", snap(.expanded(.rewind)), idle, spring: closeSpring, times: fps30(0.5), live: true)
        }

        if want("v3standby") { standBy4K() }
    }

    /// StandBy at 4K: the screen laid out at a MacBook Air's size, drawn at 3x.
    static func standBy4K() {
        let screen = CGSize(width: 1470, height: 956)
        let scale = CGFloat(Double(ProcessInfo.processInfo.environment["SB_SCALE"] ?? "3") ?? 3)
        let dir = out.appendingPathComponent("standby").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shot(_ name: String, _ page: StandByModel.Page, wallpaper: String, style: StandByClockStyle = .glass) {
            Prefs.shared.standByClockStyle = style.rawValue
            Prefs.shared.standByAccent = StandByAccent.white.rawValue
            Prefs.shared.standByWallpaper = wallpaper
            let model = StandByModel()
            model.prepare(screen: screen, scale: scale)
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            model.page = page
            model.night = false
            model.chromeVisible = true
            model.showHint = false
            SurfaceHarness.render(StandByView(model: model).frame(width: screen.width, height: screen.height), scheme: .dark, scale: scale,
                                  name: name, outDir: dir)
            print("  standby/\(name)")
        }
        Prefs.shared.standByDepth = true
        Prefs.shared.standByLyrics = true
        Prefs.shared.standByNightMode = false
        for w in Wallpapers.available { shot("glass-\(w.id)", .clock, wallpaper: w.id) }
        shot("analog-dunes", .clock, wallpaper: "dunes", style: .analog)
        shot("widgets-dunes", .widgets, wallpaper: "dunes")
        LyricsModel.shared.debugSet(SurfaceHarness.demoLyrics)
        // The current line moves down the song: lines start at 22 s and every 4.6 s after.
        for (k, elapsed) in [27.0, 31.6, 36.2, 40.8].enumerated() {
            NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: elapsed, artwork: SurfaceHarness.demoCover())
            shot("lyrics-\(k)", .nowPlaying, wallpaper: "dunes")
        }
    }
}
#endif
