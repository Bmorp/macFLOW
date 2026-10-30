import Foundation
import SQLite3

/// The Brain's memory: a private SQLite database in Atoll's Application Support folder.
/// Raw observations (events), condensed work sessions (episodes), learned facts, and how you
/// reacted to each kind of suggestion. Nothing leaves the Mac.
final class BrainStore: @unchecked Sendable {
    static let shared = BrainStore()

    struct Event: Sendable {
        var ts: Date
        var kind: String          // app, window, media, calendar, claude, clipboard, call, idle, screen
        var app: String = ""
        var bundle: String = ""
        var title: String = ""
        var detail: String = ""
        var duration: TimeInterval = 0
    }

    struct Episode: Sendable, Identifiable {
        var id: Int64 = 0
        var start: Date
        var end: Date
        var mode: String
        var project: String
        var apps: [String]
        var summary: String
    }

    /// A moment of the day, every few minutes and at each change: enough to say what you were doing and reopen it.
    struct Moment: Sendable, Identifiable, Equatable, Codable {
        var id: Int64 = 0
        var ts: Date
        var mode: String
        var project: String = ""
        var bundle: String = ""
        var app: String = ""
        var title: String = ""
        /// The front window's document (a file URL), when the app reports one.
        var document: String = ""
        /// "Title — Artist" of what was playing.
        var track: String = ""
        /// The Claude session in front, by folder.
        var claude: String = ""
    }

    struct Fact: Sendable, Identifiable {
        var id: String { key }
        let key: String
        let value: String
        let source: String        // learned, answered, inferred
        /// How sure Flow was when it was written, 0…1. Read through `confidence(at:)`, which lets it fade.
        let confidence: Double
        let updated: Date

        /// How sure Flow is now. What you answered fades over months (people change); what Flow inferred from
        /// watching fades over weeks unless it's seen again; bookkeeping ("inferred") doesn't fade.
        func confidence(at now: Date = Date()) -> Double {
            let halfLife: TimeInterval? = switch source {
            case "answered": 180 * 86_400
            case "learned": 30 * 86_400
            default: nil
            }
            guard let halfLife else { return confidence }
            return confidence * pow(0.5, max(0, now.timeIntervalSince(updated)) / halfLife)
        }

        /// Below half: worth checking again rather than acting on.
        func isStale(at now: Date = Date()) -> Bool { confidence(at: now) < 0.5 }
    }

    /// A question Flow asked, and what happened.
    struct Asked: Sendable, Equatable {
        let key: String
        var asked: Date
        var answered: Date?
        var answer: String?
        /// How many times it has been put to you.
        var times: Int
        /// "Don't ask again" (and questions that expired unanswered).
        var skips: Int
    }

    /// You said a moment was really a different kind of work.
    struct Correction: Sendable, Equatable, Identifiable {
        var id: Int64 = 0
        var ts: Date
        var bundle: String
        var app: String
        var title: String
        var project: String
        var from: String
        var to: String
    }

    /// A finished task, as the duration estimator learns from it.
    struct TaskExample: Sendable, Equatable, Codable {
        var id: String
        var ts: Date
        var title: String
        var project: String
        var mode: String
        /// Focused minutes it actually took.
        var minutes: Double
        /// What you estimated, if you did.
        var estimate: Double?
    }

    private var db: OpaquePointer?
    /// In-memory mirrors so the main thread never waits on SQLite.
    private let cacheLock = NSLock()
    private var factCache: [String: Fact]?
    private var reactionCache: [String: (accepted: Int, dismissed: Int, ignored: Int)] = [:]
    private var shownTimes: [Date] = []
    private var askedCache: [String: Asked]?
    private var eraseHandlers: [@Sendable () -> Void] = []
    private let queue = DispatchQueue(label: "atoll.brain.store")
    /// Writes handed to the queue that haven't landed yet (guarded by `cacheLock`). Reads from the separate
    /// reader connections wait for these, so a value you just wrote is always the value you read back.
    private var pendingWrites = 0
    private let url: URL
    /// Reads never wait behind the writer or the Brain's long background scans (a week of events, thousands
    /// of rows): the main thread has a read-only connection of its own — WAL lets readers run beside the
    /// writer — and background readers share another. Used to be one queue, so switching apps could stall
    /// the main thread (and the island) behind an insight being computed.
    private var mainReader: OpaquePointer?
    private var reader: OpaquePointer?
    private let readQueue = DispatchQueue(label: "atoll.brain.read")

    init(url: URL? = nil) {
        self.url = url ?? Storage.directory.appendingPathComponent("Brain.sqlite")
        queue.sync { open() }
    }

    private func open() {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { db = nil; return }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY, ts REAL, kind TEXT, app TEXT, bundle TEXT, title TEXT, detail TEXT, duration REAL);
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        CREATE TABLE IF NOT EXISTS episodes(id INTEGER PRIMARY KEY, start REAL, end REAL, mode TEXT, project TEXT, apps TEXT, summary TEXT);
        CREATE INDEX IF NOT EXISTS episodes_start ON episodes(start);
        CREATE TABLE IF NOT EXISTS facts(key TEXT PRIMARY KEY, value TEXT, source TEXT, confidence REAL, updated REAL);
        CREATE TABLE IF NOT EXISTS feedback(id INTEGER PRIMARY KEY, ts REAL, kind TEXT, outcome TEXT);
        CREATE TABLE IF NOT EXISTS moments(id INTEGER PRIMARY KEY, ts REAL, mode TEXT, project TEXT, bundle TEXT, app TEXT, title TEXT, document TEXT, track TEXT, claude TEXT);
        CREATE INDEX IF NOT EXISTS moments_ts ON moments(ts);
        CREATE TABLE IF NOT EXISTS learners(key TEXT PRIMARY KEY, state TEXT, updated REAL);
        CREATE TABLE IF NOT EXISTS questions(key TEXT PRIMARY KEY, asked REAL, answered REAL, answer TEXT, times INTEGER, skips INTEGER);
        CREATE TABLE IF NOT EXISTS corrections(id INTEGER PRIMARY KEY, ts REAL, bundle TEXT, app TEXT, title TEXT, project TEXT, mode_from TEXT, mode_to TEXT);
        CREATE TABLE IF NOT EXISTS task_examples(id TEXT PRIMARY KEY, ts REAL, title TEXT, project TEXT, mode TEXT, minutes REAL, estimate REAL);
        """)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func openReader() -> OpaquePointer? {
        var conn: OpaquePointer?
        guard db != nil, sqlite3_open_v2(url.path, &conn, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(conn)
            return nil
        }
        sqlite3_busy_timeout(conn, 200)
        return conn
    }

    /// Queues a write. Counted until it lands, so reads can tell when they would otherwise see the past.
    private func write(_ body: @escaping () -> Void) {
        cacheLock.lock(); pendingWrites += 1; cacheLock.unlock()
        queue.async {
            body()
            self.cacheLock.lock(); self.pendingWrites -= 1; self.cacheLock.unlock()
        }
    }

    /// A sync point: returns once every write queued before the call has landed.
    func flush() { queue.sync {} }

    /// Waits for queued writes, if there are any. They are single-row inserts, so the wait is a moment; with nothing
    /// queued (the usual case) a read never touches the writer's queue.
    private func settle() {
        cacheLock.lock(); let waiting = pendingWrites > 0; cacheLock.unlock()
        if waiting { queue.sync {} }
    }

    private func read<T>(_ body: (OpaquePointer?) -> T) -> T {
        settle()
        if Thread.isMainThread {
            if mainReader == nil { mainReader = openReader() }
            if let conn = mainReader { return body(conn) }
        } else if let result = readQueue.sync(execute: { () -> T? in
            if reader == nil { reader = openReader() }
            return reader.map(body)
        }) {
            return result
        }
        return queue.sync { body(db) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func run(_ sql: String, _ binds: [Any?], on conn: OpaquePointer? = nil, _ row: ((OpaquePointer) -> Void)? = nil) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn ?? db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW { row?(stmt) }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    // MARK: Events

    func record(_ e: Event) {
        write {
            self.run("INSERT INTO events(ts, kind, app, bundle, title, detail, duration) VALUES(?,?,?,?,?,?,?)",
                     [e.ts.timeIntervalSince1970, e.kind, e.app, e.bundle, String(e.title.prefix(300)), String(e.detail.prefix(600)), e.duration])
        }
    }

    func events(since: Date, kinds: [String]? = nil, limit: Int = 2000) -> [Event] {
        read { conn in
            var out: [Event] = []
            let filter = kinds.map { " AND kind IN (" + $0.map { "'\($0)'" }.joined(separator: ",") + ")" } ?? ""
            run("SELECT ts, kind, app, bundle, title, detail, duration FROM events WHERE ts >= ?\(filter) ORDER BY ts DESC LIMIT ?", [since.timeIntervalSince1970, limit], on: conn) { s in
                out.append(Event(ts: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), kind: Self.text(s, 1), app: Self.text(s, 2),
                                 bundle: Self.text(s, 3), title: Self.text(s, 4), detail: Self.text(s, 5), duration: sqlite3_column_double(s, 6)))
            }
            return out
        }
    }

    /// Seconds spent per app (foreground), most first.
    func appTime(since: Date) -> [(app: String, seconds: Double)] {
        read { conn in
            var out: [(String, Double)] = []
            run("SELECT app, SUM(duration) FROM events WHERE kind='app' AND ts >= ? GROUP BY app ORDER BY 2 DESC LIMIT 20", [since.timeIntervalSince1970], on: conn) { s in out.append((Self.text(s, 0), sqlite3_column_double(s, 1))) }
            return out
        }
    }

    // MARK: Episodes

    func save(_ ep: Episode) {
        write {
            self.run("INSERT INTO episodes(start, end, mode, project, apps, summary) VALUES(?,?,?,?,?,?)",
                     [ep.start.timeIntervalSince1970, ep.end.timeIntervalSince1970, ep.mode, ep.project, ep.apps.joined(separator: ","), ep.summary])
        }
    }

    func episodes(since: Date, limit: Int = 200) -> [Episode] {
        read { conn in
            var out: [Episode] = []
            run("SELECT id, start, end, mode, project, apps, summary FROM episodes WHERE start >= ? ORDER BY start DESC LIMIT ?", [since.timeIntervalSince1970, limit], on: conn) { s in
                out.append(Episode(id: sqlite3_column_int64(s, 0), start: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                   end: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)), mode: Self.text(s, 3), project: Self.text(s, 4),
                                   apps: Self.text(s, 5).split(separator: ",").map(String.init), summary: Self.text(s, 6)))
            }
            return out
        }
    }

    func deleteEpisode(_ id: Int64) { write { self.run("DELETE FROM episodes WHERE id = ?", [id]) } }

    // MARK: Moments

    func record(_ m: Moment) {
        write {
            self.run("INSERT INTO moments(ts, mode, project, bundle, app, title, document, track, claude) VALUES(?,?,?,?,?,?,?,?,?)",
                     [m.ts.timeIntervalSince1970, m.mode, m.project, m.bundle, m.app, String(m.title.prefix(300)), String(m.document.prefix(1000)),
                      String(m.track.prefix(200)), m.claude])
        }
    }

    /// Oldest first.
    func moments(from: Date, to: Date = .distantFuture, limit: Int = 2000) -> [Moment] {
        read { conn in
            var out: [Moment] = []
            run("SELECT id, ts, mode, project, bundle, app, title, document, track, claude FROM moments WHERE ts >= ? AND ts <= ? ORDER BY ts ASC LIMIT ?",
                [from.timeIntervalSince1970, min(to.timeIntervalSince1970, 4_000_000_000), limit], on: conn) { s in
                out.append(Moment(id: sqlite3_column_int64(s, 0), ts: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), mode: Self.text(s, 2),
                                  project: Self.text(s, 3), bundle: Self.text(s, 4), app: Self.text(s, 5), title: Self.text(s, 6),
                                  document: Self.text(s, 7), track: Self.text(s, 8), claude: Self.text(s, 9)))
            }
            return out
        }
    }

    // MARK: Facts

    func setFact(_ key: String, _ value: String, source: String, confidence: Double) {
        cacheLock.lock()
        if factCache != nil { factCache?[key] = Fact(key: key, value: value, source: source, confidence: confidence, updated: Date()) }
        cacheLock.unlock()
        write {
            self.run("INSERT INTO facts(key, value, source, confidence, updated) VALUES(?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, source=excluded.source, confidence=excluded.confidence, updated=excluded.updated",
                     [key, value, source, confidence, Date().timeIntervalSince1970])
        }
    }

    func fact(_ key: String) -> String? {
        loadFactsIfNeeded()
        cacheLock.lock(); defer { cacheLock.unlock() }
        return factCache?[key]?.value
    }

    func facts() -> [Fact] {
        loadFactsIfNeeded()
        cacheLock.lock(); defer { cacheLock.unlock() }
        return (factCache ?? [:]).values.sorted { $0.updated > $1.updated }
    }

    /// The whole fact — source, confidence and age — not just its value.
    func factRecord(_ key: String) -> Fact? {
        loadFactsIfNeeded()
        cacheLock.lock(); defer { cacheLock.unlock() }
        return factCache?[key]
    }

    private func loadFactsIfNeeded() {
        cacheLock.lock()
        let loaded = factCache != nil
        cacheLock.unlock()
        guard !loaded else { return }
        let all = readFacts()
        cacheLock.lock()
        factCache = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        cacheLock.unlock()
    }

    private func readFacts() -> [Fact] {
        read { conn in
            var out: [Fact] = []
            run("SELECT key, value, source, confidence, updated FROM facts ORDER BY updated DESC", [], on: conn) { s in
                out.append(Fact(key: Self.text(s, 0), value: Self.text(s, 1), source: Self.text(s, 2),
                                confidence: sqlite3_column_double(s, 3), updated: Date(timeIntervalSince1970: sqlite3_column_double(s, 4))))
            }
            return out
        }
    }

    func deleteFact(_ key: String) {
        cacheLock.lock(); factCache?[key] = nil; cacheLock.unlock()
        write { self.run("DELETE FROM facts WHERE key = ?", [key]) }
    }

    // MARK: Feedback

    func feedback(_ kind: String, _ outcome: String) {
        cacheLock.lock()
        if outcome == "shown" { shownTimes.append(Date()); shownTimes.removeAll { $0.timeIntervalSinceNow < -86_400 } }
        reactionCache = reactionCache.filter { !$0.key.hasPrefix(kind) }
        cacheLock.unlock()
        write { self.run("INSERT INTO feedback(ts, kind, outcome) VALUES(?,?,?)", [Date().timeIntervalSince1970, kind, outcome]) }
    }

    /// How you've reacted to a kind of suggestion over the last 60 days.
    func reactions(_ kind: String) -> (accepted: Int, dismissed: Int, ignored: Int) {
        cacheLock.lock()
        if let hit = reactionCache[kind] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let value = readReactions(kind)
        cacheLock.lock(); reactionCache[kind] = value; cacheLock.unlock()
        return value
    }

    private func readReactions(_ kind: String, hours: ClosedRange<Int>? = nil) -> (accepted: Int, dismissed: Int, ignored: Int) {
        read { conn in
            var a = 0, d = 0, i = 0
            var sql = "SELECT outcome, COUNT(*) FROM feedback WHERE kind = ? AND ts >= ?"
            var binds: [Any?] = [kind, Date().addingTimeInterval(-60 * 86_400).timeIntervalSince1970]
            if let hours {
                sql += " AND CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER) BETWEEN ? AND ?"
                binds += [hours.lowerBound, hours.upperBound]
            }
            run(sql + " GROUP BY outcome", binds, on: conn) { s in
                let n = Int(sqlite3_column_int64(s, 1))
                // "shown" is not a reaction: it used to count as half an ignore, even for suggestions you then took.
                switch Self.text(s, 0) {
                case "accepted": a = n
                case "dismissed": d = n
                case "ignored": i = n
                default: break
                }
            }
            return (a, d, i)
        }
    }

    /// How you've reacted to a kind of suggestion at this part of the day (morning, afternoon, evening).
    func reactions(_ kind: String, at date: Date) -> (accepted: Int, dismissed: Int, ignored: Int) {
        let h = Calendar.current.component(.hour, from: date)
        let part = h < 12 ? 0...11 : h < 17 ? 12...16 : 17...23
        let key = "\(kind)|\(part.lowerBound)"
        cacheLock.lock()
        if let hit = reactionCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let value = readReactions(kind, hours: part)
        cacheLock.lock(); reactionCache[key] = value; cacheLock.unlock()
        return value
    }

    func suggestionsShown(since: Date) -> Int {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return shownTimes.filter { $0 >= since }.count
    }

    /// Every reaction since a date, oldest first (for replaying history into the learners, and the trend).
    func feedbackRows(since: Date) -> [(ts: Date, kind: String, outcome: String)] {
        read { conn in
            var out: [(Date, String, String)] = []
            run("SELECT ts, kind, outcome FROM feedback WHERE ts >= ? ORDER BY ts ASC", [since.timeIntervalSince1970], on: conn) { s in
                out.append((Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), Self.text(s, 1), Self.text(s, 2)))
            }
            return out
        }
    }

    // MARK: Learners

    /// A learner's state (its weights and counts), as JSON. The learner keeps the live copy; this is for relaunch.
    func saveLearner(_ key: String, _ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        write {
            self.run("INSERT INTO learners(key, state, updated) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET state=excluded.state, updated=excluded.updated",
                     [key, text, Date().timeIntervalSince1970])
        }
    }

    func learnerStates(prefix: String) -> [String: Data] {
        // Through the writer's queue, so a state saved a moment ago is never missed.
        queue.sync {
            var out: [String: Data] = [:]
            run("SELECT key, state FROM learners WHERE key LIKE ?", [prefix + "%"]) { s in out[Self.text(s, 0)] = Data(Self.text(s, 1).utf8) }
            return out
        }
    }

    func deleteLearners(prefix: String) {
        write { self.run("DELETE FROM learners WHERE key LIKE ?", [prefix + "%"]) }
    }

    func deleteLearner(_ key: String) {
        write { self.run("DELETE FROM learners WHERE key = ?", [key]) }
    }

    // MARK: Questions asked

    func askedLog() -> [String: Asked] {
        cacheLock.lock()
        if let hit = askedCache { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let all: [String: Asked] = queue.sync {
            var out: [String: Asked] = [:]
            run("SELECT key, asked, answered, answer, times, skips FROM questions", []) { s in
                let key = Self.text(s, 0)
                let answered = sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 2))
                out[key] = Asked(key: key, asked: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), answered: answered,
                                 answer: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : Self.text(s, 3),
                                 times: Int(sqlite3_column_int64(s, 4)), skips: Int(sqlite3_column_int64(s, 5)))
            }
            return out
        }
        cacheLock.lock()
        if askedCache == nil { askedCache = all }
        let value = askedCache ?? all
        cacheLock.unlock()
        return value
    }

    /// Records that a question was put to you, or what you did with it.
    func noteQuestion(_ key: String, asked: Date? = nil, answer: String? = nil, skipped: Bool = false, at now: Date = Date()) {
        var entry = askedLog()[key] ?? Asked(key: key, asked: now, answered: nil, answer: nil, times: 0, skips: 0)
        if let asked { entry.asked = asked; entry.times += 1 }
        if let answer { entry.answer = answer; entry.answered = now }
        if skipped { entry.skips += 1 }
        cacheLock.lock(); askedCache?[key] = entry; cacheLock.unlock()
        let e = entry
        write {
            self.run("INSERT INTO questions(key, asked, answered, answer, times, skips) VALUES(?,?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET asked=excluded.asked, answered=excluded.answered, answer=excluded.answer, times=excluded.times, skips=excluded.skips",
                     [e.key, e.asked.timeIntervalSince1970, e.answered?.timeIntervalSince1970, e.answer, e.times, e.skips])
        }
    }

    func forgetQuestion(_ key: String) {
        cacheLock.lock(); askedCache?[key] = nil; cacheLock.unlock()
        write { self.run("DELETE FROM questions WHERE key = ?", [key]) }
    }

    // MARK: Mode corrections

    func save(_ c: Correction) {
        write {
            self.run("INSERT INTO corrections(ts, bundle, app, title, project, mode_from, mode_to) VALUES(?,?,?,?,?,?,?)",
                     [c.ts.timeIntervalSince1970, c.bundle, c.app, String(c.title.prefix(300)), c.project, c.from, c.to])
        }
    }

    func corrections() -> [Correction] {
        queue.sync {
            var out: [Correction] = []
            run("SELECT id, ts, bundle, app, title, project, mode_from, mode_to FROM corrections ORDER BY ts ASC", []) { s in
                out.append(Correction(id: sqlite3_column_int64(s, 0), ts: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), bundle: Self.text(s, 2),
                                      app: Self.text(s, 3), title: Self.text(s, 4), project: Self.text(s, 5), from: Self.text(s, 6), to: Self.text(s, 7)))
            }
            return out
        }
    }

    func deleteCorrections(bundle: String?) {
        write {
            if let bundle { self.run("DELETE FROM corrections WHERE bundle = ?", [bundle]) } else { self.run("DELETE FROM corrections", []) }
        }
    }

    /// Rewrites the mode of moments you corrected, so Rewind and the day show what you said.
    func relabelMoments(_ ids: [Int64], mode: String) {
        guard !ids.isEmpty else { return }
        write { for id in ids { self.run("UPDATE moments SET mode = ? WHERE id = ?", [mode, id]) } }
    }

    // MARK: Task examples

    func save(_ t: TaskExample) {
        write {
            self.run("INSERT INTO task_examples(id, ts, title, project, mode, minutes, estimate) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET ts=excluded.ts, title=excluded.title, project=excluded.project, mode=excluded.mode, minutes=excluded.minutes, estimate=excluded.estimate",
                     [t.id, t.ts.timeIntervalSince1970, String(t.title.prefix(300)), t.project, t.mode, t.minutes, t.estimate])
        }
    }

    func taskExamples() -> [TaskExample] {
        queue.sync {
            var out: [TaskExample] = []
            run("SELECT id, ts, title, project, mode, minutes, estimate FROM task_examples ORDER BY ts ASC", []) { s in
                out.append(TaskExample(id: Self.text(s, 0), ts: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), title: Self.text(s, 2),
                                       project: Self.text(s, 3), mode: Self.text(s, 4), minutes: sqlite3_column_double(s, 5),
                                       estimate: sqlite3_column_type(s, 6) == SQLITE_NULL ? nil : sqlite3_column_double(s, 6)))
            }
            return out
        }
    }

    func deleteTaskExamples() { write { self.run("DELETE FROM task_examples", []) } }

    /// Learners keep live state in memory; they register here so Erase Everything clears them too.
    func onErase(_ body: @escaping @Sendable () -> Void) {
        cacheLock.lock(); eraseHandlers.append(body); cacheLock.unlock()
    }

    // MARK: Retention

    func purge(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        queue.async {
            self.run("DELETE FROM events WHERE ts < ?", [cutoff])
            self.run("DELETE FROM episodes WHERE end < ?", [cutoff])
            self.run("DELETE FROM moments WHERE ts < ?", [cutoff])
        }
    }

    func eraseEverything() {
        queue.sync {
            exec("""
            DELETE FROM events; DELETE FROM episodes; DELETE FROM facts; DELETE FROM feedback; DELETE FROM moments;
            DELETE FROM learners; DELETE FROM questions; DELETE FROM corrections; DELETE FROM task_examples; VACUUM;
            """)
            cacheLock.lock(); factCache = [:]; reactionCache = [:]; shownTimes = []; askedCache = [:]; cacheLock.unlock()
            if self === BrainStore.shared { Memory.shared.forgetEverything() }
        }
        cacheLock.lock()
        let handlers = eraseHandlers
        cacheLock.unlock()
        // Outside the store's queue: a learner's reset may save its (now empty) state.
        for h in handlers { h() }
    }

    func counts() -> (events: Int, episodes: Int, facts: Int) {
        read { conn in
            var e = 0, p = 0, f = 0
            run("SELECT (SELECT COUNT(*) FROM events), (SELECT COUNT(*) FROM episodes), (SELECT COUNT(*) FROM facts)", [], on: conn) { s in
                e = Int(sqlite3_column_int64(s, 0)); p = Int(sqlite3_column_int64(s, 1)); f = Int(sqlite3_column_int64(s, 2))
            }
            return (e, p, f)
        }
    }
}
