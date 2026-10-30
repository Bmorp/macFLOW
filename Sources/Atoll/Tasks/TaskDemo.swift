#if DEBUG
import Foundation

/// Debug-only: a believable day of tasks for the snapshot harness. Never reaches a user's store.
@MainActor
enum TaskDemo {
    private static func task(_ title: String, scheduled: Date? = nil, due: Date? = nil, estimate: Double? = nil, project: String? = nil,
                             priority: TaskPriority = .none, repeats: RepeatRule? = nil, someday: Bool = false, order: Double) -> FlowTask {
        var t = FlowTask(title: title)
        t.scheduled = scheduled
        t.due = due
        t.estimate = estimate
        t.project = project
        t.priority = priority
        t.repeats = repeats
        t.someday = someday
        t.order = order
        return t
    }

    /// A busy Today (one of them in focus), a few days ahead, and a couple of ideas parked.
    static func busyWeek() -> (tasks: [FlowTask], active: UUID) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ n: Int, _ h: Int = 0, _ m: Int = 0) -> Date {
            let d = cal.date(byAdding: .day, value: n, to: today) ?? today
            return h == 0 && m == 0 ? d : cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d
        }
        let post = task("Write the launch post", scheduled: day(0, 10, 40), estimate: 90, project: "launch", order: 1)
        let list = [
            post,
            task("Review the pricing deck", scheduled: day(0, 15), estimate: 45, project: "launch", priority: .high, order: 2),
            task("Send the invoice to Northwind", due: day(0), estimate: 15, order: 3),
            task("Reply to Priya about the beta", scheduled: day(-1), estimate: 20, order: 4),
            task("Expense report", due: day(-2), estimate: 30, priority: .medium, order: 5),
            task("Water the plants", scheduled: day(0), repeats: .weekly([cal.component(.weekday, from: today)]), order: 6),
            task("Call the dentist", scheduled: day(0, 17, 30), estimate: 10, order: 7),
            task("Plan the offsite", scheduled: day(1), estimate: 60, project: "team", order: 8),
            task("Design review", scheduled: day(1, 14), estimate: 60, order: 9),
            task("Renew passport", due: day(4), order: 10),
            task("Read “Shape Up”", order: 11),
            task("Learn the piano", someday: true, order: 12),
            task("Build a cabin", someday: true, order: 13),
        ]
        return (list, post.id)
    }
}
#endif
