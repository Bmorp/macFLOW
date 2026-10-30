import Foundation
import EventKit
import SwiftUI

/// Keeps Flow Tasks and a list in Apple Reminders the same, both ways, so tasks reach the iPhone and the Watch.
///
/// A round reads the task list on the main thread, does every EventKit read and write on its own queue
/// (`ReminderMerge.round` over `EventKitReminders`), then hands back an outcome the store applies. Rounds run a
/// moment after a change here, and when Reminders reports one. Without Reminders access nothing runs; tasks work the
/// same, just on this Mac.
@MainActor
final class ReminderSync: ObservableObject {
    static let shared = ReminderSync()

    enum State: Equatable {
        case off
        /// Turned on, but Reminders access was refused (or taken back) in System Settings.
        case denied
        case syncing
        case synced
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// The Reminders list tasks go to.
    @Published private(set) var listName: String?

    private static let enabledKey = "tasks.reminders.sync"
    private static let listKey = "tasks.reminders.list"
    static let defaultListTitle = "Mac Flow"

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private weak var store: TaskStore?
    private let queue = DispatchQueue(label: "atoll.tasks.sync", qos: .utility)
    private var pending: DispatchWorkItem?
    private var running = false
    private var again = false
    private var observing = false

    private var eventStore: EKEventStore { RemindersService.shared.eventStore }
    private var hasAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    func start(with store: TaskStore) {
        self.store = store
        store.onLocalChange = { [weak self] in self?.schedule(after: 1.5) }
        refreshState()
        guard enabled else { return }
        observe()
        schedule(after: 2)
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 1) }
        }
    }

    private func refreshState() {
        guard enabled else { state = .off; listName = nil; return }
        if !hasAccess { state = .denied; return }
        listName = list()?.title
        if state == .off || state == .denied { state = .synced }
    }

    // MARK: Turning it on and off

    /// Asks for Reminders access if it's needed, then makes (or finds) the list and syncs.
    func turnOn() {
        RemindersService.shared.requestAccess { [weak self] granted in
            guard let self else { return }
            self.enabled = true
            guard granted else { self.state = .denied; return }
            self.observe()
            self.state = .syncing
            self.listName = self.list(create: true)?.title
            self.schedule(after: 0)
        }
    }

    func turnOff() {
        enabled = false
        pending?.cancel()
        state = .off
    }

    /// The lists you could sync with.
    var lists: [(id: String, title: String)] {
        guard hasAccess else { return [] }
        return eventStore.calendars(for: .reminder).filter(\.allowsContentModifications).map { ($0.calendarIdentifier, $0.title) }
    }

    /// The list being synced with, by identifier.
    var listID: String? { UserDefaults.standard.string(forKey: Self.listKey) }

    /// Syncs with another list from now on. Tasks already synced stay with their reminders wherever they are.
    func use(list id: String) {
        UserDefaults.standard.set(id, forKey: Self.listKey)
        listName = list()?.title
        schedule(after: 0)
    }

    /// The chosen list, or "Mac Flow" (made on first use, in the account new reminders go to).
    private func list(create: Bool = false) -> EKCalendar? {
        guard hasAccess else { return nil }
        if let id = UserDefaults.standard.string(forKey: Self.listKey), let c = eventStore.calendar(withIdentifier: id) { return c }
        if let c = eventStore.calendars(for: .reminder).first(where: { $0.title == Self.defaultListTitle && $0.allowsContentModifications }) {
            UserDefaults.standard.set(c.calendarIdentifier, forKey: Self.listKey)
            return c
        }
        guard create else { return nil }
        let c = EKCalendar(for: .reminder, eventStore: eventStore)
        c.title = Self.defaultListTitle
        c.source = eventStore.defaultCalendarForNewReminders()?.source
            ?? eventStore.sources.first { $0.sourceType == .calDAV } ?? eventStore.sources.first { $0.sourceType == .local }
        guard c.source != nil, (try? eventStore.saveCalendar(c, commit: true)) != nil else { return nil }
        UserDefaults.standard.set(c.calendarIdentifier, forKey: Self.listKey)
        return c
    }

    // MARK: Rounds

    func schedule(after delay: TimeInterval) {
        guard enabled, !Storage.readOnly else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.round() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func round() {
        guard enabled, let store else { return }
        guard hasAccess else { state = .denied; return }
        if running { again = true; return }
        guard let list = list(create: true) else { state = .failed("Couldn’t open the Reminders list"); return }
        running = true
        if state != .synced { state = .syncing }
        let snap = store.syncState()
        let backend = EventKitReminders(store: eventStore, list: list)
        queue.async {
            let outcome = ReminderMerge.round(backend, locals: snap.locals, tombstones: snap.tombstones)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = ReminderSync.shared
                    store.applySync(outcome, readAt: snap.revisions)
                    me.running = false
                    me.state = outcome.error.map { .failed($0) } ?? .synced
                    if me.again {
                        me.again = false
                        me.schedule(after: 0.5)
                    }
                }
            }
        }
    }
}

/// Reminders through EventKit, for one round on the sync queue. Apple's guidance is one long-lived event store; this
/// borrows the app's and uses it from that one serial queue.
final class EventKitReminders: ReminderBackend, @unchecked Sendable {
    private let store: EKEventStore
    private let list: EKCalendar
    /// Everything read this round, so a write changes the very object that was read.
    private var seen: [String: EKReminder] = [:]

    init(store: EKEventStore, list: EKCalendar) {
        self.store = store
        self.list = list
    }

    /// Incomplete reminders in the list, and ones finished in the last month (to see tasks completed on the phone).
    func fetch() -> [RemoteReminder]? {
        let predicates = [
            store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list]),
            store.predicateForCompletedReminders(withCompletionDateStarting: Date().addingTimeInterval(-30 * 86_400), ending: nil, calendars: [list]),
        ]
        var all: [RemoteReminder] = []
        for p in predicates {
            let done = DispatchSemaphore(value: 0)
            let box = Box()
            store.fetchReminders(matching: p) { found in
                box.value = found
                done.signal()
            }
            guard done.wait(timeout: .now() + 20) == .success, let found = box.value else { return nil }
            for r in found { seen[r.calendarItemIdentifier] = r }
            all += found.map(Self.remote(from:))
        }
        return all
    }

    private final class Box: @unchecked Sendable { var value: [EKReminder]? }

    func lookup(_ id: String) -> RemoteReminder? {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        seen[id] = r
        return Self.remote(from: r)
    }

    func create(_ fields: ReminderFields) -> RemoteReminder? {
        let r = EKReminder(eventStore: store)
        r.calendar = list
        Self.write(fields, to: r, only: Set(ReminderField.allCases))
        guard (try? store.save(r, commit: false)) != nil else { return nil }
        seen[r.calendarItemIdentifier] = r
        return Self.remote(from: r)
    }

    func update(_ id: String, to fields: ReminderFields, only: Set<ReminderField>) -> RemoteReminder? {
        guard let r = seen[id] ?? (store.calendarItem(withIdentifier: id) as? EKReminder) else { return nil }
        Self.write(fields, to: r, only: only)
        guard (try? store.save(r, commit: false)) != nil else { return nil }
        return Self.remote(from: r)
    }

    func delete(_ id: String) -> Bool {
        guard let r = seen[id] ?? (store.calendarItem(withIdentifier: id) as? EKReminder) else { return true }
        return (try? store.remove(r, commit: false)) != nil
    }

    func commit() -> Bool {
        do {
            try store.commit()
            return true
        } catch {
            store.reset()
            return false
        }
    }

    static func remote(from r: EKReminder) -> RemoteReminder {
        RemoteReminder(id: r.calendarItemIdentifier,
                       fields: ReminderFields(title: r.title ?? "", notes: r.notes ?? "",
                                              date: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                                              priority: TaskPriority(reminderValue: r.priority), completed: r.isCompleted),
                       modified: r.lastModifiedDate, completedAt: r.completionDate)
    }

    /// A date without a time goes as a day (an all-day reminder); with a time, as that moment, with an alert then.
    static func components(_ date: Date?) -> DateComponents? {
        guard let date else { return nil }
        let cal = Calendar.current
        guard FlowTask.hasTime(date, calendar: cal) else { return cal.dateComponents([.year, .month, .day], from: date) }
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        c.timeZone = cal.timeZone
        return c
    }

    private static func write(_ f: ReminderFields, to r: EKReminder, only fields: Set<ReminderField>) {
        if fields.contains(.title) { r.title = f.title }
        if fields.contains(.notes) { r.notes = f.notes.isEmpty ? nil : f.notes }
        if fields.contains(.date) {
            r.dueDateComponents = components(f.date)
            for a in r.alarms ?? [] where a.absoluteDate != nil { r.removeAlarm(a) }
            if let d = f.date, FlowTask.hasTime(d) { r.addAlarm(EKAlarm(absoluteDate: d)) }
        }
        if fields.contains(.priority) { r.priority = f.priority.reminderValue }
        if fields.contains(.completed) { r.isCompleted = f.completed }
    }
}
