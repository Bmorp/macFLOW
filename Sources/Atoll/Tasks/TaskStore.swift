import Foundation
import Combine
import SwiftUI

/// The task you're working on right now, for Home and the compact island: what it is and how long you've been at it.
/// Its own small object, so showing it never re-renders anything when the task list changes.
@MainActor
final class ActiveTask: ObservableObject {
    @Published private(set) var task: TaskSnapshot?
    /// When the current stretch of focus began.
    @Published private(set) var since: Date?
    /// Focused time on it before this stretch.
    private(set) var before: TimeInterval = 0

    func elapsed(at date: Date = Date()) -> TimeInterval { before + (since.map { max(0, date.timeIntervalSince($0)) } ?? 0) }

    fileprivate func begin(_ t: FlowTask, at date: Date) {
        before = t.actual
        since = date
        task = t.snapshot
    }

    fileprivate func end() {
        task = nil
        since = nil
        before = 0
    }

    fileprivate func refresh(_ t: FlowTask) { if task?.id == t.id { task = t.snapshot } }
}

/// Every task, in memory on the main thread and written through to `TaskDatabase`. Each change is published as a
/// `TaskEvent` the moment it happens, so the Brain learns from it; `TaskLinks.ledger` is this store.
@MainActor
final class TaskStore: ObservableObject, TaskLedger {
    static let shared = TaskStore(database: Storage.readOnly ? nil : TaskDatabase(url: TaskDatabase.defaultURL))

    @Published private(set) var tasks: [FlowTask] = []
    @Published private(set) var projects: [FlowProject] = []
    /// Bumped on every change: a cheap key for anything derived from the list.
    @Published private(set) var revision = 0
    /// The task being focused on, if any.
    let active = ActiveTask()

    private let database: TaskDatabase?
    /// Reminders' side of each synced task, as of the last sync.
    private(set) var bases: [UUID: ReminderFields] = [:]
    /// Deleted here, still to be deleted in Reminders.
    private(set) var tombstones: [String: Date] = [:]
    /// Just completed: kept in their list a moment so the circle can be seen filling.
    private var lingering: Set<UUID> = []
    private var focus: (id: UUID, since: Date)?
    /// The task a focus block is about to start for (set just before the timer starts).
    private var focusTarget: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    /// Tests pin time.
    var clock: () -> Date = { Date() }
    var calendar: Calendar = .current
    /// Called after any change that Reminders should hear about.
    var onLocalChange: (() -> Void)?

    init(database: TaskDatabase?) {
        self.database = database
        guard let database else { return }
        let c = database.load()
        tasks = c.tasks
        bases = c.bases
        projects = c.projects
        tombstones = Dictionary(c.tombstones.map { ($0.reminderID, $0.deleted) }, uniquingKeysWith: { a, _ in a })
        // No timer survives a relaunch, so nothing is mid-focus.
        for i in tasks.indices where tasks[i].status == .active {
            tasks[i].status = .open
            persist(tasks[i])
        }
    }

    /// Registers as the Brain's ledger and starts following focus blocks and Reminders. Safe to call again.
    func start() {
        TaskLinks.ledger = self
        guard !started else { return }
        started = true
        FocusTimer.shared.$phase
            .sink { [weak self] phase in
                // `@Published` tells us before it changes; act once it has.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.focusChanged(phase) } }
            }
            .store(in: &cancellables)
        ReminderSync.shared.start(with: self)
    }

    var now: Date { clock() }

    // MARK: - Reading

    func task(id: UUID) -> FlowTask? { tasks.first { $0.id == id } }

    /// An open task in a list, in your order. Today keeps a just-completed task a moment longer.
    func list(_ l: TaskList) -> [FlowTask] {
        let now = self.now
        return tasks
            .filter { ($0.isOpen || lingering.contains($0.id)) && $0.list(at: now, calendar: calendar) == l }
            .sorted { $0.order < $1.order }
    }

    struct Section: Identifiable, Equatable {
        var id: String
        var title: String?
        var tasks: [FlowTask]
    }

    /// A list as it's shown: Today and Someday as one run; Upcoming by day, then the undated ("Anytime").
    func sections(_ l: TaskList) -> [Section] {
        let items = list(l)
        guard l == .upcoming else { return items.isEmpty ? [] : [Section(id: l.rawValue, title: nil, tasks: items)] }
        let now = self.now
        var byDay: [Date: [FlowTask]] = [:]
        var anytime: [FlowTask] = []
        for t in items {
            if let w = t.when { byDay[calendar.startOfDay(for: w), default: []].append(t) } else { anytime.append(t) }
        }
        var out = byDay.keys.sorted().map { day -> Section in
            let list = byDay[day]!.sorted { a, b in
                let ta = FlowTask.hasTime(a.when!, calendar: calendar), tb = FlowTask.hasTime(b.when!, calendar: calendar)
                if ta != tb { return ta }                // timed first, in time order
                if ta, a.when! != b.when! { return a.when! < b.when! }
                return a.order < b.order
            }
            return Section(id: "d\(Int(day.timeIntervalSince1970))", title: TaskFormat.day(day, now: now, calendar: calendar), tasks: list)
        }
        if !anytime.isEmpty { out.append(Section(id: "anytime", title: "Anytime", tasks: anytime)) }
        return out
    }

    /// Open tasks the Brain and the plan can see.
    func openTasks() -> [TaskSnapshot] { tasks.filter(\.isOpen).map(\.snapshot) }

    func task(_ id: UUID) -> TaskSnapshot? { task(id: id)?.snapshot }

    /// How many tasks were finished today.
    var doneToday: Int {
        let start = calendar.startOfDay(for: now)
        return tasks.filter { $0.isDone && ($0.completed ?? .distantPast) >= start }.count
    }

    /// The morning plan's picks, best first.
    func ranked() -> [TaskRanking.Pick] {
        let now = self.now
        let advisor = TaskLinks.advisor
        return TaskRanking.rank(tasks, now: now, calendar: calendar) { t in advisor?.importance(of: t.snapshot, at: now) ?? 0.5 }
    }

    // MARK: - Capture

    private var nextOrder: Double { (tasks.map(\.order).max() ?? 0) + 1 }

    /// Adds a task from parsed words. `list` is where it was typed: a task added in Today without a date is for today;
    /// in Someday, it's parked.
    @discardableResult
    func add(_ draft: TaskDraft, typed: String? = nil, source: TaskSource, context: String? = nil, in list: TaskList? = nil,
             notes: String = "") -> FlowTask? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let now = self.now
        var t = FlowTask(title: String(title.prefix(500)))
        t.notes = notes
        t.project = draft.project.map(project(named:))
        t.due = draft.due
        t.scheduled = draft.scheduled
        t.priority = draft.priority
        t.repeats = draft.repeats
        t.someday = draft.someday || (list == .someday && draft.scheduled == nil && draft.due == nil)
        if list == .today, t.scheduled == nil, !t.someday { t.scheduled = calendar.startOfDay(for: now) }
        if let e = draft.estimate {
            t.estimate = e
            t.estimateIsUser = true
        }
        t.source = source
        t.context = context
        t.created = now
        t.order = nextOrder
        for f in TaskField.allCases { t.stamps[f] = now }
        if t.estimate == nil, let guess = TaskLinks.advisor?.estimate(for: t.snapshot) { t.estimate = guess.minutes.rounded() }
        insert(t)
        if let typed, draft.scheduled == nil, draft.due == nil, draft.estimate == nil { TaskLanguage.refine(t.id, typed: typed, in: self) }
        return t
    }

    /// Plain words, parsed the same way as typed capture (the ledger's `capture`).
    @discardableResult
    func capture(_ text: String, source: TaskSource) -> TaskSnapshot? {
        add(TaskParser.parse(text, now: now, calendar: calendar), typed: text, source: source)?.snapshot
    }

    private func insert(_ t: FlowTask, notify: Bool = true) {
        tasks.append(t)
        persist(t)
        changed(localOnly: !notify)
        TaskEvents.send(.added(t.snapshot))
    }

    /// The project's own spelling if it exists ("#Launch" files under "launch"), created on first use otherwise.
    func project(named name: String) -> String {
        if let p = projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return p.name }
        let p = FlowProject(name: name, created: now, order: Double(projects.count))
        projects.append(p)
        database?.save(p)
        return p.name
    }

    // MARK: - Changing

    /// Changes a task; whatever fields actually changed get today's time (for last-edit-wins) and one event goes out.
    func update(_ id: UUID, at stamp: Date? = nil, fromSync: Bool = false, _ change: (inout FlowTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let before = tasks[i]
        var after = before
        change(&after)
        guard after != before else { return }
        let when = stamp ?? now
        Self.stampChanges(from: before, to: &after, at: when)
        if let p = after.project, p != before.project { after.project = project(named: p) }
        tasks[i] = after
        persist(after)
        active.refresh(after)
        changed(localOnly: fromSync)
        if before.status != .done, after.status == .done {
            TaskEvents.send(.completed(after.snapshot))
        } else if before.status == .done, after.status != .done {
            TaskEvents.send(.reopened(after.snapshot))
        } else {
            TaskEvents.send(.updated(after.snapshot))
        }
    }

    static func stampChanges(from a: FlowTask, to b: inout FlowTask, at when: Date) {
        if a.title != b.title { b.stamps[.title] = when }
        if a.notes != b.notes { b.stamps[.notes] = when }
        if a.project != b.project { b.stamps[.project] = when }
        if a.due != b.due { b.stamps[.due] = when }
        if a.scheduled != b.scheduled { b.stamps[.scheduled] = when }
        if a.estimate != b.estimate { b.stamps[.estimate] = when }
        if a.priority != b.priority { b.stamps[.priority] = when }
        if a.status != b.status, (a.status == .done) != (b.status == .done) || b.status == .dropped { b.stamps[.status] = when }
        if a.someday != b.someday { b.stamps[.someday] = when }
        if a.order != b.order { b.stamps[.order] = when }
    }

    func complete(_ id: UUID) {
        guard let t = task(id: id), t.isOpen else { return }
        if focus?.id == id { endFocus() }
        let now = self.now
        lingering.insert(id)
        update(id) { $0.status = .done; $0.completed = now }
        // A repeating task comes back on its next day.
        if let rule = t.repeats {
            update(id) { $0.repeats = nil }
            var next = t
            next.id = UUID()
            next.status = .open
            next.completed = nil
            next.actual = 0
            next.reminderID = nil
            next.created = now
            next.order = nextOrder
            let anchor = t.scheduled ?? t.due ?? now
            let day = rule.following(max(calendar.startOfDay(for: anchor), calendar.startOfDay(for: now)), calendar: calendar)
            let shift = day.timeIntervalSince(calendar.startOfDay(for: anchor))
            next.scheduled = t.scheduled.map { $0.addingTimeInterval(shift) } ?? (t.due == nil ? day : nil)
            next.due = t.due.map { $0.addingTimeInterval(shift) }
            for f in TaskField.allCases { next.stamps[f] = now }
            insert(next)
        }
        // The circle fills, then the row goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.lingering.remove(id) != nil else { return }
            withAnimation(Motion.morph) { self.changed(localOnly: true) }
        }
    }

    func reopen(_ id: UUID) {
        lingering.remove(id)
        update(id) { $0.status = .open; $0.completed = nil }
    }

    /// Space in the list: done, or not done after all.
    func toggle(_ id: UUID) {
        guard let t = task(id: id) else { return }
        if t.isDone { reopen(id) } else { complete(id) }
    }

    /// Deletes a task (and its reminder at the next sync). Returns it, for Undo.
    @discardableResult
    func delete(_ id: UUID) -> FlowTask? {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        if focus?.id == id { endFocus() }
        let t = tasks.remove(at: i)
        lingering.remove(id)
        bases[id] = nil
        if let r = t.reminderID { tombstones[r] = now }
        database?.delete(id, tombstone: t.reminderID)
        changed()
        TaskEvents.send(.deleted(id))
        return t
    }

    /// Undo a delete. If its reminder is already gone from Reminders, it goes back as a new one.
    func restore(_ t: FlowTask) {
        guard task(id: t.id) == nil else { return }
        var t = t
        if let r = t.reminderID {
            if tombstones.removeValue(forKey: r) != nil {
                database?.clearTombstone(r)
            } else {
                t.reminderID = nil
            }
        }
        insert(t)
    }

    // MARK: - Order

    /// Moves a task to `index` within the list it's shown in, writing only its own order.
    func move(_ id: UUID, to index: Int, in ids: [UUID]) {
        var rest = ids.filter { $0 != id }
        let i = max(0, min(index, rest.count))
        let orderOf: (UUID) -> Double? = { x in self.tasks.first { $0.id == x }?.order }
        let before = i > 0 ? orderOf(rest[i - 1]) : nil
        let after = i < rest.count ? orderOf(rest[i]) : nil
        var value: Double
        switch (before, after) {
        case let (b?, a?): value = (b + a) / 2
        case let (b?, nil): value = b + 1
        case let (nil, a?): value = a - 1
        default: value = 0
        }
        // Squeezed too tight between two neighbours: space the whole list out again.
        if let b = before, let a = after, a - b < 1e-6 {
            rest.insert(id, at: i)
            for (n, x) in rest.enumerated() { update(x) { $0.order = Double(n) } }
            return
        }
        if value == orderOf(id) { return }
        update(id) { $0.order = value }
    }

    // MARK: - The plan's side

    /// Items for a day's plan (a meeting's action items, what Flow Lens found): each becomes a task for that day, read
    /// like typed words ("Send the deck by Friday" keeps its deadline). One that's already a task moves up to that day.
    /// Nothing is capped or dropped.
    func carry(_ items: [String], context: String, source: TaskSource, to day: Date) {
        let day = calendar.startOfDay(for: day)
        for item in items {
            let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var draft = TaskParser.parse(text, now: now, calendar: calendar)
            if draft.title.isEmpty { draft.title = text }
            let key = ReminderMerge.normalize(draft.title)
            if let existing = tasks.first(where: { $0.isOpen && ReminderMerge.normalize($0.title) == key }) {
                if existing.when.map({ $0 > day }) ?? true {
                    update(existing.id) {
                        $0.scheduled = day
                        $0.someday = false
                        if $0.context == nil { $0.context = context }
                    }
                }
                continue
            }
            if draft.scheduled == nil { draft.scheduled = day }
            draft.someday = false
            add(draft, source: source, context: context)
        }
    }

    /// A day's unfinished tasks move to `day`, so they open the next morning's Today rather than trailing as overdue.
    func rollForward(_ ids: [UUID], to day: Date, context: String) {
        let day = calendar.startOfDay(for: day)
        for id in ids {
            guard let t = task(id: id), t.isOpen, (t.scheduled.map { $0 < day } ?? true) else { continue }
            update(id) {
                $0.scheduled = day
                $0.context = context
            }
        }
    }

    /// A priority in a plan that's been made: its task, planned for its block (made now if it's new).
    @discardableResult
    func plan(_ title: String, task id: UUID?, at start: Date, minutes: Int, context: String?) -> UUID? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        if let id, let t = task(id: id) {
            update(id) {
                $0.title = title
                $0.scheduled = start
                $0.someday = false
                $0.estimate = Double(minutes)
                $0.estimateIsUser = true
                if $0.status == .done { $0.status = .open; $0.completed = nil }
            }
            return t.id
        }
        return add(TaskDraft(title: title, scheduled: start, estimate: Double(minutes)), source: .plan, context: context)?.id
    }

    // MARK: - Scheduling

    func schedule(_ id: UUID, on day: Date?) {
        update(id) {
            $0.scheduled = day
            if day != nil { $0.someday = false }
        }
    }

    func parkSomeday(_ id: UUID) {
        update(id) {
            $0.someday = true
            $0.scheduled = nil
        }
    }

    /// The Brain's estimate, kept only where you haven't given your own.
    func suggestEstimate(_ id: UUID, minutes: Double) {
        guard let t = task(id: id), !t.estimateIsUser, minutes > 0 else { return }
        update(id) { $0.estimate = minutes.rounded() }
    }

    // MARK: - Focus

    /// Starts a focus block for a task: the timer runs under its name, and its time is counted.
    func startFocus(_ id: UUID) {
        guard let t = task(id: id), t.isOpen else { return }
        focusTarget = id
        let minutes = Int(min(180, max(15, t.estimate ?? 25)).rounded())
        RoomStore.shared.setRoom(title: t.title, minutes: minutes)
    }

    private func focusChanged(_ phase: FocusTimer.Phase) {
        let timer = FocusTimer.shared
        guard timer.phase == phase else { return }
        switch phase {
        case .running:
            let target = focusTarget.flatMap { id in task(id: id).flatMap { $0.title == timer.label ? $0 : nil } } ?? match(label: timer.label)
            focusTarget = nil
            if let current = focus, current.id != target?.id { endFocus() }
            if let target, focus == nil { beginFocus(target.id) }
        case .paused, .idle:
            if focus != nil { endFocus() }
        }
    }

    /// The task a timer label stands for: a plan block's task, else an open task with that title.
    private func match(label: String) -> FlowTask? {
        if let id = PlanStore.shared.plan.items.first(where: { $0.title == label && $0.taskID != nil })?.taskID,
           let t = task(id: id), t.isOpen { return t }
        let key = ReminderMerge.normalize(label)
        return tasks.filter { $0.isOpen && ReminderMerge.normalize($0.title) == key }.max { $0.order > $1.order }
    }

    func beginFocus(_ id: UUID) {
        let now = self.now
        focus = (id, now)
        update(id) { $0.status = .active }
        guard let t = task(id: id) else { return }
        active.begin(t, at: now)
        TaskEvents.send(.started(t.snapshot))
    }

    func endFocus() {
        guard let f = focus else { return }
        focus = nil
        let spent = max(0, now.timeIntervalSince(f.since))
        active.end()
        update(f.id) {
            $0.actual += spent
            if $0.status == .active { $0.status = .open }
        }
        if let t = task(id: f.id) { TaskEvents.send(.paused(t.snapshot, focused: spent)) }
    }

    // MARK: - Sync's side

    /// Applies what a Reminders sync decided. A task changed here while the round ran keeps its change and its old
    /// base, and is merged again next round.
    func applySync(_ outcome: SyncOutcome, readAt revisions: [UUID: [TaskField: Date]]) {
        let now = self.now
        let skipped = Set(outcome.pulls.map(\.id).filter { id in task(id: id).map { $0.stamps != revisions[id] } ?? true })
        var save = Set<UUID>()
        for (id, reminderID) in outcome.links {
            if let i = tasks.firstIndex(where: { $0.id == id }) {
                tasks[i].reminderID = reminderID
                save.insert(id)
            } else {
                // Deleted here while its reminder was being made: that reminder goes next round.
                tombstones[reminderID] = now
                database?.delete(id, tombstone: reminderID)
            }
        }
        for (id, base) in outcome.bases where !skipped.contains(id) && task(id: id) != nil {
            bases[id] = base
            save.insert(id)
        }
        for change in outcome.pulls where !skipped.contains(change.id) {
            update(change.id, at: change.stamp, fromSync: true) {
                $0.apply(change.fields, fields: change.which, completedAt: change.completedAt, at: change.stamp)
            }
        }
        for id in outcome.unlinked {
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { continue }
            tasks[i].reminderID = nil
            bases[id] = nil
            save.insert(id)
        }
        for t in outcome.adopted where !tasks.contains(where: { $0.reminderID == t.reminderID }) {
            var t = t
            t.order = nextOrder
            bases[t.id] = t.reminderFields
            insert(t, notify: false)
        }
        for id in outcome.deleted {
            guard let t = task(id: id), t.stamps == revisions[id] else { continue }
            tasks.removeAll { $0.id == id }
            bases[id] = nil
            database?.delete(id, tombstone: nil)
            TaskEvents.send(.deleted(id))
        }
        for r in outcome.clearedTombstones where tombstones.removeValue(forKey: r) != nil {
            database?.clearTombstone(r)
        }
        for id in save { if let t = task(id: id) { persist(t) } }
        changed(localOnly: true)
        if !skipped.isEmpty { onLocalChange?() }
    }

    func syncState() -> (locals: [LocalSyncState], tombstones: Set<String>, revisions: [UUID: [TaskField: Date]]) {
        let now = self.now
        let locals = tasks.filter { $0.status != .dropped }.map { t in
            LocalSyncState(id: t.id, reminderID: t.reminderID, fields: t.reminderFields, stamps: t.reminderStamps, base: bases[t.id],
                           pushable: t.isOpen || (t.completed.map { now.timeIntervalSince($0) < 86_400 } ?? false), created: t.created)
        }
        return (locals, Set(tombstones.keys), Dictionary(tasks.map { ($0.id, $0.stamps) }, uniquingKeysWith: { a, _ in a }))
    }

    // MARK: - Plumbing

    private func persist(_ t: FlowTask) { database?.save(t, base: bases[t.id]) }

    private func changed(localOnly: Bool = false) {
        revision &+= 1
        if !localOnly { onLocalChange?() }
    }

    func flush() { database?.flush() }

    #if DEBUG
    /// Demo tasks for snapshots: in memory only.
    func debugSet(_ list: [FlowTask], active a: UUID? = nil, since: Date? = nil) {
        tasks = list
        lingering = []
        if let a, let t = task(id: a) {
            focus = (a, since ?? now)
            active.begin(t, at: since ?? now)
        } else {
            focus = nil
            active.end()
        }
        changed(localOnly: true)
    }
    #endif
}
