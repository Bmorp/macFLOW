import EventKit
import AppKit
import SwiftUI

/// Creates real reminders in the Reminders app from natural language:
/// "remind me to call Sam at 5pm" → "Call Sam", due today 17:00, with an alarm.
@MainActor
final class RemindersService: ObservableObject {
    static let shared = RemindersService()

    enum Access { case unknown, granted, denied }

    struct Draft: Equatable {
        let title: String
        let due: Date?
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let due: Date?
        let color: Color
        var done: Bool
        var isOverdue: Bool { (due.map { $0 < Calendar.current.startOfDay(for: Date()) }) ?? false }
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var items: [Item] = []
    private let store = EKEventStore()
    private var watching = false

    init() { updateAccess() }

    #if DEBUG
    func debugSet(_ list: [Item]) {
        access = .granted
        watching = true
        items = list
    }
    #endif

    /// Starts keeping `items` current (incomplete reminders, due ones first). Asks for nothing.
    func watch() {
        guard !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func requestAccess() {
        if access == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { NSWorkspace.shared.open(url) }
            return
        }
        NSApp.activate()
        store.requestFullAccessToReminders { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateAccess()
                self?.reload()
            }
        }
    }

    func reload() {
        updateAccess()
        guard access == .granted else { items = []; return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let mapped: [Item] = (reminders ?? []).map { r in
                Item(id: r.calendarItemIdentifier,
                     title: r.title ?? "",
                     due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                     color: Color(nsColor: r.calendar?.color ?? .systemOrange),
                     done: false)
            }
            .sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.title < b.title
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let next = Array(mapped.prefix(20))
                if next != self.items { withAnimation(.smooth) { self.items = next } }
            }
        }
    }

    /// Checks a reminder off with a moment to see it happen before it leaves the list.
    func complete(_ item: Item) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(.snappy) { items[i].done = true }
        if let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder {
            reminder.isCompleted = true
            try? store.save(reminder, commit: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            withAnimation(.smooth) { self?.items.removeAll { $0.id == item.id } }
        }
    }

    func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }

    /// Recognizes "remind me to …", "remind me …", "reminder …", "todo …".
    nonisolated static func parse(_ query: String) -> Draft? {
        let lower = query.lowercased()
        let prefixes = ["remind me to ", "remind me ", "reminder ", "todo ", "to-do "]
        guard let prefix = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        var body = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        var due: Date?
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.matches(in: body, range: NSRange(body.startIndex..., in: body)).last,
           let date = match.date, let range = Range(match.range, in: body) {
            due = date
            body.removeSubrange(range)
            body = body.trimmingCharacters(in: .whitespaces)
            for connector in [" at", " on", " by", " in", " for"] where body.lowercased().hasSuffix(connector) {
                body = String(body.dropLast(connector.count))
            }
        }
        let title = body.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return Draft(title: "", due: due) }
        return Draft(title: title.prefix(1).uppercased() + title.dropFirst(), due: due)
    }

    func create(_ draft: Draft, completion: @escaping (Bool) -> Void) {
        guard !draft.title.isEmpty else { return completion(false) }
        let save: () -> Void = { [store] in
            let reminder = EKReminder(eventStore: store)
            reminder.title = draft.title
            reminder.calendar = store.defaultCalendarForNewReminders()
            if let due = draft.due {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            completion((try? store.save(reminder, commit: true)) != nil)
        }
        if access == .granted {
            save()
        } else {
            NSApp.activate()
            store.requestFullAccessToReminders { [weak self] ok, _ in
                DispatchQueue.main.async {
                    self?.updateAccess()
                    if ok { save() } else { completion(false) }
                }
            }
        }
    }

    static func describe(_ due: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: due)
    }
}

