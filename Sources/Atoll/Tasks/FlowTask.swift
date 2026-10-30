import Foundation

/// The fields of a task that are edited on their own, each with its own modified time, so a change made on the
/// iPhone to one field never overwrites a change made here to another (last edit wins per field).
enum TaskField: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case title, notes, project, due, scheduled, estimate, priority, status, someday, order
}

/// How a task repeats. Completing one schedules the next occurrence as a new task.
enum RepeatRule: Hashable, Codable, Sendable {
    case daily
    case weekdays
    /// On these weekdays (1 = Sunday … 7 = Saturday, as `Calendar` counts them).
    case weekly(Set<Int>)
    /// On this day of the month.
    case monthly(Int)
    case yearly

    /// The first day on or after `day` (a start of day) that this rule lands on.
    func next(onOrAfter day: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        switch self {
        case .daily:
            return start
        case .weekdays:
            var d = start
            while calendar.isDateInWeekend(d) { d = calendar.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86_400) }
            return d
        case .weekly(let days):
            guard !days.isEmpty else { return start }
            for offset in 0..<8 {
                let d = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                if days.contains(calendar.component(.weekday, from: d)) { return d }
            }
            return start
        case .monthly(let dom):
            var month = calendar.dateComponents([.year, .month], from: start)
            for _ in 0..<14 {
                let range = calendar.range(of: .day, in: .month, for: calendar.date(from: month) ?? start) ?? 1..<29
                var c = month
                c.day = min(dom, range.count)
                if let d = calendar.date(from: c), d >= start { return d }
                month.month = (month.month ?? 1) + 1
            }
            return start
        case .yearly:
            return start
        }
    }

    /// The occurrence after the one on `day`.
    func following(_ day: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        switch self {
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: start) ?? start
        case .monthly:
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return next(onOrAfter: calendar.date(from: calendar.dateComponents([.year, .month], from: nextMonth)) ?? nextMonth, calendar: calendar)
        default:
            return next(onOrAfter: calendar.date(byAdding: .day, value: 1, to: start) ?? start, calendar: calendar)
        }
    }

    func describe(calendar: Calendar = .current) -> String {
        switch self {
        case .daily: return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly(let days):
            let names = days.sorted { (($0 + 5) % 7) < (($1 + 5) % 7) }.map { calendar.weekdaySymbols[($0 - 1 + 7) % 7] }
            return names.isEmpty ? "Every week" : "Every " + names.joined(separator: " and ")
        case .monthly(let d): return "Every month on the \(d)\(Self.ordinal(d))"
        case .yearly: return "Every year"
        }
    }

    static func ordinal(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }
}

/// One task. Flow Tasks keeps these in its own SQLite file; the rest of the app sees `TaskSnapshot`s.
///
/// Dates follow one convention: a date at exactly midnight is a day without a time ("tomorrow"); anything else
/// carries its time ("tomorrow 3pm"). That's how Reminders reads them too (date-only due components).
struct FlowTask: Identifiable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var title: String
    var notes: String = ""
    var project: String?
    /// When it has to be done by.
    var due: Date?
    /// When it's planned to be worked on — the day it shows up in Today.
    var scheduled: Date?
    /// Minutes.
    var estimate: Double?
    /// Whether the estimate is the user's own (the Brain only fills estimates nobody gave).
    var estimateIsUser = false
    var priority: TaskPriority = .none
    var status: TaskStatus = .open
    var source: TaskSource = .typed
    /// Focused seconds spent on it so far.
    var actual: TimeInterval = 0
    var created: Date = Date()
    var completed: Date?
    /// The matching reminder in Apple Reminders (`calendarItemIdentifier`), once synced.
    var reminderID: String?
    /// Manual order; fractional so a move rewrites one row.
    var order: Double = 0
    /// Parked for some day: out of Today and Upcoming until it's given a date.
    var someday = false
    /// Where it came from, in words: "From Design Review", "Unfinished yesterday".
    var context: String?
    var repeats: RepeatRule?
    /// When each field last changed here.
    var stamps: [TaskField: Date] = [:]

    var isOpen: Bool { status == .open || status == .active }
    var isDone: Bool { status == .done }

    /// The date the task is "for": when it's planned, else when it's due.
    var when: Date? { scheduled ?? due }

    var snapshot: TaskSnapshot {
        TaskSnapshot(id: id, title: title, notes: notes, project: project, due: due, scheduled: scheduled, estimate: estimate,
                     priority: priority, status: status, source: source, actual: actual, created: created, completed: completed)
    }

    mutating func touch(_ fields: TaskField..., at date: Date = Date()) {
        for f in fields { stamps[f] = date }
    }

    static func hasTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0 || (c.second ?? 0) != 0
    }

    /// Past its due date: a day-only due is overdue once that day is over; a timed one once its time has passed.
    func isOverdue(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isOpen, let due else { return false }
        return Self.hasTime(due, calendar: calendar) ? due < now : due < calendar.startOfDay(for: now)
    }
}

/// A project: a name tasks are filed under (`#launch`). Created on first use.
struct FlowProject: Identifiable, Hashable, Codable, Sendable {
    var id: String { name.lowercased() }
    var name: String
    var created: Date = Date()
    var order: Double = 0
}

// MARK: - Where a task belongs

/// The Tasks place's three lists.
enum TaskList: String, CaseIterable, Identifiable, Sendable {
    case today = "Today", upcoming = "Upcoming", someday = "Someday"
    var id: String { rawValue }
}

extension FlowTask {
    /// Which list an open task shows in: anything planned or due on or before today is Today's (yesterday's
    /// unfinished work rolls in on its own); later dates and undated tasks are Upcoming; parked ones are Someday.
    func list(at now: Date = Date(), calendar: Calendar = .current) -> TaskList {
        if someday && scheduled == nil && due == nil { return .someday }
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        if let s = scheduled, s < endOfToday { return .today }
        if let d = due, d < endOfToday { return .today }
        if someday { return .someday }
        return .upcoming
    }
}
