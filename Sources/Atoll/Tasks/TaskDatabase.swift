import Foundation
import SQLite3

/// Flow Tasks' own SQLite file (`Tasks.sqlite`, next to the Brain's, owner-only). The task list lives in memory
/// on the main thread; every change is written here on a serial queue, so the main thread never waits on disk.
final class TaskDatabase: @unchecked Sendable {
    /// A reminder deleted here, waiting for the next sync to delete it in Reminders too.
    struct Tombstone: Hashable, Sendable {
        var reminderID: String
        var deleted: Date
    }

    struct Contents: Sendable {
        var tasks: [FlowTask] = []
        /// Each synced task's fields as Reminders last had them: the common ancestor for a three-way merge.
        var bases: [UUID: ReminderFields] = [:]
        var projects: [FlowProject] = []
        var tombstones: [Tombstone] = []
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "atoll.tasks.store", qos: .utility)
    let url: URL

    init(url: URL) {
        self.url = url
        queue.sync { open() }
    }

    static var defaultURL: URL { Storage.directory.appendingPathComponent("Tasks.sqlite") }

    private func open() {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { db = nil; return }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY, title TEXT, notes TEXT, project TEXT, due REAL, scheduled REAL,
            estimate REAL, estimate_user INTEGER, priority INTEGER, status TEXT, source TEXT, actual REAL, created REAL, completed REAL,
            reminder TEXT, ord REAL, someday INTEGER, context TEXT, repeats TEXT, stamps TEXT, base TEXT);
        CREATE INDEX IF NOT EXISTS tasks_status ON tasks(status);
        CREATE TABLE IF NOT EXISTS projects(name TEXT PRIMARY KEY, created REAL, ord REAL);
        CREATE TABLE IF NOT EXISTS tombstones(reminder TEXT PRIMARY KEY, deleted REAL);
        """)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
        }
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func run(_ sql: String, _ binds: [Any?], _ row: ((OpaquePointer) -> Void)? = nil) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW { row?(stmt) }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_text(s, i).map { String(cString: $0) }
    }
    private static func real(_ s: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }
    private static func date(_ s: OpaquePointer, _ i: Int32) -> Date? { real(s, i).map { Date(timeIntervalSince1970: $0) } }

    private static func json<T: Encodable>(_ v: T?) -> String? {
        guard let v, let data = try? JSONEncoder().encode(v) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ s: String?) -> T? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Reading (once, at launch)

    func load() -> Contents {
        queue.sync {
            var out = Contents()
            run("SELECT id, title, notes, project, due, scheduled, estimate, estimate_user, priority, status, source, actual, created, completed, reminder, ord, someday, context, repeats, stamps, base FROM tasks", []) { s in
                guard let id = Self.text(s, 0).flatMap(UUID.init(uuidString:)) else { return }
                var t = FlowTask(id: id, title: Self.text(s, 1) ?? "")
                t.notes = Self.text(s, 2) ?? ""
                t.project = Self.text(s, 3)
                t.due = Self.date(s, 4)
                t.scheduled = Self.date(s, 5)
                t.estimate = Self.real(s, 6)
                t.estimateIsUser = sqlite3_column_int64(s, 7) != 0
                t.priority = TaskPriority(rawValue: Int(sqlite3_column_int64(s, 8))) ?? .none
                t.status = Self.text(s, 9).flatMap(TaskStatus.init(rawValue:)) ?? .open
                t.source = Self.text(s, 10).flatMap(TaskSource.init(rawValue:)) ?? .typed
                t.actual = Self.real(s, 11) ?? 0
                t.created = Self.date(s, 12) ?? Date()
                t.completed = Self.date(s, 13)
                t.reminderID = Self.text(s, 14)
                t.order = Self.real(s, 15) ?? 0
                t.someday = sqlite3_column_int64(s, 16) != 0
                t.context = Self.text(s, 17)
                t.repeats = Self.decode(RepeatRule.self, Self.text(s, 18))
                t.stamps = Self.decode([TaskField: Date].self, Self.text(s, 19)) ?? [:]
                out.tasks.append(t)
                if let base = Self.decode(ReminderFields.self, Self.text(s, 20)) { out.bases[id] = base }
            }
            run("SELECT name, created, ord FROM projects ORDER BY ord", []) { s in
                out.projects.append(FlowProject(name: Self.text(s, 0) ?? "", created: Self.date(s, 1) ?? Date(), order: Self.real(s, 2) ?? 0))
            }
            run("SELECT reminder, deleted FROM tombstones", []) { s in
                if let r = Self.text(s, 0) { out.tombstones.append(Tombstone(reminderID: r, deleted: Self.date(s, 1) ?? Date())) }
            }
            return out
        }
    }

    // MARK: Writing (queued)

    func save(_ t: FlowTask, base: ReminderFields?) {
        queue.async {
            self.run("""
            INSERT OR REPLACE INTO tasks(id, title, notes, project, due, scheduled, estimate, estimate_user, priority, status, source, actual,
                created, completed, reminder, ord, someday, context, repeats, stamps, base) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [t.id.uuidString, t.title, t.notes, t.project, t.due?.timeIntervalSince1970, t.scheduled?.timeIntervalSince1970, t.estimate,
                  t.estimateIsUser, t.priority.rawValue, t.status.rawValue, t.source.rawValue, t.actual, t.created.timeIntervalSince1970,
                  t.completed?.timeIntervalSince1970, t.reminderID, t.order, t.someday, t.context, Self.json(t.repeats), Self.json(t.stamps),
                  Self.json(base)])
        }
    }

    func delete(_ id: UUID, tombstone: String?) {
        queue.async {
            self.run("DELETE FROM tasks WHERE id = ?", [id.uuidString])
            if let tombstone { self.run("INSERT OR REPLACE INTO tombstones(reminder, deleted) VALUES(?,?)", [tombstone, Date().timeIntervalSince1970]) }
        }
    }

    func clearTombstone(_ reminderID: String) {
        queue.async { self.run("DELETE FROM tombstones WHERE reminder = ?", [reminderID]) }
    }

    func save(_ p: FlowProject) {
        queue.async { self.run("INSERT OR REPLACE INTO projects(name, created, ord) VALUES(?,?,?)", [p.name, p.created.timeIntervalSince1970, p.order]) }
    }

    func eraseEverything() {
        queue.sync { exec("DELETE FROM tasks; DELETE FROM projects; DELETE FROM tombstones; VACUUM;") }
    }

    /// Waits for queued writes (at quit, and in tests).
    func flush() { queue.sync {} }

    deinit { sqlite3_close(db) }
}
