import Testing
import Foundation
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
