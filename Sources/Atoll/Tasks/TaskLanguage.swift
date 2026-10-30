import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The on-device model as a second reader, never a requirement. The rules parser runs on every keystroke and
/// decides; when it found no day or length in words that clearly mention one ("the Tuesday after next", "a week
/// from Friday"), the model is asked afterwards, and its answer fills only what's still empty — if you haven't
/// touched the task meanwhile. Without macOS 26 and Apple Intelligence, nothing here runs.
@MainActor
enum TaskLanguage {
    /// Words that suggest a day or a length the rules may have missed. Without one, the model isn't asked:
    /// it can't invent a date for "buy milk".
    static func mentionsTime(_ text: String) -> Bool {
        let cues = ["day", "week", "month", "year", "next", "after", "before", "until", "tonight", "morning", "evening",
                    "afternoon", "hour", "minute", "min", "noon", "end of", "mon", "tue", "wed", "thu", "fri", "sat", "sun",
                    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let lower = text.lowercased()
        return lower.rangeOfCharacter(from: .decimalDigits) != nil || cues.contains { lower.contains($0) }
    }

    static func refine(_ id: UUID, typed: String, in store: TaskStore) {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), Mind.shared.isAvailable, mentionsTime(typed) else { return }
        guard let original = store.task(id: id) else { return }
        let now = store.now
        Task { @MainActor in
            guard let read = await ask(typed, now: now) else { return }
            // Only if it's still exactly as captured.
            guard let t = store.task(id: id), t.stamps == original.stamps, t.title == original.title else { return }
            let cal = store.calendar
            var day: Date?
            if let d = read.day, let parsed = dayFormatter().date(from: d) {
                let start = cal.startOfDay(for: parsed)
                let span = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: start).day ?? 0
                if (0...400).contains(span) { day = start }
            }
            if let d = day, let time = read.time {
                let parts = time.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) {
                    day = cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: d)
                }
            }
            let minutes = read.minutes.flatMap { (1...600).contains($0) ? Double($0) : nil }
            guard day != nil || minutes != nil else { return }
            store.update(id) { task in
                if task.scheduled == nil, task.due == nil, let day { task.scheduled = day; task.someday = false }
                if task.estimate == nil || !task.estimateIsUser, let minutes { task.estimate = minutes; task.estimateIsUser = true }
            }
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func ask(_ text: String, now: Date) async -> (day: String?, time: String?, minutes: Int?)? {
        let session = LanguageModelSession(instructions: """
        You read a to-do the user typed and say when it's for and how long it takes, only if the words say so.
        Today is \(dayFormatter().string(from: now)), a \(now.formatted(.dateTime.weekday(.wide))).
        Never guess: leave a field empty when the text doesn't state it.
        """)
        guard let r = try? await session.respond(to: text, generating: TaskReading.self).content else { return nil }
        let day = r.day.trimmingCharacters(in: .whitespaces)
        let time = r.time.trimmingCharacters(in: .whitespaces)
        return (day.isEmpty ? nil : day, time.isEmpty ? nil : time, r.minutes > 0 ? r.minutes : nil)
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct TaskReading {
    @Guide(description: "The day the task is for, as yyyy-MM-dd, or empty if the text names no day")
    var day: String
    @Guide(description: "The time of day as HH:mm in 24 hours, or empty if the text names no time")
    var time: String
    @Guide(description: "How many minutes the task takes if the text says, otherwise 0")
    var minutes: Int
}
#endif

/// yyyy-MM-dd in the user's time zone.
private func dayFormatter() -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate, .withDashSeparatorInDate]
    f.timeZone = .current
    return f
}
