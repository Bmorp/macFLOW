import Testing
import Foundation
@testable import Atoll

@Suite("Calculator")
struct CalculatorTests {
    @Test func arithmetic() {
        #expect(Calculator.evaluate("(12+8)*4.5") == 90)
        #expect(Calculator.evaluate("2^10") == 1024)
        #expect(Calculator.evaluate("10/4") == 2.5)
        #expect(Calculator.evaluate("sqrt(16)+1") == 5)
    }

    @Test func rejectsNonMath() {
        #expect(Calculator.evaluate("hello") == nil)
        #expect(Calculator.evaluate("42") == nil)          // a bare number is not a calculation
        #expect(Calculator.evaluate("3 +") == nil)
    }

    @Test func formatting() {
        #expect(Calculator.format(90) == "90")
        #expect(Calculator.format(2.5) == "2.5")
    }
}

@Suite("Conversions") @MainActor
struct ConverterTests {
    @Test func units() throws {
        let marathon = try #require(Converter.convert("26.2 mi in km"))
        #expect(marathon.output == "42.1648")
        let temp = try #require(Converter.convert("212 f to c"))
        #expect(temp.output == "100")
        let data = try #require(Converter.convert("1 gb in mb"))
        #expect(data.output == "1,000")
    }

    @Test func incompatibleUnitsAreIgnored() {
        #expect(Converter.convert("5 kg to km") == nil)
    }

    @Test func percent() throws {
        #expect(try #require(Converter.convert("15% of 2400")).output == "360")
    }

    @Test func timeZones() throws {
        let tokyo = try #require(Converter.convert("time in tokyo"))
        #expect(tokyo.detail.hasPrefix("Tokyo"))
        #expect(Converter.convert("time in atlantis") == nil)
    }
}

@Suite("Natural language")
struct ParsingTests {
    @Test func reminderWithTime() throws {
        let draft = try #require(RemindersService.parse("remind me to call Sam at 5pm"))
        #expect(draft.title == "Call Sam")
        let due = try #require(draft.due)
        #expect(Calendar.current.component(.hour, from: due) == 17)
    }

    @Test func reminderWithoutTime() throws {
        let draft = try #require(RemindersService.parse("todo buy oat milk"))
        #expect(draft.title == "Buy oat milk")
        #expect(draft.due == nil)
    }

    @Test func notAReminder() {
        #expect(RemindersService.parse("call Sam") == nil)
    }

    @Test @MainActor func timers() {
        #expect(SearchModel.timerMinutes("timer 10") == 10)
        #expect(SearchModel.timerMinutes("25 min focus") == 25)
        #expect(SearchModel.timerMinutes("timer") == nil)
        #expect(SearchModel.timerMinutes("timer 0") == nil)
    }
}

@Suite("Clipboard")
struct ClipboardTests {
    @Test func flavours() {
        #expect(ClipItem(text: "#5E5CE6", date: .now).flavor == .color)
        #expect(ClipItem(text: "https://apple.com/mac", date: .now).flavor == .link)
        #expect(ClipItem(text: "hello@atoll.app", date: .now).flavor == .email)
        #expect(ClipItem(text: "func greet() { }", date: .now).flavor == .code)
        #expect(ClipItem(text: "1,024", date: .now).flavor == .number)
        #expect(ClipItem(text: "Ship it on Friday", date: .now).flavor == .plain)
    }
}

@Suite("App search")
struct AppSearchTests {
    @Test func initials() {
        let vsc = AppEntry(url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"), name: "Visual Studio Code", bundleID: nil)
        #expect(vsc.initials == "vsc")
        #expect(vsc.searchName == "visual studio code")
    }
}

@Suite("Widget layout") @MainActor
struct WidgetLayoutTests {
    private func store(with list: [WidgetInstance]) -> (WidgetStore, UInt32) {
        Storage.readOnly = true
        let store = WidgetStore()
        let screen = WidgetStore.primaryScreen.displayID
        store.debugReplace(list.map { var w = $0; w.screenID = screen; return w })
        return (store, screen)
    }

    @Test func snapsOneGapFromANeighbour() {
        let (store, screen) = store(with: [WidgetInstance(kind: .weather, family: .small, offset: CGPoint(x: 32, y: 16), screenID: 0)])
        // Dropped a few points off "one gap to the right": lands exactly there, edges aligned.
        let p = store.placement(near: CGPoint(x: 32 + 170 + 16 + 5, y: 19), size: WidgetFamily.small.size, screen: screen, excluding: nil)
        #expect(p == CGPoint(x: 218, y: 16))
    }

    @Test func neverOverlaps() {
        let existing = WidgetInstance(kind: .upNext, family: .medium, offset: CGPoint(x: 32, y: 16), screenID: 0)
        let (store, screen) = store(with: [existing])
        let size = WidgetFamily.small.size
        let p = store.placement(near: CGPoint(x: 60, y: 30), size: size, screen: screen, excluding: nil)
        let taken = CGRect(origin: existing.offset, size: existing.family.size).insetBy(dx: -15, dy: -15)
        #expect(!taken.intersects(CGRect(origin: p, size: size)))
    }

    @Test func staysOnScreen() {
        let (store, screen) = store(with: [])
        let p = store.placement(near: CGPoint(x: -400, y: -400), size: WidgetFamily.large.size, screen: screen, excluding: nil)
        #expect(p.x >= WidgetStore.margin && p.y >= WidgetStore.margin / 2)
    }
}

@Suite("Your Live Activities") @MainActor
struct CustomActivityTests {
    @Test func progressLinkShowsAnActivity() throws {
        let a = CustomActivity()
        a.handle(URL(string: "atoll://progress?title=Building&detail=Atoll&progress=24&symbol=hammer.fill&tint=green")!)
        let item = try #require(a.current)
        #expect(item.title == "Building")
        #expect(item.detail == "Atoll")
        #expect(abs((item.progress ?? 0) - 0.24) < 0.0001)
        #expect(item.symbol == "hammer.fill")
    }

    @Test func doneClearsAndReports() {
        let a = CustomActivity()
        var finished: CustomActivity.Item?
        a.onFinish = { finished = $0 }
        a.handle(URL(string: "atoll://progress?title=Deploy")!)
        a.handle(URL(string: "atoll://done?title=Deployed")!)
        #expect(a.current == nil)
        #expect(finished?.title == "Deployed")
        #expect(finished?.state == .done)
    }

    @Test func linksCanOnlyShowShortPlainText() {
        let a = CustomActivity()
        let long = String(repeating: "x", count: 300)
        a.handle(URL(string: "atoll://progress?title=\(long)%0A%0Dline&symbol=not.a.real.symbol")!)
        #expect((a.current?.title.count ?? 0) <= 64)
        #expect(!(a.current?.title.contains("\n") ?? true))
        #expect(a.current?.symbol == "hammer.fill")
    }

    @Test func otherSchemesAreIgnored() {
        let a = CustomActivity()
        a.handle(URL(string: "https://example.com/progress?title=Nope")!)
        #expect(a.current == nil)
    }
}

@Suite("Claude")
struct ClaudeTests {
    @Test func busySessionIsWorking() throws {
        let s = try #require(ClaudeSessions.parse(["pid": 42, "sessionId": "abc", "cwd": "/Users/me/Projects/Atoll", "status": "busy",
                                                   "name": "Fix the island", "statusUpdatedAt": 1_700_000_000_000, "entrypoint": "claude-desktop"],
                                                  fallbackID: "42"))
        #expect(s.state == .working)
        #expect(s.folder == "Atoll")
        #expect(s.name == "Fix the island")
        #expect(s.viaDesktop)
        #expect(s.since == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func waitingStatusesNeedYou() {
        for status in ["awaiting_approval", "awaiting_user", "waiting_for_input"] {
            #expect(ClaudeSessions.parse(["pid": 1, "status": status], fallbackID: "1")?.state == .waiting)
        }
        #expect(ClaudeSessions.parse(["pid": 1, "status": "idle"], fallbackID: "1")?.state == .idle)
        #expect(ClaudeSessions.parse(["status": "busy"], fallbackID: "1") == nil)   // no process, no session
    }

    @Test func streamedAnswerAssembles() {
        let reader = StreamReader()
        let lines = """
        {"type":"system","subtype":"init"}
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}}
        {"type":"result","subtype":"success","is_error":false,"result":"Hello"}

        """
        var text = ""
        var finished = false
        // Arrives in arbitrary chunks, as a pipe delivers it.
        let data = Data(lines.utf8)
        for chunk in stride(from: 0, to: data.count, by: 17) {
            for e in reader.feed(data.subdata(in: chunk..<min(chunk + 17, data.count))) {
                switch e {
                case .delta(let t): text += t
                case .result(let r, let err): finished = !err && r == "Hello"
                case .message: break
                }
            }
        }
        #expect(text == "Hello")
        #expect(finished)
    }
}

@Suite("Brain")
struct BrainTests {
    @Test func classifiesWork() {
        #expect(Understanding.mode(bundle: "com.apple.dt.Xcode", title: "") == .coding)
        #expect(Understanding.mode(bundle: "com.apple.Safari", title: "Pull request #42 · atoll/atoll · GitHub") == .coding)
        #expect(Understanding.mode(bundle: "com.google.Chrome", title: "Inbox (3) - Gmail") == .communicating)
        #expect(Understanding.mode(bundle: "com.google.Chrome", title: "Lo-fi beats - YouTube") == .media)
        #expect(Understanding.mode(bundle: "com.unknown.app", title: "", overrides: ["com.unknown.app": .design]) == .design)
    }

    @Test func findsTheProject() {
        #expect(Understanding.project(bundle: "com.apple.dt.Xcode", title: "Atoll — IslandView.swift", known: []) == "Atoll")
        #expect(Understanding.project(bundle: "com.microsoft.VSCode", title: "index.ts — kerala-taxi-service", known: []) == "kerala-taxi-service")
        #expect(Understanding.project(bundle: "com.apple.Terminal", title: "~/Projects/Atoll — zsh — 80×24", known: []) == "Atoll")
        #expect(Understanding.project(bundle: "com.apple.Safari", title: "Survey results — workflowsurvey", known: ["workflowsurvey"]) == "workflowsurvey")
    }

    @Test func neverRecordsPrivateWindows() {
        #expect(Understanding.isPrivate(bundle: "com.1password.1password", title: ""))
        #expect(Understanding.isPrivate(bundle: "com.google.Chrome", title: "New Incognito Tab"))
        #expect(!Understanding.isPrivate(bundle: "com.apple.Safari", title: "Apple"))
    }

    @Test func memoryRoundTrips() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("brain-test-\(UUID().uuidString).sqlite")
        let store = BrainStore(url: url)
        store.record(.init(ts: Date(), kind: "app", app: "Xcode", bundle: "com.apple.dt.Xcode", duration: 600))
        store.record(.init(ts: Date(), kind: "app", app: "Xcode", bundle: "com.apple.dt.Xcode", duration: 300))
        store.setFact("pref:music.coding", "yes", source: "answered", confidence: 1)
        store.feedback("break", "accepted")
        store.feedback("break", "dismissed")
        #expect(store.appTime(since: Date().addingTimeInterval(-60)).first?.seconds == 900)
        #expect(store.fact("pref:music.coding") == "yes")
        #expect(store.reactions("break").accepted == 1)
        store.eraseEverything()
        #expect(store.counts().events == 0)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func condensesScreenText() {
        let text = ScreenSensor.condense(["File", "Edit", "func present() — swaps the island content", "func present() — swaps the island content",
                                          // Fake keys are split so secret scanners don't flag the fixture.
                                          "token sk_" + "live_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", "Build succeeded in 4.2 seconds"])
        #expect(text.contains("swaps the island content"))
        #expect(text.contains("Build succeeded"))
        #expect(!text.contains("sk_live"))
        #expect(text.components(separatedBy: "swaps").count == 2)   // de-duplicated
    }

    @Test func spotsErrors() {
        #expect(WorkContext.looksLikeError("error: cannot find 'foo' in scope\n  at main.swift:12"))
        #expect(!WorkContext.looksLikeError("Lunch at 1?"))
    }
}

@Suite("Now playing")
@MainActor
struct NowPlayingTests {
    @Test func oneSongCountsOnce() {
        let np = NowPlayingModel.shared
        let before = np.changeCount
        // Music's notification for a streamed song: no ID at all.
        np.report(source: .music, title: "Kareeb", artist: "Bharat Chauhan", album: "Uns", key: nil, playing: true)
        // AppleScript a moment later: the same song, with its hex persistent ID.
        np.report(source: .music, title: "Kareeb", artist: "Bharat Chauhan", album: "Uns", key: "74F3EC0C3D141F2D", playing: true)
        #expect(np.changeCount == before + 1)
        // A different song is a change.
        np.report(source: .music, title: "Khat", artist: "Navjot Ahuja", album: "Khat - Single", key: nil, playing: true)
        #expect(np.changeCount == before + 2)
    }

    @Test func albumCoversAreShared() {
        // Every song on an album shares one cover; library and catalog spellings agree.
        #expect(ArtworkStore.key(title: "Track A", artist: "M83", album: "Hurry Up, We're Dreaming")
                == ArtworkStore.key(title: "Track B", artist: "M83", album: "Hurry Up, We're Dreaming"))
        #expect(ArtworkStore.clean("Khat - Single") == "khat")
        #expect(ArtworkStore.clean("Cry For Me (feat. Someone)") == "cry for me")
        #expect(ArtworkStore.clean("After Hours (Deluxe)") == "after hours")
    }
}

@Suite("Catalog covers")
struct CatalogCoverTests {
    /// Apple's real answer for "Kareeb Bharat Chauhan" (trimmed): the single and the album version.
    let results: [[String: Any]] = [
        ["trackName": "Kareeb", "artistName": "Bharat Chauhan", "collectionName": "Kareeb - Single", "artworkUrl100": "https://x/single/100x100bb.jpg"],
        ["trackName": "Kareeb", "artistName": "Bharat Chauhan", "collectionName": "Uns", "artworkUrl100": "https://x/uns/100x100bb.jpg"],
        ["trackName": "Kareeb (Lofi)", "artistName": "Someone Else", "collectionName": "Lofi Mix", "artworkUrl100": "https://x/lofi/100x100bb.jpg"],
    ]

    @Test func picksTheAlbumYouArePlaying() {
        #expect(ArtworkStore.bestSong(results, title: "Kareeb", artist: "Bharat Chauhan", album: "Uns") == "https://x/uns/100x100bb.jpg")
        #expect(ArtworkStore.bestSong(results, title: "Kareeb", artist: "Bharat Chauhan", album: "Kareeb - Single") == "https://x/single/100x100bb.jpg")
    }

    @Test func refusesAGuess() {
        // Same title, wrong artist: no cover beats a wrong cover.
        #expect(ArtworkStore.bestSong(results, title: "Kareeb", artist: "Arijit Singh", album: "Other") == nil)
    }
}

@Suite("Plan your day")
struct PlanTests {
    let cal = Calendar.current
    var day: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 23))! }
    func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }
    func hm(_ d: Date) -> String { String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d)) }

    @Test func readsMeetingsInPlainWords() throws {
        let a = try #require(PlanScheduler.parseMeeting("Call with Sam at 4pm for 30m", on: day))
        #expect(a.title == "Call with Sam")
        #expect(hm(a.start) == "16:00")
        #expect(a.minutes == 30)
        let b = try #require(PlanScheduler.parseMeeting("Design review 2-3pm", on: day))
        #expect(b.title == "Design review")
        #expect(hm(b.start) == "14:00")
        #expect(b.minutes == 60)
        let c = try #require(PlanScheduler.parseMeeting("standup 10:30 for an hour", on: day))
        #expect(c.title == "Standup")
        #expect(hm(c.start) == "10:30")
        #expect(c.minutes == 60)
        let d = try #require(PlanScheduler.parseMeeting("1:1 with Priya at 3:15 for 1.5h", on: day))
        #expect(hm(d.start) == "15:15")       // an afternoon hour without am/pm
        #expect(d.minutes == 90)
        #expect(PlanScheduler.parseMeeting("Finish 3 slides", on: day) == nil)   // a number isn't a time
        #expect(PlanScheduler.parseMeeting("", on: day) == nil)
    }

    @Test func fitsPrioritiesAroundMeetings() {
        // Planning at 8:40; meetings 10:00–10:30 and 14:00–15:00.
        let busy = [DateInterval(start: at(10), end: at(10, 30)), DateInterval(start: at(14), end: at(15))]
        let p = [Priority(title: "Write the spec", minutes: 60), Priority(title: "Review PRs", minutes: 90), Priority(title: "", minutes: 30)]
        let items = PlanScheduler.schedule(priorities: p, busy: busy, from: at(8, 40), dayStart: 9, dayEnd: 19)
        let focus = items.filter { $0.kind == .focus }
        #expect(focus.count == 2)                                    // the empty one is skipped
        #expect(hm(focus[0].start) == "09:00")                       // first free hour, before the 10:00 meeting
        #expect(focus[0].id == p[0].id)                              // keeps the priority's identity
        #expect(hm(focus[1].start) == "10:40")                       // after the meeting and its 10-min buffer
        let lunch = items.first { $0.kind == .rest }
        #expect(lunch.map { hm($0.start) } == "12:30")
        // Nothing overlaps anything.
        let all = items.map(\.interval) + busy
        for (i, a) in all.enumerated() { for b in all[(i + 1)...] { #expect(a.intersection(with: b).map { $0.duration == 0 } ?? true) } }
    }

    @Test func leavesOutWhatDoesNotFit() {
        let items = PlanScheduler.schedule(priorities: [Priority(title: "Big thing", minutes: 180)], busy: [], from: at(17, 30), dayStart: 9, dayEnd: 19)
        #expect(items.isEmpty)
    }

    @Test func stableIdentityForCalendarEvents() {
        #expect(UUID(stable: "event-1") == UUID(stable: "event-1"))
        #expect(UUID(stable: "event-1") != UUID(stable: "event-2"))
    }
}

@Suite("Flow inbox") @MainActor
struct FlowInboxTests {
    @Test func questionsWaitAndSuggestionsReplace() {
        let inbox = FlowInbox()   // no island in tests: nothing pops, items just wait
        let q = BrainQuestion(key: "pref:x", text: "Like music while coding?", detail: "", options: [.init(label: "Yes", value: "yes")])
        #expect(inbox.ask(q))
        #expect(!inbox.ask(BrainQuestion(key: "pref:x", text: "Again?", detail: "", options: [])))   // already waiting
        let s1 = BrainSuggestion(kind: "break", symbol: "cup.and.saucer", title: "Take a break", detail: "", actionTitle: "OK", action: .none, confidence: 0.5)
        let s2 = BrainSuggestion(kind: "break", symbol: "cup.and.saucer", title: "Really, a break", detail: "", actionTitle: "OK", action: .none, confidence: 0.5)
        inbox.suggest(s1)
        inbox.suggest(s2)
        #expect(inbox.items.count == 2)                             // the newer break replaced the older
        #expect(inbox.top?.id == s2.id)
        inbox.resolve(s2.id)
        #expect(inbox.top?.id == q.id)                              // the question is still there, waiting
    }
}

@Suite("Rooms, Rewind, meetings, your day")
struct FlowNextTests {
    let cal = Calendar.current
    var day: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 23))! }
    func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }

    @Test func lateNightBelongsToTheDayItEnds() {
        // 1 AM Monday: the record's day is still Sunday (it began at 4 AM Sunday); 9 AM Monday: Monday from 4 AM.
        let start = RewindModel.dayStart(for: at(1).addingTimeInterval(86_400))
        #expect(start == at(4))
        #expect(RewindModel.dayStart(for: at(9)) == at(4))
    }

    @Test func roomKeysIgnoreCaseAndSpacing() {
        #expect(Room.key(for: "  Write the   Launch post ") == "write the launch post")
    }

    @Test func rewindJoinsAStretchOfOneKindOfWork() {
        let ms = [BrainStore.Moment(ts: at(9), mode: "coding"), BrainStore.Moment(ts: at(9, 5), mode: "coding"),
                  BrainStore.Moment(ts: at(9, 10), mode: "meeting"), BrainStore.Moment(ts: at(10, 30), mode: "coding")]
        let spans = RewindModel.spans(ms, until: at(10, 40))
        #expect(spans.count == 3)
        #expect(spans[0].mode == .coding && spans[0].start == at(9) && spans[0].end == at(9, 10))
        #expect(spans[1].end == at(9, 20))          // a lone moment lasts at most ten minutes
        #expect(spans[2].end == at(10, 40))
    }

    @Test func findsActionItemsWithoutTheModel() {
        let items = MeetingCompanion.actionItems(from: [
            "Thanks everyone. I'll send the deck to Sam by Friday. The weather is nice.",
            "Can you update the pricing page? Great.",
        ])
        #expect(items == ["I'll send the deck to Sam by Friday", "Can you update the pricing page"])
    }

    @Test func movingKeepsTheTimeUnlessOneIsGiven() throws {
        let original = at(15)
        let tomorrow = try #require(CalendarModel.target("tomorrow", from: original, now: at(9)))
        #expect(cal.component(.hour, from: tomorrow) == 15)
        #expect(cal.isDate(tomorrow, inSameDayAs: cal.date(byAdding: .day, value: 1, to: original)!))
        let four = try #require(CalendarModel.target("4pm", from: original, now: at(9)))
        #expect(cal.component(.hour, from: four) == 16)
        #expect(cal.isDate(four, inSameDayAs: original))            // just a time: same day as it was
        let tomorrowTen = try #require(CalendarModel.target("tomorrow at 10am", from: original, now: at(9)))
        #expect(cal.component(.hour, from: tomorrowTen) == 10)
        #expect(cal.isDate(tomorrowTen, inSameDayAs: cal.date(byAdding: .day, value: 1, to: at(9))!))
    }

    @Test func theDayReadsBack() {
        let line = DayStory.headline(modes: [.init(mode: .coding, seconds: 5 * 3600), .init(mode: .meeting, seconds: 3600)],
                                     focus: 4.5 * 3600, meetings: 1, songs: 10, project: "Atoll")
        #expect(line == "A day of building, mostly on Atoll — deep and steady")
        #expect(DayStory.headline(modes: [], focus: 0, meetings: 0, songs: 0, project: nil) == "A quiet day")
    }

    @Test func agendaDropsTheDialIn() {
        let notes = "Agenda:\n1. Pricing\n2. Launch date\n\nJoin Zoom Meeting https://zoom.us/j/123\nMeeting ID: 123\nPasscode: 9"
        #expect(CalendarModel.agenda(notes) == "Agenda:\n1. Pricing\n2. Launch date")
    }
}

@Suite("Flow learns")
struct LearningTests {
    let cal = Calendar.current
    func day(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    /// Ten weekdays: deep work 9:30–11:30 every morning (with music on half), scattered communication after lunch.
    func history() -> (sessions: [Patterns.Session], music: [Date], switches: [Date]) {
        var sessions: [Patterns.Session] = [], music: [Date] = [], switches: [Date] = []
        for d in 5...16 where ![10, 11].contains(d) {
            sessions.append(.init(start: day(d, 9, 30), end: day(d, d % 2 == 0 ? 11 : 10, 30), mode: .coding))
            if d % 2 == 0 { music.append(day(d, 9, 25)) }
            sessions.append(.init(start: day(d, 14), end: day(d, 15), mode: .communicating))
            sessions.append(.init(start: day(d, 15, 30), end: day(d, 16), mode: .meeting))
            for k in 0..<30 { switches.append(day(d, 14, k * 2)) }
            for k in 0..<4 { switches.append(day(d, 10, k * 10)) }
        }
        return (sessions, music, switches)
    }

    @Test func findsTheSharpestHours() {
        let h = history()
        let p = Patterns.compute(sessions: h.sessions, music: h.music, switches: h.switches, now: day(17, 8))
        #expect(p.days == 10)
        #expect(p.bestStart == 9 && p.bestEnd == 11)
        #expect(p.scatteredHour == 14)
        #expect(p.focusLength == 120)                     // median of 60- and 120-minute mornings → the longer half
        #expect(p.musicLift.map { $0 > 1.9 } == true)     // the music mornings ran twice as long
        #expect(p.insights.contains { $0.contains("sharpest") })
    }

    @Test func needsAFewDaysBeforeItSpeaks() {
        let p = Patterns.compute(sessions: [.init(start: day(5, 9), end: day(5, 11), mode: .coding)], music: [], switches: [], now: day(6, 8))
        #expect(!p.isReady)
        #expect(p.insights.isEmpty)
    }

    @Test func thePlanPutsTheTopPriorityInTheSharpestHours() {
        let window = DateInterval(start: day(23, 10), end: day(23, 12))
        let items = PlanScheduler.schedule(priorities: [Priority(title: "Write the spec", minutes: 60), Priority(title: "Inbox", minutes: 30)],
                                           busy: [], from: day(23, 8, 40), dayStart: 9, dayEnd: 19, focusWindow: window)
        let spec = items.first { $0.title == "Write the spec" }
        let inbox = items.first { $0.title == "Inbox" }
        #expect(spec.map { cal.component(.hour, from: $0.start) } == 10)   // in the window, not at 9
        #expect(inbox.map { cal.component(.hour, from: $0.start) } == 9)   // the rest fills from the start of the day
    }

    @Test func anHourOfWorkReadsAsASentence() {
        let ms = [BrainStore.Moment(ts: day(23, 10, 5), mode: "coding", project: "Atoll", app: "Xcode", document: "file:///x/PlanView.swift", track: "Midnight City — M83"),
                  BrainStore.Moment(ts: day(23, 10, 30), mode: "coding", project: "Atoll", app: "Xcode", document: "file:///x/Rooms.swift")]
        let s = MemoryKeeper.describe(hour: day(23, 10), ms)
        #expect(s.contains("coding on Atoll in Xcode"))
        #expect(s.contains("PlanView.swift") && s.contains("Rooms.swift"))
        #expect(s.contains("Midnight City"))
    }
}

@Suite("Flow Lens")
struct LensTests {
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!

    @Test func aTimeAndAPlaceBecomesAnEvent() throws {
        let a = LensReader.actions(for: "Lunch with Sam tomorrow at 1pm", now: now)
        #expect(a.first?.id == "event")
        guard case .addEvent(let date, let title)? = a.first else { Issue.record("no event"); return }
        #expect(Calendar.current.component(.hour, from: date) == 13)
        #expect(title == "Lunch with Sam")
        #expect(a.contains { $0.id == "remind" })
    }

    @Test func mostCopiesShowNothing() {
        #expect(LensReader.actions(for: "hello", now: now).isEmpty)
        #expect(LensReader.actions(for: "https://developer.apple.com/design", now: now).isEmpty)
        #expect(LensReader.actions(for: "sk_" + "live_51Hx9aBcD3fGhIjKlMn0pQr", now: now).isEmpty)  // a secret
        #expect(LensReader.actions(for: "let x = foo(); if x { return }", now: now).isEmpty)       // code
        #expect(LensReader.actions(for: "Rebuild the notch island", now: now).isEmpty)
    }

    @Test func aLongPassageCanBeSummarised() {
        let text = String(repeating: "The team agreed to ship the pricing page on Friday after the review. ", count: 6)
        let ids = LensReader.actions(for: text, now: now).map(\.id)
        #expect(ids.contains("summarize") && ids.contains("tasks"))
    }

    @Test func aQuestionInvitesAReply() {
        let ids = LensReader.actions(for: "Hey! Could you send me the deck before the call? Thanks", now: now).map(\.id)
        #expect(ids.contains("reply"))
    }

    @Test func anotherLanguageCanBeTranslated() {
        let ids = LensReader.actions(for: "Bonjour, pouvez-vous m'envoyer le document avant la réunion de demain matin ?", now: now).map(\.id)
        #expect(ids.contains("translate"))
    }
}

@Suite("Brief, cards, habits")
struct ContentTests {
    @Test func readsRSSAndAtom() {
        let rss = """
        <rss><channel><item><title>Apple ships &amp; things</title><link>https://a.com/1</link>
        <pubDate>Mon, 26 Oct 2026 08:00:00 +0000</pubDate><description><![CDATA[<p>Big news.</p>]]></description></item></channel></rss>
        """
        let a = FeedParser.parse(Data(rss.utf8), source: "A")
        #expect(a.count == 1)
        #expect(a.first?.title == "Apple ships & things")
        #expect(a.first?.summary == "Big news.")
        #expect(a.first?.link.absoluteString == "https://a.com/1")
        let atom = """
        <feed><entry><title>Swift 7</title><link rel="alternate" href="https://b.com/s"/><updated>2026-10-26T07:00:00Z</updated>
        <summary>New things.</summary></entry></feed>
        """
        let b = FeedParser.parse(Data(atom.utf8), source: "B")
        #expect(b.first?.link.absoluteString == "https://b.com/s")
        #expect(b.first.map { Calendar.current.component(.year, from: $0.date) } == 2026)
    }

    @Test func cardsComeBackSpacedOut() {
        let now = Date()
        var c = StudyCard(question: "Q", answer: "A", source: "S")
        c.review(.good, now: now)
        #expect(abs(c.due.timeIntervalSince(now) - 86_400) < 1)          // a day
        c.review(.good, now: now)
        #expect(abs(c.due.timeIntervalSince(now) - 3 * 86_400) < 1)      // three days
        c.review(.again, now: now)
        #expect(abs(c.due.timeIntervalSince(now) - 600) < 1)             // forgot it: ten minutes
        #expect(c.ease < 2.3)
    }

    @Test func habitsReadAsSentences() {
        let t0 = Date()
        var ms: [BrainStore.Moment] = []
        for i in 0..<8 {
            ms.append(.init(ts: t0.addingTimeInterval(Double(i) * 3600), mode: "meeting", bundle: "us.zoom.xos", app: "Zoom"))
            ms.append(.init(ts: t0.addingTimeInterval(Double(i) * 3600 + 300), mode: "coding", bundle: "com.apple.dt.Xcode", app: "Xcode"))
        }
        let s = Habits.describe(ms)
        #expect(s.contains { $0.contains("After Zoom you usually go to Xcode") })
    }
}

@Suite("Lyrics")
struct LyricsTests {
    @Test func parsesTimestampsTagsAndOffsets() {
        let lines = LRC.parse("""
        [ar:Someone]
        [offset:+500]
        [00:12.50]First line
        [00:20.00][01:10.00]Chorus
        [00:15:25]Colon centiseconds <00:15.40>with <00:15.90>words
        """)
        #expect(lines.map(\.text) == ["First line", "Colon centiseconds with words", "Chorus", "Chorus"])
        #expect(abs(lines[0].time - 12.0) < 0.001)        // +500 ms offset: half a second sooner
        #expect(abs(lines[1].time - 14.75) < 0.001)
        #expect(abs(lines[3].time - 69.5) < 0.001)
    }

    @Test func gapsOnlyWhereTheSongBreathes() {
        let timed = LRC.timed(LRC.parse("""
        [00:08.00]Intro is long enough for dots
        [00:12.00]Next
        [00:14.00]
        [00:15.00]A breath is not a gap
        [00:19.00]
        [00:40.00]After a solo
        [00:44.00]Then a long silence with no blank line
        [01:20.00]Back again
        """))
        #expect(timed.map(\.text) == ["", "Intro is long enough for dots", "Next", "A breath is not a gap", "", "After a solo",
                                      "Then a long silence with no blank line", "", "Back again"])
        #expect(timed[0].time == 0)
        #expect(abs(timed[7].time - (44 + LRC.longestLine)) < 0.001)
    }

    @Test func findsTheLineBeingSung() throws {
        let lyrics = try #require(Lyrics.synced(lrc: "[00:10.00]One\n[00:20.00]Two\n[00:30.00]Three", source: "test"))
        #expect(lyrics.lines.first?.isGap == true)        // 10 s of intro
        #expect(lyrics.index(at: 5) == 0)
        #expect(lyrics.lines[lyrics.index(at: 10)!].text == "One")
        #expect(lyrics.lines[lyrics.index(at: 29.9)!].text == "Two")
        #expect(lyrics.lines[lyrics.index(at: 300)!].text == "Three")
        #expect(lyrics.end(of: lyrics.lines.count - 1, duration: 200) == 200)
    }

    @Test func plainLyricsDropBlankLines() throws {
        let lyrics = try #require(Lyrics.plain("Verse one\n\nVerse two\n", source: "music"))
        #expect(lyrics.lines.map(\.text) == ["Verse one", "Verse two"])
        #expect(!lyrics.synced && lyrics.index(at: 50) == nil)
    }

    @Test func matchesOnlyTheSameSongAtTheSameLength() {
        let records = [
            LRCLib.Record(trackName: "Midnight City", artistName: "M83", albumName: nil, duration: 300, instrumental: false, plainLyrics: "a", syncedLyrics: "[00:01.00]a"),
            LRCLib.Record(trackName: "Midnight City (Remix)", artistName: "Someone Else", albumName: nil, duration: 243, instrumental: false, plainLyrics: "b", syncedLyrics: "[00:01.00]b"),
            LRCLib.Record(trackName: "Midnight City", artistName: "M83", albumName: nil, duration: 242, instrumental: false, plainLyrics: "c", syncedLyrics: nil),
            LRCLib.Record(trackName: "Midnight City", artistName: "M83", albumName: nil, duration: 244.5, instrumental: false, plainLyrics: "d", syncedLyrics: "[00:01.00]d"),
        ]
        // The synced record within 3 s wins over a closer plain one; wrong artist and wrong length never match.
        #expect(LRCLib.best(records, title: "Midnight City", artist: "M83", duration: 243)?.plainLyrics == "d")
        #expect(LRCLib.best(records, title: "Lower Your Eyelids", artist: "M83", duration: 243) == nil)
    }
}

@Suite("Updates")
struct UpdaterTests {
    @Test func comparesVersions() {
        #expect(Updater.isNewer("8.1.0", than: "8.0.0"))
        #expect(Updater.isNewer("8.10.0", than: "8.9.2"))     // numeric, not alphabetical
        #expect(Updater.isNewer("9", than: "8.9.9"))
        #expect(!Updater.isNewer("8.1", than: "8.1.0"))       // missing parts count as zero
        #expect(!Updater.isNewer("8.0.9", than: "8.1.0"))
    }

    @Test func readsAReleaseWithItsChecksum() throws {
        let json = """
        {"tag_name": "v8.1.2", "html_url": "https://github.com/Bmorp/macFLOW/releases/tag/v8.1.2", "draft": false, "prerelease": false,
         "assets": [{"name": "MacFlow-8.1.2.zip", "browser_download_url": "https://example.com/MacFlow-8.1.2.zip"},
                    {"name": "MacFlow-8.1.2.zip.sha256", "browser_download_url": "https://example.com/MacFlow-8.1.2.zip.sha256"}]}
        """
        let release = try #require(Updater.parse(Data(json.utf8)))
        #expect(release.version == "8.1.2")
        #expect(release.archive.lastPathComponent == "MacFlow-8.1.2.zip")
        #expect(release.checksum.lastPathComponent == "MacFlow-8.1.2.zip.sha256")
    }

    @Test func ignoresReleasesItCantVerify() {
        // A DMG alone, no checksum, or a pre-release: nothing to offer.
        let dmgOnly = """
        {"tag_name": "v8.1.2", "html_url": "https://example.com",
         "assets": [{"name": "a.dmg", "browser_download_url": "https://example.com/a.dmg"}, {"name": "a.dmg.sha256", "browser_download_url": "https://example.com/a.dmg.sha256"}]}
        """
        let noChecksum = """
        {"tag_name": "v8.1.2", "html_url": "https://example.com", "assets": [{"name": "a.zip", "browser_download_url": "https://example.com/a.zip"}]}
        """
        let prerelease = """
        {"tag_name": "v9.0.0", "html_url": "https://example.com", "prerelease": true,
         "assets": [{"name": "a.zip", "browser_download_url": "https://example.com/a.zip"}, {"name": "a.zip.sha256", "browser_download_url": "https://example.com/a.zip.sha256"}]}
        """
        #expect(Updater.parse(Data(dmgOnly.utf8)) == nil)
        #expect(Updater.parse(Data(noChecksum.utf8)) == nil)
        #expect(Updater.parse(Data(prerelease.utf8)) == nil)
        #expect(Updater.parse(Data("{}".utf8)) == nil)
    }
}
