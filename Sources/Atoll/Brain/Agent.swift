import AppKit
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Atoll's Brain as an assistant you talk to: it answers from what it knows about your day, and it acts — timers,
/// music, volume, brightness, opening projects and apps, reminders, remembering what you tell it — through a fixed
/// set of safe tools. Apple's on-device model; nothing leaves this Mac (except a question you hand to Claude).
@MainActor
final class BrainAgent: ObservableObject {
    static let shared = BrainAgent()

    struct Message: Identifiable, Equatable {
        enum Role { case you, atoll, action }
        let id = UUID()
        let role: Role
        var text: String
        var symbol: String? = nil
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var thinking = false
    @Published var draft = ""
    /// Debug checks: tools report what they'd do without doing it.
    nonisolated(unsafe) static var dryRun = false

    private var task: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var sessionBox: AnyObject?
    /// Something you're looking at (a page), to go with your next question.
    private var pendingContext: String?

    /// "Ask about it": the next question carries this context.
    func draftContext(_ context: String, about title: String) {
        pendingContext = context
        noteAction("Ask anything about “\(title.prefix(60))”", symbol: "doc.text.magnifyingglass")
    }

    var available: Bool { Mind.shared.isAvailable }

    static let starters = [
        "What did I get done today?",
        "What was I doing at 3?",
        "Show my day",
    ]

    func send(_ text: String? = nil) {
        let q = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        draft = ""
        messages.append(Message(role: .you, text: q))
        guard available else {
            messages.append(Message(role: .atoll, text: Mind.shared.unavailableReason))
            return
        }
        thinking = true
        let reply = Message(role: .atoll, text: "")
        messages.append(reply)
        let replyID = reply.id
        task = Task { @MainActor in
            defer { thinking = false }
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                await respond(to: q, into: replyID, retry: true)
                return
            }
            #endif
            update(replyID, Mind.shared.unavailableReason)
        }
    }

    /// A page summarized or explained: a short line for what you asked, then the answer streaming in. Apart from the chat
    /// session (whose tools and context leave no room for a page), so it works even while Flow is mid-answer.
    func page(_ label: String, instruction: String, title: String, text: String) {
        messages.append(Message(role: .you, text: label))
        let reply = Message(role: .atoll, text: "")
        messages.append(reply)
        let id = reply.id
        pageTask?.cancel()
        pageTask = Task { @MainActor in
            do {
                for try await partial in Mind.shared.onPage(instruction, title: title, text: text) { update(id, partial) }
                if messages.first(where: { $0.id == id })?.text.isEmpty ?? false { update(id, "The page didn’t have anything to summarize.") }
            } catch {
                if !Task.isCancelled { update(id, "I couldn’t read that page: \(error.localizedDescription)") }
            }
        }
    }

    #if DEBUG
    func debugSet(_ list: [Message]) { messages = list; thinking = false }
    #endif

    func reset() {
        pendingContext = nil
        task?.cancel()
        thinking = false
        messages.removeAll()
        sessionBox = nil
    }

    /// A tool did something: show it in the conversation as it happens.
    func noteAction(_ text: String, symbol: String) {
        // Keep the action just above Atoll's (still-streaming) reply.
        let action = Message(role: .action, text: text, symbol: symbol)
        if let last = messages.last, last.role == .atoll, last.text.isEmpty {
            messages.insert(action, at: messages.count - 1)
        } else {
            messages.append(action)
        }
    }

    private func update(_ id: UUID, _ text: String) {
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].text = text }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func session() -> LanguageModelSession {
        if let s = sessionBox as? LanguageModelSession { return s }
        let s = LanguageModelSession(tools: AtollTools.all, instructions: Self.instructions())
        sessionBox = s
        return s
    }

    @available(macOS 26.0, *)
    private func respond(to q: String, into id: UUID, retry: Bool) async {
        do {
            // The relevant past, by meaning (on this Mac): it goes with the question, so Flow answers from memory too.
            let hits = await Memory.shared.recall(q, limit: 5)
            var prompt = hits.isEmpty ? q : "Possibly relevant memories (use only if they help):\n\(Memory.lines(hits))\n\nThe user says: \(q)"
            if let page = pendingContext {
                pendingContext = nil
                prompt = "What the user is looking at:\n\(page)\n\n" + prompt
            }
            for try await partial in session().streamResponse(to: prompt) {
                update(id, partial.content)
            }
            if messages.first(where: { $0.id == id })?.text.isEmpty ?? false { update(id, "Done.") }
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error, retry {
                // A long conversation: start a fresh session (with fresh context) and try once more.
                sessionBox = nil
                await respond(to: q, into: id, retry: false)
            } else {
                update(id, "I couldn’t answer that: \(error.localizedDescription)")
            }
        } catch {
            if !Task.isCancelled { update(id, "I couldn’t answer that: \(error.localizedDescription)") }
        }
    }
    #endif

    /// Who Atoll is, what it can do, and what it knows right now — kept short for the on-device context window.
    static func instructions() -> String {
        let digest = String(BrainEngine.shared.digest().prefix(1800))
        return """
        You are Flow, the calm, capable personal assistant in Mac Flow, living in the notch of the user's Mac.
        When the user asks you to do something, do it with a tool — timers, playing music, playback, volume, brightness,
        Night Shift, True Tone, opening an app or project, reminders, joining the next meeting, remembering a fact,
        adding a meeting or task to today's plan, opening the day planner, setting up the Mac for a piece of work (setRoom),
        picking a project up where it was left (resume), saying what they were doing at a time today (recall), showing their
        day (showDay), moving a calendar event (moveEvent), taking meeting notes (meetingNotes), and searching their past days
        by meaning (searchMemory) — use it for anything about earlier days; doing something with the page open in their
        browser (readPage: summarize, explain, save to learn); and the news from their sources (news).
        When the user has a plan for today (in the context), guide them by it: what's next, what to cut if they're behind.
        After acting, confirm in one short sentence. You can use several tools for one request.
        For questions about their day, projects, music or habits, answer only from the context below. Never invent.
        For coding, writing or general-knowledge questions that need depth, use handToClaude.
        Be brief and warm: one to three sentences.

        Context:
        \(digest)
        """
    }
}

#if canImport(FoundationModels)
/// The only things the Brain can do. Each is local, reversible and visible in the conversation.
@available(macOS 26.0, *)
enum AtollTools {
    /// Dry run: show the call, do nothing.
    static func dry(_ call: String) async -> String {
        await MainActor.run { BrainAgent.shared.noteAction("would " + call, symbol: "testtube.2") }
        return "Done."
    }

    static var all: [any Tool] {
        [StartTimer(), Playback(), PlayMusic(), SetLevel(), DisplayFeature(), OpenThing(), Remember(), Reminder(), JoinMeeting(),
         AddToPlan(), OpenPlan(), SetRoom(), Resume(), Recall(), ShowDay(), MoveEvent(), TakeNotes(), SearchMemory(),
         ReadPage(), News(), HandToClaude()]
    }

    struct StartTimer: Tool {
        let name = "startTimer"
        let description = "Start a focus or break timer in the notch."
        @Generable struct Arguments {
            @Guide(description: "Length in minutes", .range(1...180)) var minutes: Int
            @Guide(description: "A short label, like Focus, Break or a task name") var label: String
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("startTimer(\(arguments.minutes), \(arguments.label))") }
            await MainActor.run {
                let label = arguments.label.isEmpty ? "Focus" : arguments.label
                FocusTimer.shared.start(minutes: arguments.minutes, label: label)
                BrainAgent.shared.noteAction("Started a \(arguments.minutes)-minute \(label) timer", symbol: "timer")
            }
            return "Timer started."
        }
    }

    struct Playback: Tool {
        let name = "controlPlayback"
        let description = "Play, pause, skip to the next track or go back to the previous one in the music player."
        @Generable enum Action { case play, pause, next, previous }
        @Generable struct Arguments { var action: Action }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("controlPlayback(\(arguments.action))") }
            await MainActor.run {
                let np = NowPlayingModel.shared
                switch arguments.action {
                case .play: if !np.isPlaying { np.playPause() }; BrainAgent.shared.noteAction("Playing", symbol: "play.fill")
                case .pause: if np.isPlaying { np.playPause() }; BrainAgent.shared.noteAction("Paused", symbol: "pause.fill")
                case .next: np.next(); BrainAgent.shared.noteAction("Next track", symbol: "forward.fill")
                case .previous: np.previous(); BrainAgent.shared.noteAction("Previous track", symbol: "backward.fill")
                }
            }
            return "Done."
        }
    }

    struct PlayMusic: Tool {
        let name = "playMusic"
        let description = "Play an artist, song or genre in the user's music app. If they ask for their usual music for a kind of work, pass the artist from the context."
        @Generable struct Arguments {
            @Guide(description: "Artist, song or genre to play") var query: String
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("playMusic(\(arguments.query))") }
            await MainActor.run {
                BrainEngine.shared.perform(.playArtist(arguments.query))
                BrainAgent.shared.noteAction("Playing \(arguments.query)", symbol: "music.note")
            }
            return "Opened \(arguments.query) in the music app."
        }
    }

    struct SetLevel: Tool {
        let name = "setLevel"
        let description = "Set the Mac's sound volume or display brightness, as a percentage."
        @Generable enum Setting { case volume, brightness }
        @Generable struct Arguments {
            var setting: Setting
            @Guide(description: "Percentage from 0 to 100", .range(0...100)) var percent: Int
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("setLevel(\(arguments.setting), \(arguments.percent))") }
            let v = Double(arguments.percent) / 100
            await MainActor.run {
                switch arguments.setting {
                case .volume:
                    IslandManager.shared.noteOwnVolumeChange()
                    SystemVolume.shared.set(v)
                    BrainAgent.shared.noteAction("Volume \(arguments.percent)%", symbol: "speaker.wave.2.fill")
                case .brightness:
                    DisplayControl.shared.setBrightness(v)
                    BrainAgent.shared.noteAction("Brightness \(arguments.percent)%", symbol: "sun.max.fill")
                }
            }
            return "Set."
        }
    }

    struct DisplayFeature: Tool {
        let name = "setDisplayFeature"
        let description = "Turn Night Shift or True Tone on or off."
        @Generable enum Feature { case nightShift, trueTone }
        @Generable struct Arguments { var feature: Feature; var on: Bool }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("setDisplayFeature(\(arguments.feature), \(arguments.on))") }
            await MainActor.run {
                switch arguments.feature {
                case .nightShift:
                    DisplayControl.shared.setNightShift(arguments.on)
                    BrainAgent.shared.noteAction("Night Shift \(arguments.on ? "on" : "off")", symbol: "moon.fill")
                case .trueTone:
                    DisplayControl.shared.setTrueTone(arguments.on)
                    BrainAgent.shared.noteAction("True Tone \(arguments.on ? "on" : "off")", symbol: "circle.lefthalf.filled")
                }
            }
            return "Done."
        }
    }

    struct OpenThing: Tool {
        let name = "open"
        let description = "Open one of the user's projects (opens the apps they use for it) or an app by name."
        @Generable struct Arguments {
            @Guide(description: "Project or app name") var name: String
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("open(\(arguments.name))") }
            return await MainActor.run {
                let q = arguments.name.lowercased()
                if let p = InsightModel.shared.insight.projects.first(where: { $0.name.lowercased().contains(q) || q.contains($0.name.lowercased()) }), !p.apps.isEmpty {
                    BrainEngine.shared.perform(.openApps(p.apps))
                    BrainAgent.shared.noteAction("Opened \(p.name) — \(p.appNames.prefix(3).joined(separator: ", "))", symbol: "folder.fill")
                    return "Opened the project \(p.name)."
                }
                if let app = AppCatalog.shared.search(arguments.name, limit: 1).first {
                    AppCatalog.shared.launch(app)
                    BrainAgent.shared.noteAction("Opened \(app.name)", symbol: "app.fill")
                    return "Opened \(app.name)."
                }
                return "I couldn't find a project or app called \(arguments.name)."
            }
        }
    }

    struct Remember: Tool {
        let name = "remember"
        let description = "Remember something the user tells you about themselves, their preferences or their work, for later."
        @Generable struct Arguments {
            @Guide(description: "The fact, in a short sentence, e.g. 'Likes lo-fi while writing'") var fact: String
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("remember(\(arguments.fact))") }
            await MainActor.run {
                let key = "told:" + String(arguments.fact.lowercased().filter { $0.isLetter || $0 == " " }.prefix(60))
                BrainStore.shared.setFact(key, arguments.fact, source: "answered", confidence: 1)
                BrainAgent.shared.noteAction("Remembered: \(arguments.fact)", symbol: "brain.head.profile")
            }
            return "Saved."
        }
    }

    struct Reminder: Tool {
        let name = "createReminder"
        let description = "Add a reminder to the Reminders app, with an optional time, e.g. 'call Sam at 5pm'."
        @Generable struct Arguments {
            @Guide(description: "What to be reminded about, including when if given") var text: String
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("createReminder(\(arguments.text))") }
            guard let draft = RemindersService.parse("remind me to " + arguments.text) ?? RemindersService.parse(arguments.text) else {
                return "I couldn't understand that reminder."
            }
            await MainActor.run {
                RemindersService.shared.create(draft) { ok in
                    BrainAgent.shared.noteAction(ok ? "Reminder: \(draft.title)" : "Couldn't add the reminder", symbol: ok ? "checklist" : "exclamationmark.triangle")
                }
            }
            return "Reminder added."
        }
    }

    struct JoinMeeting: Tool {
        let name = "joinNextMeeting"
        let description = "Join the user's next or current video meeting."
        @Generable struct Arguments {}
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("joinNextMeeting()") }
            return await MainActor.run {
                guard let e = CalendarModel.shared.events.first(where: { !$0.isAllDay && $0.end > Date() && $0.meetingURL != nil }),
                      let url = e.meetingURL else { return "There's no meeting with a video link coming up." }
                BrainEngine.shared.perform(.joinMeeting(url))
                BrainAgent.shared.noteAction("Joining \(e.title)", symbol: "video.fill")
                return "Joining \(e.title)."
            }
        }
    }

    struct AddToPlan: Tool {
        let name = "addToPlan"
        let description = "Add a meeting or a focus task to today's plan at a time, e.g. 'call with Sam at 4pm for 30 minutes'."
        @Generable enum Kind { case meeting, focus }
        @Generable struct Arguments {
            @Guide(description: "What it is, with its time and length, e.g. 'Call with Sam at 4pm for 30m'") var text: String
            var kind: Kind
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("addToPlan(\(arguments.text), \(arguments.kind))") }
            return await MainActor.run {
                guard var item = PlanScheduler.parseMeeting(arguments.text) else { return "I need a time for that, like 4pm." }
                if arguments.kind == .focus { item.kind = .focus }
                PlanStore.shared.add(item)
                BrainAgent.shared.noteAction("Added \(item.title) at \(item.start.formatted(date: .omitted, time: .shortened))", symbol: "calendar.badge.plus")
                return "Added to today's plan."
            }
        }
    }

    struct OpenPlan: Tool {
        let name = "openDayPlanner"
        let description = "Open the day planner in the notch, to plan or replan today."
        @Generable struct Arguments {}
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("openDayPlanner()") }
            await MainActor.run { IslandManager.shared.openPlan() }
            return "Opened the planner."
        }
    }

    struct SetRoom: Tool {
        let name = "setRoom"
        let description = "Set up the Mac for a piece of work: reopen its documents, hide other apps, play its music, start a focus timer."
        @Generable struct Arguments {
            @Guide(description: "The work, e.g. 'Write the launch post' or a project name") var work: String
            @Guide(description: "Minutes of focus", .range(5...180)) var minutes: Int
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("setRoom(\(arguments.work), \(arguments.minutes))") }
            return await MainActor.run {
                let had = RoomStore.shared.room(for: arguments.work)
                RoomStore.shared.setRoom(title: arguments.work, minutes: arguments.minutes)
                BrainAgent.shared.noteAction(had == nil ? "Started \(arguments.minutes) min on \(arguments.work) — I'll save its room at the end"
                                                        : "Set the room for \(arguments.work) · \(had!.summary)", symbol: "rectangle.3.group.fill")
                return had == nil ? "No saved room yet; started the timer and will remember the setup when it ends." : "Room set."
            }
        }
    }

    struct Resume: Tool {
        let name = "resume"
        let description = "Pick a project back up exactly where the user left it: its apps, documents and music."
        @Generable struct Arguments {
            @Guide(description: "Project name") var project: String
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("resume(\(arguments.project))") }
            return await MainActor.run {
                guard let room = RoomStore.shared.room(for: arguments.project) else { return "I don't have a saved room for \(arguments.project) yet." }
                RoomStore.shared.restore(room, hideOthers: Prefs.shared.roomHidesOthers)
                BrainAgent.shared.noteAction("Back to \(room.title) · \(room.summary)", symbol: "arrow.uturn.forward")
                return "Reopened \(room.title)."
            }
        }
    }

    struct Recall: Tool {
        let name = "recall"
        let description = "Say what the user was doing at a time earlier today, and open Rewind at that moment."
        @Generable struct Arguments {
            @Guide(description: "The time, e.g. '3pm', '10:30', 'an hour ago'") var time: String
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("recall(\(arguments.time))") }
            return await MainActor.run {
                guard let when = Recall.time(arguments.time) else { return "I didn't understand that time." }
                let rewind = RewindModel.shared
                rewind.load(at: when)
                guard let m = rewind.current else { return "I don't have a record of that time." }
                IslandManager.shared.primary?.model.open(.rewind)
                return RewindModel.describe(m)
            }
        }

        static func time(_ text: String) -> Date? {
            let lower = text.lowercased()
            if let m = try? NSRegularExpression(pattern: #"(\d+|an?)\s*(hour|hr|minute|min)s?\s+ago"#).firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
               let nr = Range(m.range(at: 1), in: lower), let ur = Range(m.range(at: 2), in: lower) {
                let n = Double(lower[nr]) ?? 1
                return Date().addingTimeInterval(-n * (lower[ur].hasPrefix("h") ? 3600 : 60))
            }
            if let item = PlanScheduler.parseMeeting("x " + text) { return item.start }
            return (try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue))?
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date
        }
    }

    struct ShowDay: Tool {
        let name = "showDay"
        let description = "Show the user their day, drawn: focus, meetings and music as a picture."
        @Generable struct Arguments {}
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("showDay()") }
            await MainActor.run { IslandManager.shared.primary?.model.open(.day) }
            return "Showing their day."
        }
    }

    struct MoveEvent: Tool {
        let name = "moveEvent"
        let description = "Move an event on the user's calendar, e.g. their 3 o'clock to tomorrow. Keeps its length."
        @Generable struct Arguments {
            @Guide(description: "Which event: its time ('3pm', '3 o'clock') or words from its title") var which: String
            @Guide(description: "When to: 'tomorrow', '4pm', 'tomorrow at 10'") var to: String
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("moveEvent(\(arguments.which), \(arguments.to))") }
            return await MainActor.run {
                let result = CalendarModel.shared.move(arguments.which, to: arguments.to)
                BrainAgent.shared.noteAction(result, symbol: result.hasPrefix("Moved") ? "calendar" : "exclamationmark.triangle")
                return result
            }
        }
    }

    struct TakeNotes: Tool {
        let name = "meetingNotes"
        let description = "Start or stop taking notes for the current meeting (transcribed on this Mac, written up at the end)."
        @Generable struct Arguments { var start: Bool }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("meetingNotes(\(arguments.start))") }
            return await MainActor.run {
                let c = MeetingCompanion.shared
                if arguments.start { c.begin(); BrainAgent.shared.noteAction("Taking notes — tell everyone", symbol: "waveform.badge.mic") }
                else { c.stop(); BrainAgent.shared.noteAction("Stopped notes — writing them up", symbol: "list.bullet.clipboard") }
                return arguments.start ? "Notes started. Remind the user to tell the others." : "Notes stopped; they'll be written up."
            }
        }
    }

    struct SearchMemory: Tool {
        let name = "searchMemory"
        let description = "Search the user's past days by meaning: what they worked on and when, meetings and what was decided, things they told you. Use for 'when did I last…', 'what did we decide about…'."
        @Generable struct Arguments {
            @Guide(description: "What to look for, in a few words") var query: String
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("searchMemory(\(arguments.query))") }
            let hits = await Memory.shared.recall(arguments.query, limit: 8)
            await MainActor.run { BrainAgent.shared.noteAction("Looked through your history for “\(arguments.query)”", symbol: "brain.head.profile") }
            return hits.isEmpty ? "Nothing in memory matches that." : Memory.lines(hits)
        }
    }

    struct ReadPage: Tool {
        let name = "readPage"
        let description = "Do something with the web page open in the user's browser: summarize it, explain it simply, or save it as study cards."
        @Generable enum Action { case summarize, explain, saveToLearn }
        @Generable struct Arguments { var action: Action }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("readPage(\(arguments.action))") }
            await MainActor.run {
                switch arguments.action {
                case .summarize: PageActions.perform(.summarize)
                case .explain: PageActions.perform(.explain)
                case .saveToLearn: PageActions.perform(.learn)
                }
            }
            return "Reading the page now."
        }
    }

    struct News: Tool {
        let name = "news"
        let description = "The latest headlines from the user's chosen news sources, ranked by their interests; optionally about a topic."
        @Generable struct Arguments {
            @Guide(description: "A topic to focus on, or empty for the top of the news") var topic: String
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("news(\(arguments.topic))") }
            let items = await MainActor.run { () -> [NewsItem] in
                NewsStore.shared.refresh()
                let topic = arguments.topic.lowercased()
                let all = NewsStore.shared.brief
                let matching = topic.isEmpty ? all : all.filter { ($0.title + " " + $0.summary).lowercased().contains(topic) }
                return Array((matching.isEmpty ? all : matching).prefix(6))
            }
            guard !items.isEmpty else { return "No headlines yet — the Brief may be off, or still loading." }
            return items.map { "- \($0.title) (\($0.source))" }.joined(separator: "\n")
        }
    }

    struct HandToClaude: Tool {
        let name = "handToClaude"
        let description = "Ask Claude a question that needs deep knowledge, coding or careful writing. The answer appears in the notch."
        @Generable struct Arguments {
            @Guide(description: "The full question for Claude") var prompt: String
        }
        func call(arguments: Arguments) async throws -> String {
            if BrainAgent.dryRun { return await dry("handToClaude(\(arguments.prompt))") }
            await MainActor.run {
                BrainAgent.shared.noteAction("Asked Claude", symbol: "asterisk")
                IslandManager.shared.openSearch()
                SearchModel.shared.activate(.ask(prompt: arguments.prompt, title: arguments.prompt))
            }
            return "Claude is answering in the notch."
        }
    }
}
#endif
