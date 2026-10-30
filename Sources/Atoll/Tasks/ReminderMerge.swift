import Foundation

// Two-way sync with Apple Reminders, as pure logic: what to create, link, merge, import and delete, and how two
// edits to the same task meet. EventKit never appears here (`ReminderSync` does the talking), so every rule
// below is tested on plain values.

/// The parts of a task Reminders also holds.
struct ReminderFields: Codable, Hashable, Sendable {
    var title: String
    var notes: String
    /// The reminder's date: the task's planned day, or its due date when it has no plan. Midnight = no time.
    var date: Date?
    var priority: TaskPriority
    var completed: Bool

    static func same(_ f: ReminderField, _ a: ReminderFields, _ b: ReminderFields) -> Bool {
        switch f {
        case .title: return a.title == b.title
        case .notes: return a.notes == b.notes
        // Reminders keeps dates to the minute.
        case .date:
            switch (a.date, b.date) {
            case (nil, nil): return true
            case let (x?, y?): return abs(x.timeIntervalSince(y)) < 30
            default: return false
            }
        case .priority: return a.priority == b.priority
        case .completed: return a.completed == b.completed
        }
    }

    mutating func take(_ f: ReminderField, from o: ReminderFields) {
        switch f {
        case .title: title = o.title
        case .notes: notes = o.notes
        case .date: date = o.date
        case .priority: priority = o.priority
        case .completed: completed = o.completed
        }
    }
}

enum ReminderField: String, CaseIterable, Codable, Sendable {
    case title, notes, date, priority, completed
}

/// One reminder, read out of EventKit into plain values.
struct RemoteReminder: Hashable, Sendable {
    var id: String
    var fields: ReminderFields
    /// When Reminders last changed it (any field: Reminders doesn't say which).
    var modified: Date?
    var completedAt: Date?
}

/// One task as the sync sees it.
struct LocalSyncState: Sendable {
    var id: UUID
    var reminderID: String?
    var fields: ReminderFields
    /// When each field last changed here.
    var stamps: [ReminderField: Date]
    /// The fields as Reminders had them after the last sync.
    var base: ReminderFields?
    /// Whether it should go to Reminders if it isn't there yet (finished history isn't pushed).
    var pushable: Bool
    var created: Date
}

enum ReminderMerge {
    struct Result: Equatable {
        /// What both sides should now hold.
        var fields: ReminderFields
        /// Fields Reminders won, to apply here.
        var pull: Set<ReminderField>
        /// Whether Reminders needs updating.
        var push: Bool
    }

    /// A three-way merge, field by field. A field changed on one side only takes that side's value; changed on both
    /// (or never synced before), the later edit wins — this Mac's per-field time against the reminder's last-modified time.
    static func merge(local: ReminderFields, stamps: [ReminderField: Date], base: ReminderFields?,
                      remote: ReminderFields, remoteModified: Date?) -> Result {
        var out = local
        var pull = Set<ReminderField>()
        for f in ReminderField.allCases where !ReminderFields.same(f, local, remote) {
            let localChanged = base.map { !ReminderFields.same(f, local, $0) } ?? true
            let remoteChanged = base.map { !ReminderFields.same(f, remote, $0) } ?? true
            let remoteWins: Bool
            switch (localChanged, remoteChanged) {
            case (true, false): remoteWins = false
            case (false, true): remoteWins = true
            default: remoteWins = (remoteModified ?? .distantPast) > (stamps[f] ?? .distantPast)
            }
            if remoteWins {
                out.take(f, from: remote)
                pull.insert(f)
            }
        }
        return Result(fields: out, pull: pull, push: ReminderField.allCases.contains { !ReminderFields.same($0, out, remote) })
    }

    enum Step: Hashable {
        /// Push a new reminder for this task.
        case create(UUID)
        /// Pair a task with a reminder that already has its title (a first sync, or a link lost in a crash), then merge.
        case link(UUID, String)
        case merge(UUID, String)
        /// A reminder added elsewhere becomes a task.
        case adopt(String)
        /// Its reminder was deleted in Reminders.
        case deleteTask(UUID)
        /// Its task was deleted here.
        case deleteReminder(String)
    }

    /// Decides one sync round. `missing` holds linked reminders confirmed gone (looked up by identifier, not found):
    /// only those delete tasks, so a failed or partial fetch never does.
    static func plan(locals: [LocalSyncState], remotes: [RemoteReminder], tombstones: Set<String>, missing: Set<String>) -> [Step] {
        var steps: [Step] = []
        let byID = Dictionary(remotes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var claimed = Set<String>()

        for t in tombstones.sorted() where byID[t] != nil {
            steps.append(.deleteReminder(t))
            claimed.insert(t)
        }
        let linkedIDs = Set(locals.compactMap(\.reminderID))
        var gone: [LocalSyncState] = []
        for l in locals {
            guard let r = l.reminderID else { continue }
            if byID[r] != nil, !tombstones.contains(r) {
                steps.append(.merge(l.id, r))
                claimed.insert(r)
            } else if missing.contains(r) {
                gone.append(l)
            }
        }
        // Unpaired reminders, by title, oldest first, waiting to be matched before anything is created.
        var pool: [String: [RemoteReminder]] = [:]
        for r in remotes where !claimed.contains(r.id) && !linkedIDs.contains(r.id) {
            pool[normalize(r.fields.title), default: []].append(r)
        }
        // A reminder that changed identity (EventKit can reissue them after a full resync) is the same title under a
        // new identifier: follow it rather than delete the task and adopt a copy.
        for l in gone {
            let key = normalize(l.fields.title)
            if let i = pool[key]?.firstIndex(where: { $0.fields.completed == l.fields.completed }), let match = pool[key]?.remove(at: i) {
                steps.append(.link(l.id, match.id))
            } else {
                steps.append(.deleteTask(l.id))
            }
        }
        for l in locals.filter({ $0.reminderID == nil }).sorted(by: { $0.created < $1.created }) {
            let key = normalize(l.fields.title)
            if let i = pool[key]?.firstIndex(where: { $0.fields.completed == l.fields.completed }), let match = pool[key]?.remove(at: i) {
                steps.append(.link(l.id, match.id))
            } else if l.pushable {
                steps.append(.create(l.id))
            }
        }
        for r in pool.values.flatMap({ $0 }).sorted(by: { $0.id < $1.id }) where !r.fields.completed {
            steps.append(.adopt(r.id))
        }
        return steps
    }

    static func normalize(_ title: String) -> String {
        title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// One whole round against Reminders: read, decide, write there, and say what changes here.
    static func round(_ backend: ReminderBackend, locals: [LocalSyncState], tombstones: Set<String>, now: Date = Date()) -> SyncOutcome {
        var out = SyncOutcome()
        guard let fetched = backend.fetch() else { out.error = "Couldn’t read Reminders"; return out }
        var byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Linked reminders not in the list (finished long ago, or moved to another list) are followed by identifier;
        // only ones that can't be found at all count as deleted.
        var missing = Set<String>()
        for id in Set(locals.compactMap(\.reminderID)).union(tombstones) where byID[id] == nil {
            if let r = backend.lookup(id) { byID[id] = r } else { missing.insert(id) }
        }
        // Everything vanishing at once is a list deleted or reset, not a run of deliberate deletions: unlink, push again.
        let linked = locals.filter { $0.reminderID != nil }
        let gone = linked.filter { missing.contains($0.reminderID ?? "") }
        if gone.count > 3, gone.count * 2 > linked.count {
            out.unlinked = gone.map(\.id)
            missing.subtract(gone.compactMap(\.reminderID))
        }
        let unlinked = Set(out.unlinked)
        let localByID = Dictionary(locals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let steps = plan(locals: locals.filter { !unlinked.contains($0.id) }, remotes: Array(byID.values), tombstones: tombstones, missing: missing)

        for step in steps {
            switch step {
            case .create(let id):
                guard let local = localByID[id], let made = backend.create(local.fields) else { continue }
                out.links[id] = made.id
                out.bases[id] = made.fields
            case .link(let id, let rid), .merge(let id, let rid):
                guard let local = localByID[id], let remote = byID[rid] else { continue }
                var isLink = false
                if case .link = step { isLink = true }
                let result = merge(local: local.fields, stamps: local.stamps, base: isLink ? nil : local.base,
                                   remote: remote.fields, remoteModified: remote.modified)
                var saved = remote
                if result.push {
                    let changed = Set(ReminderField.allCases.filter { !ReminderFields.same($0, result.fields, remote.fields) })
                    guard let r = backend.update(rid, to: result.fields, only: changed) else { continue }
                    saved = r
                }
                if isLink { out.links[id] = rid }
                if !result.pull.isEmpty {
                    out.pulls.append(SyncOutcome.Pull(id: id, fields: result.fields, which: result.pull,
                                                      completedAt: remote.completedAt, stamp: remote.modified ?? now))
                }
                out.bases[id] = saved.fields
            case .adopt(let rid):
                guard let remote = byID[rid] else { continue }
                out.adopted.append(FlowTask.adopting(remote, order: 0))
            case .deleteTask(let id):
                out.deleted.append(id)
            case .deleteReminder(let rid):
                if backend.delete(rid) { out.clearedTombstones.append(rid) }
            }
        }
        // Tombstones whose reminder is already gone have nothing left to do.
        out.clearedTombstones += tombstones.filter { byID[$0] == nil }
        guard backend.commit() else { return SyncOutcome(error: "Couldn’t save to Reminders") }
        return out
    }
}

/// Reminders as a sync round needs it: plain values in and out. EventKit is one (`EventKitReminders`); tests use another.
protocol ReminderBackend {
    /// The list's reminders (open, and recently finished), or nil when they couldn't be read.
    func fetch() -> [RemoteReminder]?
    /// A reminder wherever it is now (another list, finished long ago); nil once it no longer exists.
    func lookup(_ id: String) -> RemoteReminder?
    /// Makes a reminder in the list; returns it as saved.
    func create(_ fields: ReminderFields) -> RemoteReminder?
    /// Changes these fields of a reminder; returns it as saved.
    func update(_ id: String, to fields: ReminderFields, only: Set<ReminderField>) -> RemoteReminder?
    func delete(_ id: String) -> Bool
    /// Makes the round's writes permanent; false means they were all undone.
    func commit() -> Bool
}

/// What a sync round changes on this Mac.
struct SyncOutcome: Sendable {
    struct Pull: Sendable {
        var id: UUID
        var fields: ReminderFields
        var which: Set<ReminderField>
        var completedAt: Date?
        var stamp: Date
    }
    var links: [UUID: String] = [:]
    var bases: [UUID: ReminderFields] = [:]
    var pulls: [Pull] = []
    var adopted: [FlowTask] = []
    var deleted: [UUID] = []
    /// Links to forget (their reminders vanished all at once — a list deleted or reset): pushed again next round.
    var unlinked: [UUID] = []
    var clearedTombstones: [String] = []
    var error: String?
}

// MARK: - Tasks ↔ reminder fields

extension FlowTask {
    /// This task as Reminders would hold it.
    var reminderFields: ReminderFields {
        ReminderFields(title: title, notes: notes, date: scheduled ?? due, priority: priority, completed: status == .done)
    }

    /// When each reminder field last changed here.
    var reminderStamps: [ReminderField: Date] {
        var out: [ReminderField: Date] = [:]
        out[.title] = stamps[.title]
        out[.notes] = stamps[.notes]
        out[.date] = [stamps[.scheduled], stamps[.due]].compactMap { $0 }.max()
        out[.priority] = stamps[.priority]
        out[.completed] = stamps[.status]
        return out
    }

    /// Takes the fields Reminders won. A date lands where this task keeps its date: its plan if it has one, else its
    /// due date; a date added on the iPhone to an undated task is a plan ("do it then"), as Reminders' Today reads it.
    mutating func apply(_ remote: ReminderFields, fields: Set<ReminderField>, completedAt: Date?, at stamp: Date) {
        for f in fields {
            switch f {
            case .title:
                title = remote.title
                touch(.title, at: stamp)
            case .notes:
                notes = remote.notes
                touch(.notes, at: stamp)
            case .date:
                if scheduled != nil || due == nil {
                    scheduled = remote.date
                    touch(.scheduled, at: stamp)
                } else {
                    due = remote.date
                    touch(.due, at: stamp)
                }
                if remote.date != nil { someday = false }
            case .priority:
                priority = remote.priority
                touch(.priority, at: stamp)
            case .completed:
                status = remote.completed ? .done : .open
                completed = remote.completed ? (completedAt ?? stamp) : nil
                touch(.status, at: stamp)
            }
        }
    }

    /// A reminder from elsewhere, as a new task.
    static func adopting(_ r: RemoteReminder, order: Double) -> FlowTask {
        var t = FlowTask(title: r.fields.title.isEmpty ? "Untitled" : r.fields.title)
        t.notes = r.fields.notes
        t.scheduled = r.fields.date
        t.priority = r.fields.priority
        t.status = r.fields.completed ? .done : .open
        t.completed = r.fields.completed ? (r.completedAt ?? r.modified ?? Date()) : nil
        t.source = .reminders
        t.reminderID = r.id
        t.order = order
        t.created = r.modified ?? Date()
        let stamp = r.modified ?? Date()
        for f in TaskField.allCases { t.stamps[f] = stamp }
        return t
    }
}

extension TaskPriority {
    /// Reminders' scale: 1–4 high, 5 medium, 6–9 low, 0 none.
    var reminderValue: Int {
        switch self {
        case .none: 0
        case .high: 1
        case .medium: 5
        case .low: 9
        }
    }

    init(reminderValue v: Int) {
        switch v {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
}
