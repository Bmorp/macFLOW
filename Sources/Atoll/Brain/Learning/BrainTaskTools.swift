import Foundation

/// What Flow's tasks tools do, apart from the language model that calls them — so they work (and are tested) on any
/// macOS, and say plainly when Flow Tasks isn't there.
@MainActor
enum BrainTaskTools {
    static let unavailable = "Tasks aren’t available yet in this version of Mac Flow."

    /// Open tasks, most important first, with Flow's estimates.
    static func list(ledger: TaskLedger?, advisor given: TaskAdvisor? = nil, now: Date = Date(), limit: Int = 10) -> String {
        let advisor = given ?? TaskLinks.advisor
        guard let ledger else { return unavailable }
        let open = ledger.openTasks()
        guard !open.isEmpty else { return "No open tasks." }
        let ranked = open.sorted { (advisor?.importance(of: $0, at: now) ?? 0) > (advisor?.importance(of: $1, at: now) ?? 0) }
        return ranked.prefix(limit).map { t in
            var line = "- \(t.title)"
            if let p = t.project, !p.isEmpty { line += " [\(p)]" }
            if let d = t.due { line += " · due \(d.formatted(date: .abbreviated, time: .shortened))" }
            if let m = t.estimate ?? advisor?.estimate(for: t)?.minutes { line += " · about \(TaskBrain.minutesText(m))" }
            if t.status == .active { line += " · in progress" }
            return line
        }.joined(separator: "\n") + (open.count > limit ? "\n(and \(open.count - limit) more)" : "")
    }

    /// Adds a task from plain words, parsed the way typed capture is.
    static func add(_ text: String, ledger: TaskLedger?) -> (reply: String, task: TaskSnapshot?) {
        guard let ledger else { return (unavailable, nil) }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return ("What should the task say?", nil) }
        guard let t = ledger.capture(words, source: .flow) else { return ("I couldn’t add that task.", nil) }
        return ("Added “\(t.title)”" + (t.due.map { ", due \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "") + ".", t)
    }

    /// Completes the open task that best matches the words.
    static func complete(_ query: String, ledger: TaskLedger?) -> (reply: String, task: TaskSnapshot?) {
        guard let ledger else { return (unavailable, nil) }
        guard let t = match(query, in: ledger.openTasks()) else { return ("I couldn’t find an open task like “\(query)”.", nil) }
        ledger.complete(t.id)
        return ("Done: “\(t.title)”.", t)
    }

    /// The task a few words mean: exact title first, then the most shared words.
    nonisolated static func match(_ query: String, in tasks: [TaskSnapshot]) -> TaskSnapshot? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let exact = tasks.first(where: { $0.title.lowercased() == q }) { return exact }
        if let contains = tasks.first(where: { $0.title.lowercased().contains(q) }) { return contains }
        let words = Set(q.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        guard !words.isEmpty else { return nil }
        let scored = tasks.map { t -> (Double, TaskSnapshot) in
            let tw = Set(t.title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            return (Double(words.intersection(tw).count) / Double(words.count), t)
        }
        guard let best = scored.max(by: { $0.0 < $1.0 }), best.0 >= 0.5 else { return nil }
        return best.1
    }
}
