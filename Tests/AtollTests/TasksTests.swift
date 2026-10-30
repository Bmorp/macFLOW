import Testing
import Foundation
import AppKit
@testable import Atoll

/// A fixed week for every task test: Wednesday 4 November 2026, 10:00, UTC.
enum TaskClock {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    static func at(_ month: Int, _ day: Int, _ h: Int = 0, _ m: Int = 0, year: Int = 2026) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: h, minute: m))!
    }
    static let now = at(11, 4, 10)
    static func parse(_ s: String) -> TaskDraft { TaskParser.parse(s, now: now, calendar: cal) }
}

@Suite("Task capture: the parser")
struct TaskParserTests {
    typealias C = TaskClock

    @Test func theWholeLine() {
        let d = C.parse("review deck tomorrow 3pm 45m #launch !high")
        #expect(d.title == "Review deck")
        #expect(d.scheduled == C.at(11, 5, 15))
        #expect(d.due == nil)
        #expect(d.estimate == 45)
        #expect(d.project == "launch")
        #expect(d.priority == .high)
    }

    @Test func repeats() {
        let monday = C.parse("call mom every Monday")
        #expect(monday.title == "Call mom")
        #expect(monday.repeats == .weekly([2]))
        #expect(monday.scheduled == C.at(11, 9))
        #expect(C.parse("standup every weekday 9:30").repeats == .weekdays)
        let plants = C.parse("water plants weekly")
        #expect(plants.title == "Water plants")
        #expect(plants.repeats == .weekly([4]))                // today's weekday
        #expect(plants.scheduled == C.at(11, 4))
        let review = C.parse("Weekly review every friday 4pm 1h")
        #expect(review.title == "Weekly review")                // a first-word adverb is the title's
        #expect(review.repeats == .weekly([6]))
        #expect(review.scheduled == C.at(11, 6, 16))
        #expect(review.estimate == 60)
        #expect(C.parse("pay rent every 1st").repeats == .monthly(1))
        #expect(C.parse("gym every mon and thu").repeats == .weekly([2, 5]))
    }

    @Test func deadlines() {
        let d = C.parse("send invoice by Friday")
        #expect(d.title == "Send invoice")
        #expect(d.due == C.at(11, 6))
        #expect(d.scheduled == nil)
        let timed = C.parse("submit report by friday 5pm")
        #expect(timed.title == "Submit report")
        #expect(timed.due == C.at(11, 6, 17))
        #expect(timed.scheduled == nil)
        let both = C.parse("review deck tomorrow 3pm by friday")
        #expect(both.scheduled == C.at(11, 5, 15))
        #expect(both.due == C.at(11, 6))
        #expect(C.parse("file taxes due next month").due == C.at(12, 1))
        #expect(C.parse("ship it by 5pm").due == C.at(11, 4, 17))
    }

    @Test func relativeTimes() {
        #expect(C.parse("stretch in 2 hours").scheduled == C.at(11, 4, 12))
        #expect(C.parse("stretch in 2 hours").title == "Stretch")
        #expect(C.parse("tea in 30 min").scheduled == C.at(11, 4, 10, 30))
        #expect(C.parse("follow up in 3 days").scheduled == C.at(11, 7))
        #expect(C.parse("check back in two weeks").scheduled == C.at(11, 18))
        #expect(C.parse("plan offsite next week").scheduled == C.at(11, 9))
        #expect(C.parse("plan offsite next week").title == "Plan offsite")
        #expect(C.parse("budget next month").scheduled == C.at(12, 1))
        #expect(C.parse("tidy up this weekend").scheduled == C.at(11, 7))
        #expect(C.parse("wrap up end of month").scheduled == C.at(11, 30))
    }

    @Test func weekdays() {
        // Today is Wednesday 4 November.
        #expect(C.parse("dentist friday").scheduled == C.at(11, 6))
        #expect(C.parse("dentist this friday").scheduled == C.at(11, 6))
        #expect(C.parse("dentist next friday").scheduled == C.at(11, 13))
        #expect(C.parse("sync this wednesday").scheduled == C.at(11, 4))
        #expect(C.parse("sync wednesday").scheduled == C.at(11, 11))     // a bare weekday is the next one
        #expect(C.parse("sync next monday").scheduled == C.at(11, 9))
        #expect(C.parse("hike on sat").scheduled == C.at(11, 7))
        #expect(C.parse("standup mon").scheduled == C.at(11, 9))
        let sun = C.parse("enjoy the sun")                                 // "sun" alone is a word
        #expect(sun.title == "Enjoy the sun")
        #expect(sun.scheduled == nil)
        #expect(C.parse("call tomorrow morning").scheduled == C.at(11, 5, 9))
        #expect(C.parse("email Sam tonight").scheduled == C.at(11, 4, 19))
        #expect(C.parse("day after tomorrow").scheduled == C.at(11, 6))
    }

    @Test func calendarDates() {
        #expect(C.parse("dinner nov 20 7pm").scheduled == C.at(11, 20, 19))
        #expect(C.parse("renew passport 3 jan").scheduled == C.at(1, 3, year: 2027))   // gone this year: next year's
        #expect(C.parse("pay rent on the 1st").scheduled == C.at(12, 1))
        #expect(C.parse("launch 2027-02-14").scheduled == C.at(2, 14, year: 2027))
        #expect(C.parse("renew passport 3 jan").title == "Renew passport")
    }

    @Test func times() {
        let four = C.parse("meet Sam at 4")
        #expect(four.title == "Meet Sam")
        #expect(four.scheduled == C.at(11, 4, 16))               // a workday hour means the afternoon
        #expect(C.parse("call Sam at 9am").scheduled == C.at(11, 5, 9))   // already past today: tomorrow
        #expect(C.parse("lunch at noon").scheduled == C.at(11, 4, 12))
        #expect(C.parse("lunch at noon").title == "Lunch")
        #expect(C.parse("standup 10:30").scheduled == C.at(11, 4, 10, 30))
        #expect(C.parse("1:1 with Priya").scheduled == nil)      // not a time
    }

    @Test func durations() {
        #expect(C.parse("write spec 1h30").estimate == 90)
        #expect(C.parse("deep work 1.5h").estimate == 90)
        #expect(C.parse("review 1h 30m").estimate == 90)
        #expect(C.parse("call 90 min").estimate == 90)
        #expect(C.parse("read 2 hours").estimate == 120)
        let hour = C.parse("workout for an hour")
        #expect(hour.estimate == 60)
        #expect(hour.title == "Workout")
        #expect(C.parse("nap half an hour").estimate == 30)
        #expect(C.parse("deck 1h 30 slides").estimate == 60)     // "30 slides" isn't minutes
    }

    @Test func priorityMarks() {
        #expect(C.parse("taxes !!!").priority == .high)
        #expect(C.parse("taxes !!").priority == .medium)
        #expect(C.parse("taxes !").priority == .low)
        #expect(C.parse("!low tidy desk").priority == .low)
        #expect(C.parse("fix crash p1").priority == .high)
        let excited = C.parse("ship it!")
        #expect(excited.priority == TaskPriority.none)
        #expect(excited.title == "Ship it!")
    }

    @Test func projectsAndTitles() {
        let issue = C.parse("fix bug #123")
        #expect(issue.project == nil)
        #expect(issue.title == "Fix bug #123")
        let home = C.parse("#home buy milk")
        #expect(home.project == "home")
        #expect(home.title == "Buy milk")
        // Words that look like dates or lengths but aren't stay put.
        #expect(C.parse("read chapter 5").title == "Read chapter 5")
        #expect(C.parse("buy 3 apples").title == "Buy 3 apples")
        #expect(C.parse("check in").title == "Check in")
        #expect(C.parse("log in to the portal").title == "Log in to the portal")
        #expect(C.parse("read chapter 5").hasDetails == false)
        let someday = C.parse("learn piano someday")
        #expect(someday.someday)
        #expect(someday.title == "Learn piano")
        #expect(C.parse("").isEmpty)
        #expect(C.parse("tomorrow").isEmpty)
        #expect(C.parse("tomorrow").scheduled == C.at(11, 5))
    }

    @Test func previewWords() {
        let parts = TaskFormat.parts(of: C.parse("review deck tomorrow 45m #launch"), now: C.now)
        #expect(parts.count == 3)
        #expect(parts.contains("45m"))
        #expect(parts.contains("#launch"))
        #expect(TaskFormat.length(90) == "1h 30m")
        #expect(TaskFormat.length(45) == "45m")
    }
}

// MARK: - The store

@MainActor
func makeStore(_ database: TaskDatabase? = nil) -> TaskStore {
    let s = TaskStore(database: database)
    s.clock = { TaskClock.now }
    s.calendar = TaskClock.cal
    return s
}

@MainActor
final class EventLog {
    private(set) var events: [String] = []
    private var sub: Any?
    init(_ ids: @escaping () -> Set<UUID>) {
        sub = TaskEvents.stream.sink { [weak self] e in
            let (name, id): (String, UUID) = switch e {
            case .added(let t): ("added", t.id)
            case .updated(let t): ("updated", t.id)
            case .started(let t): ("started", t.id)
            case .paused(let t, let f): ("paused:\(Int(f))", t.id)
            case .completed(let t): ("completed", t.id)
            case .reopened(let t): ("reopened", t.id)
            case .deleted(let id): ("deleted", id)
            }
            if ids().contains(id) || name == "deleted" { self?.events.append(name) }
        }
    }
}

@Suite("Flow Tasks: the store") @MainActor
struct TaskStoreTests {
    typealias C = TaskClock

    @Test func roundTripsThroughSQLite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        let a = makeStore(TaskDatabase(url: url))
        let t = try #require(a.add(C.parse("review deck tomorrow 3pm 45m #launch !high every friday"), source: .search, context: "From a test",
                                   notes: "Slides 4–9"))
        a.update(t.id) { $0.reminderID = "r-1" }
        a.complete(try #require(a.add(C.parse("ship it"), source: .typed)).id)
        a.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        let b = makeStore(TaskDatabase(url: url))
        #expect(b.tasks.count == 2)
        let back = try #require(b.task(id: t.id))
        let original = try #require(a.task(id: t.id))
        #expect(back == original)
        #expect(back.project == "launch")
        #expect(back.notes == "Slides 4–9")
        #expect(back.repeats == .weekly([6]))
        #expect(back.reminderID == "r-1")
        #expect(back.estimateIsUser)
        #expect(b.projects.map(\.name) == ["launch"])
        #expect(b.tasks.filter(\.isDone).count == 1)
    }

    @Test func publishesEveryChange() throws {
        let s = makeStore()
        let log = EventLog { Set(s.tasks.map(\.id)) }
        let t = try #require(s.add(C.parse("write the spec"), source: .typed))
        s.update(t.id) { $0.title = "Write the spec v2" }
        s.complete(t.id)
        s.reopen(t.id)
        s.update(t.id) { $0.title = "Write the spec v2" }        // no change, no event
        s.delete(t.id)
        #expect(log.events == ["added", "updated", "completed", "reopened", "deleted"])
    }

    @Test func stampsOnlyWhatChanged() throws {
        let s = makeStore()
        let t = try #require(s.add(C.parse("draft"), source: .typed))
        let later = C.now.addingTimeInterval(600)
        s.clock = { later }
        s.update(t.id) { $0.title = "Draft the post"; $0.priority = .high }
        let u = try #require(s.task(id: t.id))
        #expect(u.stamps[.title] == later)
        #expect(u.stamps[.priority] == later)
        #expect(u.stamps[.due] == C.now)
        s.clock = { later.addingTimeInterval(60) }
        s.update(t.id) { $0.notes = "x" }
        #expect(s.task(id: t.id)?.stamps[.title] == later)
    }

    @Test func listsAndSections() throws {
        let s = makeStore()
        let today = try #require(s.add(C.parse("standup notes"), source: .typed, in: .today))
        let overdue = try #require(s.add(TaskDraft(title: "Expenses", due: C.at(11, 2)), source: .typed))
        let fri = try #require(s.add(C.parse("dentist friday 3pm"), source: .typed))
        let fri2 = try #require(s.add(C.parse("buy flowers friday"), source: .typed))
        let anytime = try #require(s.add(C.parse("read a book"), source: .typed))
        let parked = try #require(s.add(C.parse("learn piano someday"), source: .typed))
        #expect(s.list(.today).map(\.id) == [today.id, overdue.id])
        #expect(s.list(.someday).map(\.id) == [parked.id])
        let sections = s.sections(.upcoming)
        #expect(sections.map(\.title) == ["Friday", "Anytime"])
        #expect(sections.first?.tasks.map(\.id) == [fri.id, fri2.id])   // timed first
        #expect(sections.last?.tasks.map(\.id) == [anytime.id])
        #expect(s.task(id: today.id)?.scheduled == C.at(11, 4))    // typed in Today: for today
        #expect(s.task(id: overdue.id)?.isOverdue(at: C.now, calendar: C.cal) == true)
    }

    @Test func reordersWithOneWrite() throws {
        let s = makeStore()
        let ids = try ["a", "b", "c", "d"].map { try #require(s.add(C.parse($0), source: .typed, in: .today)).id }
        s.move(ids[3], to: 0, in: ids)
        #expect(s.list(.today).map(\.title) == ["D", "A", "B", "C"])
        s.move(ids[3], to: 2, in: s.list(.today).map(\.id))
        #expect(s.list(.today).map(\.title) == ["A", "B", "D", "C"])
        s.move(ids[0], to: 4, in: s.list(.today).map(\.id))
        #expect(s.list(.today).map(\.title) == ["B", "D", "C", "A"])
    }

    @Test func completingARepeatBringsTheNextOne() throws {
        let s = makeStore()
        let t = try #require(s.add(C.parse("water plants every monday 9am"), source: .typed))
        #expect(t.scheduled == C.at(11, 9, 9))
        s.complete(t.id)
        let next = try #require(s.tasks.first { $0.isOpen && $0.title == "Water plants" })
        #expect(next.scheduled == C.at(11, 16, 9))
        #expect(next.repeats == .weekly([2]))
        #expect(s.task(id: t.id)?.repeats == nil)                 // reopening the old one won't spawn another
    }

    @Test func undoesADelete() throws {
        let s = makeStore()
        let t = try #require(s.add(C.parse("call Sam"), source: .typed))
        s.update(t.id) { $0.reminderID = "r-9" }
        let gone = try #require(s.delete(t.id))
        #expect(s.tombstones["r-9"] != nil)
        s.restore(gone)
        #expect(s.task(id: t.id)?.reminderID == "r-9")
        #expect(s.tombstones.isEmpty)                             // Reminders never hears of it
    }

    @Test func ledgerForTheBrain() throws {
        let s = makeStore()
        let snap = try #require(s.capture("review deck tomorrow 3pm 45m", source: .voice))
        #expect(snap.title == "Review deck")
        #expect(snap.estimate == 45)
        #expect(snap.source == .voice)
        let mine = try #require(s.capture("tidy inbox", source: .flow))
        s.suggestEstimate(mine.id, minutes: 20)
        s.suggestEstimate(snap.id, minutes: 90)                   // the user's 45 stays
        #expect(s.task(snap.id)?.estimate == 45)
        #expect(s.task(mine.id)?.estimate == 20)
        s.complete(mine.id)
        #expect(s.openTasks().map(\.id) == [snap.id])
    }

    @Test func focusTimeIsCountedAndPublished() throws {
        let s = makeStore()
        let log = EventLog { Set(s.tasks.map(\.id)) }
        let t = try #require(s.add(C.parse("write"), source: .typed))
        s.beginFocus(t.id)
        #expect(s.task(id: t.id)?.status == .active)
        #expect(s.active.task?.id == t.id)
        s.clock = { C.now.addingTimeInterval(25 * 60) }
        #expect(s.active.elapsed(at: s.now) == TimeInterval(25 * 60))
        s.endFocus()
        #expect(s.task(id: t.id)?.actual == TimeInterval(25 * 60))
        #expect(s.task(id: t.id)?.status == .open)
        #expect(s.active.task == nil)
        #expect(log.events.contains("started"))
        #expect(log.events.contains("paused:1500"))
    }

    @Test func rankingForTheMorning() throws {
        let s = makeStore()
        let backlog = try #require(s.add(C.parse("backlog thing"), source: .typed))
        let important = try #require(s.add(C.parse("important thing !!!"), source: .typed))
        let carried = try #require(s.add(TaskDraft(title: "Yesterday’s thing", scheduled: C.at(11, 3)), source: .plan))
        let dueToday = try #require(s.add(C.parse("file report by today"), source: .typed))
        let overdue = try #require(s.add(TaskDraft(title: "Late thing", due: C.at(11, 1)), source: .typed))
        _ = try #require(s.add(C.parse("next week thing next week"), source: .typed))
        _ = try #require(s.add(C.parse("someday thing someday"), source: .typed))
        let picks = TaskRanking.rank(s.tasks, now: C.now, calendar: C.cal)
        #expect(picks.map(\.task.id) == [overdue.id, dueToday.id, carried.id, important.id, backlog.id])
        #expect(Array(picks.map(\.reason).prefix(3)) == ["Overdue", "Due today", "Unfinished yesterday"])
        // What the Brain learned outranks the priority marks within a tier.
        let learned = TaskRanking.rank(s.tasks, now: C.now, calendar: C.cal) { $0.id == backlog.id ? 0.9 : 0.5 }
        #expect(Array(learned.map(\.task.id).suffix(2)) == [backlog.id, important.id])
    }
}

// MARK: - Carry-over and the plan

@Suite("Flow Tasks: carry-over and the plan") @MainActor
struct TaskPlanTests {
    typealias C = TaskClock

    @Test func carriesEveryItemNotJustSix() {
        let s = makeStore()
        let items = (1...8).map { "Action item \($0)" } + ["Send the deck to Sam by Friday"]
        s.carry(items, context: "From Design Review", source: .meeting, to: C.at(11, 5))
        #expect(s.tasks.count == 9)
        #expect(s.tasks.allSatisfy { $0.source == .meeting && $0.context == "From Design Review" })
        let deck = s.tasks.first { $0.title == "Send the deck to Sam" }
        #expect(deck?.due == C.at(11, 6))                          // its deadline survives
        #expect(deck?.scheduled == C.at(11, 5))
        // Carried again (Add to Tomorrow pressed twice): no duplicates.
        s.carry(items, context: "From Design Review", source: .meeting, to: C.at(11, 5))
        #expect(s.tasks.count == 9)
        // The next morning they're all in Today; planning three of them loses none of the rest.
        s.clock = { C.at(11, 5, 8) }
        #expect(s.list(.today).count == 9)
        for pick in s.ranked().prefix(3) { s.plan(pick.task.title, task: pick.task.id, at: C.at(11, 5, 10), minutes: 45, context: nil) }
        #expect(s.list(.today).count == 9)
        #expect(s.tasks.count == 9)
    }

    @Test func unfinishedWorkRollsForward() throws {
        let s = makeStore()
        let t = try #require(s.add(TaskDraft(title: "Pricing page", scheduled: C.at(11, 3, 14)), source: .plan))
        let done = try #require(s.add(TaskDraft(title: "Done thing", scheduled: C.at(11, 3, 9)), source: .plan))
        s.complete(done.id)
        s.rollForward([t.id, done.id], to: C.at(11, 4), context: "Unfinished yesterday")
        #expect(s.task(id: t.id)?.scheduled == C.at(11, 4))
        #expect(s.task(id: t.id)?.context == "Unfinished yesterday")
        #expect(s.task(id: done.id)?.scheduled == C.at(11, 3, 9))   // finished work stays where it was
    }

    @Test func planningLinksOrMakesTasks() throws {
        let s = makeStore()
        let t = try #require(s.add(C.parse("write the launch post"), source: .typed))
        let linked = s.plan("Write the launch post", task: t.id, at: C.at(11, 4, 10, 40), minutes: 90, context: nil)
        #expect(linked == t.id)
        #expect(s.task(id: t.id)?.scheduled == C.at(11, 4, 10, 40))
        #expect(s.task(id: t.id)?.estimate == 90)
        let made = try #require(s.plan("Inbox zero", task: nil, at: C.at(11, 4, 15), minutes: 30, context: nil))
        #expect(s.task(id: made)?.source == .plan)
        #expect(s.list(.today).map(\.id).contains(made))
    }

    @Test func wrapUpSaysWhatsLeft() {
        var plan = DayPlan(day: "2026-11-04")
        plan.items = [PlanItem(title: "A", kind: .focus, start: C.at(11, 4, 9), minutes: 30, done: true),
                      PlanItem(title: "B", kind: .focus, start: C.at(11, 4, 10), minutes: 30)]
        #expect(DayGuide.wrapUp(plan: plan, left: []) == "1 of 2 priorities done — see how it went")
        let line = DayGuide.wrapUp(plan: plan, left: ["B", "Inbox zero", "Call Sam"])
        #expect(line.contains("“B”, “Inbox zero” +1"))
    }
}

// MARK: - Reminders sync

/// Reminders, as a dictionary: what a sync round sees, and what an iPhone edit changes.
final class FakeReminders: ReminderBackend {
    var items: [String: RemoteReminder] = [:]
    /// Moved to another list or finished long ago: found by identifier, not in the list.
    var elsewhere: [String: RemoteReminder] = [:]
    var clock = TaskClock.now
    private var next = 1
    var failReads = false

    func fetch() -> [RemoteReminder]? { failReads ? nil : Array(items.values) }
    func lookup(_ id: String) -> RemoteReminder? { items[id] ?? elsewhere[id] }
    func create(_ fields: ReminderFields) -> RemoteReminder? {
        let r = RemoteReminder(id: "r\(next)", fields: fields, modified: clock, completedAt: fields.completed ? clock : nil)
        next += 1
        items[r.id] = r
        return r
    }
    func update(_ id: String, to fields: ReminderFields, only: Set<ReminderField>) -> RemoteReminder? {
        guard var r = items[id] ?? elsewhere[id] else { return nil }
        for f in only { r.fields.take(f, from: fields) }
        r.modified = clock
        if items[id] != nil { items[id] = r } else { elsewhere[id] = r }
        return r
    }
    func delete(_ id: String) -> Bool { items[id] = nil; elsewhere[id] = nil; return true }
    func commit() -> Bool { true }

    /// A change made on the iPhone.
    func edit(_ id: String, at date: Date, _ change: (inout ReminderFields) -> Void) {
        guard var r = items[id] else { return }
        change(&r.fields)
        r.modified = date
        if r.fields.completed { r.completedAt = date }
        items[id] = r
    }
    func add(_ title: String, completed: Bool = false, date: Date? = nil) -> String {
        create(ReminderFields(title: title, notes: "", date: date, priority: .none, completed: completed))!.id
    }
    func titles() -> [String] { items.values.map(\.fields.title).sorted() }
}

@MainActor
func sync(_ store: TaskStore, _ remote: FakeReminders) {
    let s = store.syncState()
    store.applySync(ReminderMerge.round(remote, locals: s.locals, tombstones: s.tombstones, now: store.now), readAt: s.revisions)
}

@Suite("Flow Tasks: Reminders sync") @MainActor
struct ReminderSyncTests {
    typealias C = TaskClock
    let base = ReminderFields(title: "Deck", notes: "", date: nil, priority: .none, completed: false)

    @Test func mergeIsPerFieldLastEditWins() {
        var local = base, remote = base
        local.title = "Deck v2"                                    // changed here
        remote.date = C.at(11, 6)                                  // changed on the phone
        let both = ReminderMerge.merge(local: local, stamps: [.title: C.now], base: base, remote: remote, remoteModified: C.now)
        #expect(both.fields.title == "Deck v2")
        #expect(both.fields.date == C.at(11, 6))
        #expect(both.pull == [.date])
        #expect(both.push)
        // The same field on both sides: the later edit wins, whichever side it's on.
        local = base; remote = base
        local.title = "Mine"; remote.title = "Theirs"
        let theirs = ReminderMerge.merge(local: local, stamps: [.title: C.now], base: base, remote: remote, remoteModified: C.now.addingTimeInterval(60))
        #expect(theirs.fields.title == "Theirs")
        #expect(!theirs.push)
        let mine = ReminderMerge.merge(local: local, stamps: [.title: C.now.addingTimeInterval(120)], base: base, remote: remote,
                                       remoteModified: C.now.addingTimeInterval(60))
        #expect(mine.fields.title == "Mine")
        #expect(mine.pull.isEmpty)
        // Reminders keeps minutes, not seconds: the same date isn't a change.
        local = base; remote = base
        local.date = C.at(11, 6, 15).addingTimeInterval(12); remote.date = C.at(11, 6, 15)
        let same = ReminderMerge.merge(local: local, stamps: [:], base: nil, remote: remote, remoteModified: nil)
        #expect(!same.push && same.pull.isEmpty)
    }

    @Test func firstSyncMakesNoDuplicates() throws {
        let s = makeStore()
        let remote = FakeReminders()
        _ = remote.add("call sam")                                 // already in Reminders, typed differently
        _ = remote.add("Pick up dry cleaning")
        _ = remote.add("Old finished thing", completed: true)
        let call = try #require(s.add(C.parse("Call Sam"), source: .typed))
        _ = try #require(s.add(C.parse("Write the spec"), source: .typed))
        let finished = try #require(s.add(C.parse("Ancient history"), source: .typed))
        s.update(finished.id) { $0.status = .done; $0.completed = C.now.addingTimeInterval(-10 * 86_400) }
        sync(s, remote)
        // Linked, not duplicated; with no history between them, this Mac's spelling wins the tie.
        #expect(remote.titles() == ["Call Sam", "Old finished thing", "Pick up dry cleaning", "Write the spec"])
        #expect(Set(s.tasks.filter(\.isOpen).map(\.title)) == ["Call Sam", "Write the spec", "Pick up dry cleaning"])
        #expect(s.task(id: call.id)?.reminderID != nil)
        // Nothing changes on a second round.
        let before = (remote.items, s.tasks.count)
        sync(s, remote)
        #expect(remote.items == before.0)
        #expect(s.tasks.count == before.1)
    }

    @Test func editsTravelBothWays() throws {
        let s = makeStore()
        let remote = FakeReminders()
        let t = try #require(s.add(C.parse("review deck tomorrow 3pm !!"), source: .typed))
        sync(s, remote)
        let rid = try #require(s.task(id: t.id)?.reminderID)
        #expect(remote.items[rid]?.fields.date == C.at(11, 5, 15))
        #expect(remote.items[rid]?.fields.priority == .medium)
        // Here: a new title. On the phone, a minute later: a new time.
        s.clock = { C.now.addingTimeInterval(60) }
        s.update(t.id) { $0.title = "Review the deck" }
        remote.edit(rid, at: C.now.addingTimeInterval(120)) { $0.date = C.at(11, 5, 16) }
        sync(s, remote)
        #expect(s.task(id: t.id)?.title == "Review the deck")
        #expect(s.task(id: t.id)?.scheduled == C.at(11, 5, 16))
        #expect(remote.items[rid]?.fields.title == "Review the deck")
        // Done on the Watch: done here, with an event for the Brain.
        let log = EventLog { [t.id] }
        remote.edit(rid, at: C.now.addingTimeInterval(300)) { $0.completed = true }
        sync(s, remote)
        #expect(s.task(id: t.id)?.isDone == true)
        #expect(log.events == ["completed"])
        // Reopened here: open there.
        s.clock = { C.now.addingTimeInterval(400) }
        s.reopen(t.id)
        sync(s, remote)
        #expect(remote.items[rid]?.fields.completed == false)
    }

    @Test func deletionsTravelBothWays() throws {
        let s = makeStore()
        let remote = FakeReminders()
        let a = try #require(s.add(C.parse("A thing"), source: .typed))
        let b = try #require(s.add(C.parse("B thing"), source: .typed))
        sync(s, remote)
        let ra = try #require(s.task(id: a.id)?.reminderID)
        let rb = try #require(s.task(id: b.id)?.reminderID)
        s.delete(a.id)
        sync(s, remote)
        #expect(remote.items[ra] == nil)
        #expect(s.tombstones.isEmpty)
        remote.items[rb] = nil                                     // deleted on the iPhone
        sync(s, remote)
        #expect(s.task(id: b.id) == nil)
        #expect(s.tasks.isEmpty)
    }

    @Test func aFailedReadDeletesNothing() {
        let s = makeStore()
        let remote = FakeReminders()
        for n in 1...6 { _ = s.add(C.parse("Task \(n)"), source: .typed) }
        sync(s, remote)
        remote.failReads = true
        sync(s, remote)
        #expect(s.tasks.count == 6)
        // The whole list vanishing at once is a reset, not six deletions: the tasks go back up.
        remote.failReads = false
        remote.items = [:]
        sync(s, remote)
        #expect(s.tasks.count == 6)
        sync(s, remote)
        #expect(remote.items.count == 6)
    }

    @Test func followsAReminderThatMovedOrFinished() throws {
        let s = makeStore()
        let remote = FakeReminders()
        let t = try #require(s.add(C.parse("Moved thing"), source: .typed))
        sync(s, remote)
        let rid = try #require(s.task(id: t.id)?.reminderID)
        remote.elsewhere[rid] = remote.items.removeValue(forKey: rid)   // dragged to another list on the iPhone
        s.clock = { C.now.addingTimeInterval(60) }
        s.update(t.id) { $0.title = "Moved thing, renamed" }
        sync(s, remote)
        #expect(s.task(id: t.id) != nil)
        #expect(remote.elsewhere[rid]?.fields.title == "Moved thing, renamed")
    }
}

// MARK: - Capture everywhere

@Suite("Flow Tasks: capture") @MainActor
struct TaskCaptureTests {
    typealias C = TaskClock

    @Test func searchCommands() throws {
        let c = try #require(TaskCapture.command("t review deck tomorrow 3pm 45m #launch", now: C.now))
        #expect(c.draft.title == "Review deck")
        #expect(c.draft.estimate == 45)
        #expect(c.typed == "review deck tomorrow 3pm 45m #launch")
        #expect(TaskCapture.command("todo buy oat milk", now: C.now)?.draft.title == "Buy oat milk")
        #expect(TaskCapture.command("Task: nope", now: C.now) == nil)            // needs the space
        #expect(TaskCapture.command("t tomorrow", now: C.now) == nil)            // nothing to do yet
        #expect(TaskCapture.command("timer 10", now: C.now) == nil)
        #expect(TaskCapture.opensTasks("tasks"))
        #expect(TaskCapture.opensTasks("tas"))
        #expect(TaskCapture.opensTasks("todo"))
        #expect(!TaskCapture.opensTasks("ta"))
    }

    @Test func droppedTextBecomesTasks() {
        let text = """
        Launch checklist
        - [ ] Send the deck to Sam by Friday
        • Book the room
        2. Draft the post 45m

        * [x] Already done
        """
        #expect(TaskCapture.lines(in: text) == ["Launch checklist", "Send the deck to Sam by Friday", "Book the room", "Draft the post 45m", "Already done"])
        #expect(TaskCapture.lines(in: "   \n\n").isEmpty)
        #expect(TaskCapture.lines(in: String(repeating: "x", count: 300)).isEmpty)   // a paragraph isn't a task
    }
}

// MARK: - The keyboard

@Suite("Flow Tasks: keyboard") @MainActor
struct TaskKeyboardTests {
    typealias C = TaskClock

    func key(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func listKeys() throws {
        let s = makeStore()
        s.clock = { Date() }
        s.calendar = .current
        let m = TasksModel(store: s)
        for title in ["One", "Two", "Three"] { _ = s.add(TaskDraft(title: title), source: .typed, in: .today) }
        m.opened()
        let ids = m.rows
        #expect(m.selection == ids[0])
        #expect(m.handle(key(125), typing: false))                    // ↓
        #expect(m.selection == ids[1])
        #expect(m.handle(key(125, "", .command), typing: false))      // ⌘↓: Two moves below Three
        #expect(m.rows.map { s.task(id: $0)?.title } == ["One", "Three", "Two"])
        #expect(m.handle(key(126, "", .command), typing: false))      // ⌘↑: back
        #expect(m.rows.map { s.task(id: $0)?.title } == ["One", "Two", "Three"])
        #expect(m.handle(key(49, " "), typing: false))                // Space completes
        #expect(s.task(id: ids[1])?.isDone == true)
        #expect(m.selection == ids[2])                                 // and the selection moves on
        #expect(m.handle(key(51), typing: false))                     // ⌫ deletes…
        #expect(s.task(id: ids[2]) == nil)
        #expect(m.handle(key(6, "z", .command), typing: false))       // …⌘Z brings it back
        #expect(s.task(id: ids[2]) != nil)
        #expect(m.handle(key(36), typing: false))                     // Return edits
        #expect(m.editing == ids[2])
        m.editText = "Three, tomorrow 9am"
        #expect(m.handle(key(36), typing: true))                      // Return again: saved, words read
        #expect(s.task(id: ids[2])?.title == "Three")
        #expect(m.editing == nil)
        #expect(!m.handle(key(53), typing: false))                    // Esc in the list: the island closes
    }

    @Test func typingStartsATask() throws {
        let s = makeStore()
        s.clock = { Date() }
        s.calendar = .current
        let m = TasksModel(store: s)
        #expect(m.handle(key(4, "h"), typing: false))
        #expect(m.field == .quickAdd)
        #expect(m.draft == "h")
        m.draft = "hang the shelf 30m"
        #expect(m.line.parsed?.estimate == 30)
        #expect(m.handle(key(36), typing: true))
        #expect(m.draft.isEmpty)
        let t = try #require(s.tasks.first)
        #expect(t.title == "Hang the shelf")
        #expect(t.list() == .today)                                   // typed in Today: for today
        #expect(m.handle(key(45, "n", .command), typing: false))      // ⌘N
        #expect(m.field == .quickAdd)
        #expect(m.handle(key(53), typing: true))                      // Esc leaves the empty line
        #expect(m.field == nil)
    }
}
