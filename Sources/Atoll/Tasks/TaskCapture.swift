import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Tasks' look, in one place: the system accent (as Reminders fills its circles with the list's colour).
enum TaskStyle {
    static var tint: Color { Color(nsColor: .controlAccentColor) }
}

/// Getting tasks in from everywhere: ⌥Space, text dropped on the notch, and the words for each.
@MainActor
enum TaskCapture {
    static let prefixes = ["t ", "task ", "todo ", "to-do ", "add task ", "new task "]

    /// "t review deck tomorrow 3pm" → what it would add, and the words after the prefix. Nil if it isn't a task command
    /// or there's no title yet.
    static func command(_ query: String, now: Date = Date()) -> (draft: TaskDraft, typed: String)? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard let p = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        let rest = String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        let draft = TaskParser.parse(rest, now: now)
        return draft.title.isEmpty ? nil : (draft, rest)
    }

    /// "tasks", "todo", "my tasks", or the start of "tasks".
    static func opensTasks(_ lower: String) -> Bool {
        ["tasks", "my tasks", "todo", "todos", "to-do", "to-dos", "todo list", "to do"].contains(lower) || (lower.count >= 3 && "tasks".hasPrefix(lower))
    }

    /// Open tasks whose title has these words, best first.
    static func find(_ lower: String, limit: Int = 3) -> [(id: UUID, title: String, detail: String)] {
        guard lower.count >= 3 else { return [] }
        let store = TaskStore.shared
        let hits = store.tasks.filter { $0.isOpen && $0.title.localizedCaseInsensitiveContains(lower) }
            .sorted { a, b in
                let pa = a.title.lowercased().hasPrefix(lower), pb = b.title.lowercased().hasPrefix(lower)
                if pa != pb { return pa }
                return (a.when ?? .distantFuture) < (b.when ?? .distantFuture)
            }
        return hits.prefix(limit).map { t in
            (t.id, t.title, (["Task"] + TaskRowText.meta(t, list: t.list(), now: Date()).map(\.text)).joined(separator: " · "))
        }
    }

    /// One line about your tasks, for the "Tasks" result: "4 today · next: Review deck".
    static var summary: String {
        let today = TaskStore.shared.list(.today).filter(\.isOpen)
        guard let first = today.first else { return "Nothing left for today" }
        return "\(today.count) today · next: \(first.title)"
    }

    /// What adding said: "Added · Tomorrow 3:00 PM".
    static func added(_ t: FlowTask) -> String {
        if t.someday { return "Added to Someday" }
        guard let w = t.when else { return "Task Added" }
        return "Added · " + TaskFormat.when(w)
    }

    // MARK: Dropped text

    /// Text dropped on the notch becomes tasks: a line, or a list of lines (bullets and checkboxes dropped), each read
    /// like typed words. Files aren't text: they go to the shelf and Flow as before.
    static func canTake(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
            && !providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }

    @discardableResult
    static func drop(_ providers: [NSItemProvider]) -> Bool {
        guard canTake(providers) else { return false }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            _ = p.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? NSString else { return }
                let string = String(text)
                DispatchQueue.main.async { MainActor.assumeIsolated { take(string) } }
            }
        }
        return true
    }

    static func take(_ text: String) {
        let lines = lines(in: text)
        guard !lines.isEmpty else { return }
        var added: [FlowTask] = []
        for line in lines.prefix(30) {
            if let t = TaskStore.shared.add(TaskParser.parse(line), typed: line, source: .drop) { added.append(t) }
        }
        guard let first = added.first else { return }
        HapticEngine.shared.play(.confirm, channel: .tasks)
        IslandManager.shared.confirm("checkmark.circle.fill", added.count == 1 ? "Task added · \(first.title)" : "\(added.count) tasks added",
                                     tint: TaskStyle.tint)
    }

    /// The lines of dropped text that read like tasks: list markers stripped, blanks and very long lines left out.
    nonisolated static func lines(in text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: #"^(?:[-*•–]\s*)?(?:\[[ xX]?\]\s*)?(?:\d{1,2}[.)]\s+)?"#, with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.count > 200 ? nil : line
        }
    }
}
