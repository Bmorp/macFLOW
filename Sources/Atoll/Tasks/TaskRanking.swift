import Foundation

/// Which open tasks matter most today — the morning plan's draft. Pure, so it's tested.
///
/// First what's due today or overdue (soonest first), then what's planned for today or carried from an earlier day,
/// then the rest of the backlog; within each, what the Brain has learned matters to you, then priority, then your order.
/// Someday and tasks planned for later days stay out.
enum TaskRanking {
    struct Pick: Equatable {
        var task: FlowTask
        /// Why it's in the plan, in words: "Overdue", "Due today", "Unfinished yesterday", "From Design Review".
        var reason: String
    }

    static func rank(_ tasks: [FlowTask], now: Date, calendar cal: Calendar = .current,
                     importance: (FlowTask) -> Double = { _ in 0.5 }) -> [Pick] {
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? now
        func tier(_ t: FlowTask) -> Int? {
            if let due = t.due, due < tomorrow { return 0 }
            if let s = t.scheduled { return s < tomorrow ? 1 : nil }
            if t.someday { return nil }
            return 2
        }
        let candidates = tasks.compactMap { t -> (FlowTask, Int, Double)? in
            guard t.isOpen, let tier = tier(t) else { return nil }
            return (t, tier, importance(t))
        }
        let sorted = candidates.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.1 == 0, let x = a.0.due, let y = b.0.due, x != y { return x < y }
            if abs(a.2 - b.2) > 0.001 { return a.2 > b.2 }
            if a.0.priority != b.0.priority { return a.0.priority > b.0.priority }
            return a.0.order < b.0.order
        }
        return sorted.map { t, tier, _ in Pick(task: t, reason: reason(t, tier: tier, today: today, calendar: cal)) }
    }

    static func reason(_ t: FlowTask, tier: Int, today: Date, calendar cal: Calendar) -> String {
        switch tier {
        case 0:
            return (t.due.map { cal.startOfDay(for: $0) < today } ?? false) ? "Overdue" : "Due today"
        case 1:
            if let s = t.scheduled, cal.startOfDay(for: s) < today {
                let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
                return cal.startOfDay(for: s) == yesterday ? "Unfinished yesterday" : "Carried over"
            }
            return t.context ?? "Planned for today"
        default:
            if let c = t.context { return c }
            return t.priority >= .medium ? "A priority in your tasks" : "From your tasks"
        }
    }
}
