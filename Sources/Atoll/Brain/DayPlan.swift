import AppKit
import SwiftUI

/// A day, planned: your meetings (from Calendar and any you add), your top priorities placed into the free time
/// around them, and a break. Built in the morning in the island, then Flow walks you through it.
struct PlanItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case focus, meeting, calendar, rest }
    var id = UUID()
    var title: String
    var kind: Kind
    var start: Date
    var minutes: Int
    var done = false

    var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
    var interval: DateInterval { DateInterval(start: start, duration: TimeInterval(minutes * 60)) }

    /// Lunch keeps one identity, so the day's preview can animate it rather than replace it.
    static let lunchID = UUID(uuidString: "6C756E63-6800-4000-8000-000000000001")!
}

extension UUID {
    /// The same UUID for the same string (a calendar event's identifier), so a row keeps its identity across rebuilds.
    init(stable string: String) {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in string.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return h
        }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: a >> (8 * i)); bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (8 * i)) }
        self = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct DayPlan: Codable, Equatable {
    var day: String
    var items: [PlanItem] = []
    var started = false
    var skipped = false
    /// Reminders already given (item id + moment), so nothing nags twice — even across relaunches.
    var fired: Set<String> = []

    static func key(for date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    var focus: [PlanItem] { items.filter { $0.kind == .focus } }
    var next: PlanItem? { items.filter { $0.end > Date() && !$0.done }.min { $0.start < $1.start } }
}

/// One priority being planned: what, and for how long.
struct Priority: Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var minutes = 60
    /// Drafted by Flow: where it came from ("Unfinished yesterday", "From Design Review"), and the title as drafted —
    /// once you change the title it's yours.
    var source: String? = nil
    var draft: String? = nil

    var isDraft: Bool { source != nil && title == draft }
}

/// "Now", for the planner — debug renders pin it to a morning.
enum PlanClock {
    nonisolated(unsafe) static var pinned: Date?
    static var now: Date { pinned ?? Date() }
}

// MARK: - Scheduling (pure; tested)

enum PlanScheduler {
    /// Places each priority, in order, into the earliest free slot from `from` (rounded up to a quarter hour)
    /// within working hours, leaving a short buffer after anything busy. A lunch break goes in if there's room.
    static func schedule(priorities: [Priority], busy: [DateInterval], from now: Date,
                         dayStart: Int = 9, dayEnd: Int = 19, buffer: TimeInterval = 10 * 60,
                         focusWindow: DateInterval? = nil, calendar: Calendar = .current) -> [PlanItem] {
        let day = calendar.startOfDay(for: now)
        let open = day.addingTimeInterval(TimeInterval(dayStart * 3600))
        let close = day.addingTimeInterval(TimeInterval(dayEnd * 3600))
        var taken = busy.map { DateInterval(start: $0.start, end: $0.end.addingTimeInterval(buffer)) }
        var cursorStart = max(open, roundUp(now, to: 15, calendar: calendar))
        var out: [PlanItem] = []

        func freeSlot(minutes: Int, notBefore: Date, notAfter: Date? = nil) -> Date? {
            var t = notBefore
            let length = TimeInterval(minutes * 60)
            while t.addingTimeInterval(length) <= close {
                if let latest = notAfter, t > latest { return nil }
                let wantEnd = t.addingTimeInterval(length)
                // Strict overlap: back-to-back (ending as a meeting starts) is fine. `DateInterval.intersects` counts touching.
                if let clash = taken.filter({ $0.start < wantEnd && $0.end > t }).min(by: { $0.end < $1.end }) {
                    t = roundUp(clash.end, to: 5, calendar: calendar)
                } else {
                    return t
                }
            }
            return nil
        }

        // Lunch first, so focus blocks don't swallow the middle of the day: 45 min between 12:30 and 14:00.
        let lunchFrom = day.addingTimeInterval(12.5 * 3600), lunchLatest = day.addingTimeInterval(13.25 * 3600)
        if lunchLatest > now, let t = freeSlot(minutes: 45, notBefore: max(lunchFrom, roundUp(now, to: 15, calendar: calendar)), notAfter: lunchLatest) {
            let item = PlanItem(id: PlanItem.lunchID, title: "Lunch", kind: .rest, start: t, minutes: 45)
            out.append(item)
            taken.append(DateInterval(start: item.start, end: item.end.addingTimeInterval(buffer)))
        }

        // What Flow learned: the first priority goes into your sharpest hours if it fits there (and they're still ahead).
        let named = priorities.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        var placedFirst: UUID?
        if let w = focusWindow, let first = named.first, w.end > now {
            let from = max(w.start, roundUp(now, to: 15, calendar: calendar), open)
            if let t = freeSlot(minutes: first.minutes, notBefore: from, notAfter: w.end.addingTimeInterval(-TimeInterval(first.minutes * 30))) {
                let item = PlanItem(id: first.id, title: first.title.trimmingCharacters(in: .whitespaces), kind: .focus, start: t, minutes: first.minutes)
                out.append(item)
                taken.append(DateInterval(start: item.start, end: item.end.addingTimeInterval(buffer)))
                placedFirst = first.id
            }
        }

        for p in named where p.id != placedFirst {
            guard let t = freeSlot(minutes: p.minutes, notBefore: cursorStart) else { continue }
            let item = PlanItem(id: p.id, title: p.title.trimmingCharacters(in: .whitespaces), kind: .focus, start: t, minutes: p.minutes)
            out.append(item)
            taken.append(DateInterval(start: item.start, end: item.end.addingTimeInterval(buffer)))
            cursorStart = item.end.addingTimeInterval(buffer)
        }
        return out.sorted { $0.start < $1.start }
    }

    static func roundUp(_ d: Date, to minutes: Int, calendar: Calendar = .current) -> Date {
        let c = calendar.dateComponents([.hour, .minute, .second], from: d)
        let m = (c.minute ?? 0), s = (c.second ?? 0)
        let over = (m % minutes == 0 && s == 0) ? 0 : minutes - m % minutes
        return calendar.date(byAdding: .minute, value: over, to: d.addingTimeInterval(-TimeInterval(s))) ?? d
    }

    /// "Call with Sam at 4pm for 30m", "Standup 10:30", "Design review 2–3pm" → a meeting today.
    static func parseMeeting(_ text: String, on day: Date = Date(), calendar: Calendar = .current) -> PlanItem? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        let ns = lower as NSString
        var start: Date?
        var end: Date?
        var used: [NSRange] = []

        // Times: "4pm", "4:30 pm", "16:00", "10:30", a range "2-3pm" / "14:00–15:00".
        let timeRe = try! NSRegularExpression(pattern: #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?:\s*(?:-|–|to)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)?\b"#)
        for m in timeRe.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let h1s = group(1), var h1 = Int(h1s) else { continue }
            let mm1 = Int(group(2) ?? "0") ?? 0
            let ampm1 = group(3) ?? group(6)
            // A bare number is only a time with ":mm" or am/pm (so "3 slides" stays a title).
            guard group(2) != nil || ampm1 != nil, h1 <= 23, mm1 < 60 else { continue }
            if ampm1 == "pm", h1 < 12 { h1 += 12 }
            if ampm1 == "am", h1 == 12 { h1 = 0 }
            if ampm1 == nil, h1 >= 1, h1 <= 7 { h1 += 12 }   // "4:00" in a workday means the afternoon
            start = calendar.date(bySettingHour: h1, minute: mm1, second: 0, of: day)
            if let h2s = group(4), var h2 = Int(h2s) {
                let mm2 = Int(group(5) ?? "0") ?? 0
                let ampm2 = group(6) ?? ampm1
                if ampm2 == "pm", h2 < 12 { h2 += 12 }
                if ampm2 == nil, h2 >= 1, h2 <= 7 { h2 += 12 }
                end = calendar.date(bySettingHour: h2, minute: mm2, second: 0, of: day)
            }
            used.append(m.range)
            break
        }
        guard let start else { return nil }

        // Length: "for 30m", "for 1h", "for 45 min", "for an hour".
        var minutes = 30
        if let end, end > start { minutes = Int(end.timeIntervalSince(start) / 60) }
        let lenRe = try! NSRegularExpression(pattern: #"\bfor\s+(an?\s+hour|(\d+(?:\.\d+)?)\s*(h|hr|hrs|hours?|m|min|mins|minutes?))\b"#)
        if let m = lenRe.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)) {
            let whole = ns.substring(with: m.range)
            if whole.contains("hour") && m.range(at: 2).location == NSNotFound {
                minutes = 60
            } else if m.range(at: 2).location != NSNotFound, let n = Double(ns.substring(with: m.range(at: 2))) {
                let unit = ns.substring(with: m.range(at: 3))
                minutes = Int(unit.hasPrefix("h") ? n * 60 : n)
            }
            used.append(m.range)
        }

        // Title: what's left, without "at" / "from".
        var title = raw as NSString
        for r in used.sorted(by: { $0.location > $1.location }) { title = title.replacingCharacters(in: r, with: "") as NSString }
        var t = (title as String).replacingOccurrences(of: #"\b(at|from|on|today)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " ,.-–"))
        if t.isEmpty { t = "Meeting" }
        return PlanItem(title: t.prefix(1).uppercased() + t.dropFirst(), kind: .meeting, start: start, minutes: max(5, min(minutes, 8 * 60)))
    }
}

// MARK: - Store

@MainActor
final class PlanStore: ObservableObject {
    static let shared = PlanStore()

    @Published private(set) var plan: DayPlan
    // The plan being made in the island.
    @Published var priorities: [Priority] = [Priority(), Priority(minutes: 60), Priority(minutes: 30)]
    @Published private(set) var addedMeetings: [PlanItem] = []

    private static let file = "dayplan.json"

    init() {
        let saved = Storage.load(DayPlan.self, from: Self.file)
        plan = saved?.day == DayPlan.key() ? saved! : DayPlan(day: DayPlan.key())
        if let saved, saved.day != DayPlan.key() { carryUnfinished(from: saved) }
        prepareForEditing()
    }

    /// What a past day's plan didn't get to comes forward (once).
    private func carryUnfinished(from old: DayPlan) {
        guard old.started else { return }
        let undone = old.focus.filter { !$0.done }.map(\.title)
        if !undone.isEmpty { carry(undone, from: "Unfinished yesterday", day: old.day) }
    }

    /// Items carried into the next day's plan — from a meeting's action items, or what a day didn't get to — and where
    /// each came from.
    @Published private(set) var carried: [String] = UserDefaults.standard.stringArray(forKey: "planCarry") ?? []
    private var carriedFrom: [String: String] = (UserDefaults.standard.dictionary(forKey: "planCarryFrom") as? [String: String]) ?? [:]

    func carry(_ items: [String], from source: String, day: String = DayPlan.key()) {
        var c = carried
        for i in items.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !i.isEmpty && !c.contains(i) {
            c.append(i)
            carriedFrom[i] = source
        }
        carried = Array(c.prefix(6))
        carriedFrom = carriedFrom.filter { carried.contains($0.key) }
        UserDefaults.standard.set(carried, forKey: "planCarry")
        UserDefaults.standard.set(carriedFrom, forKey: "planCarryFrom")
        UserDefaults.standard.set(day, forKey: "planCarryDay")
    }

    /// Opening the planner on a day that's already planned: what's still to do comes back to edit; what's done stays done.
    /// On a fresh day Flow drafts it (`draft`).
    func prepareForEditing() {
        rollOver()
        draft()
        guard plan.started else { return }
        let now = Date()
        priorities = plan.focus.filter { !$0.done && $0.end > now }.prefix(3).map { Priority(id: $0.id, title: $0.title, minutes: $0.minutes) }
        while priorities.count < 3 { priorities.append(Priority(minutes: 30)) }
        addedMeetings = plan.items.filter { $0.kind == .meeting && $0.end > now }
    }

    /// Flow drafts the morning: what was carried in (yesterday's unfinished priorities, a meeting's action items), then
    /// your main project this week if there's room. Each draft says where it came from; type over it and it's yours.
    func draft() {
        guard !plan.started, !plan.skipped, priorities.allSatisfy({ $0.title.isEmpty }) else { return }
        var drafts: [Priority] = []
        if UserDefaults.standard.string(forKey: "planCarryDay") != DayPlan.key() {
            for item in carried.prefix(3) {
                drafts.append(Priority(title: item, minutes: 45, source: carriedFrom[item] ?? "Carried over", draft: item))
            }
        }
        if drafts.count < 3, let p = InsightModel.shared.insight.projects
            .filter({ $0.week > 3600 && Date().timeIntervalSince($0.lastSeen) < 3 * 86_400 })
            .max(by: { $0.week < $1.week }) {
            let title = "Continue \(p.name)"
            if !drafts.contains(where: { $0.title.localizedCaseInsensitiveContains(p.name) }) {
                drafts.append(Priority(title: title, minutes: 90, source: "Your main project this week — \(BrainEngine.duration(p.week))", draft: title))
            }
        }
        for (i, d) in drafts.prefix(3).enumerated() where i < priorities.count { priorities[i] = d }
    }

    /// Whether anything in the planner is still as Flow drafted it.
    var hasDrafts: Bool { priorities.contains(where: \.isDraft) }

    /// A new day: start fresh (carrying forward what yesterday didn't get to).
    func rollOver() {
        guard plan.day != DayPlan.key() else { return }
        carryUnfinished(from: plan)
        plan = DayPlan(day: DayPlan.key())
        priorities = [Priority(), Priority(minutes: 60), Priority(minutes: 30)]
        addedMeetings = []
    }

    /// Today's calendar meetings (timed, not all-day).
    var calendarItems: [PlanItem] {
        let cal = Calendar.current
        return CalendarModel.shared.events
            .filter { !$0.isAllDay && cal.isDateInToday($0.start) }
            .map { PlanItem(id: UUID(stable: $0.id), title: $0.title, kind: .calendar, start: $0.start,
                            minutes: max(5, Int($0.end.timeIntervalSince($0.start) / 60))) }
    }

    /// The day as it would be with what's typed right now (meetings + placed priorities + lunch).
    var preview: [PlanItem] {
        let fixed = calendarItems + addedMeetings
        let prefs = Prefs.shared
        let placed = PlanScheduler.schedule(priorities: priorities, busy: fixed.map(\.interval), from: PlanClock.now,
                                            dayStart: prefs.planStartHour, dayEnd: max(prefs.planStartHour + 4, prefs.planEndHour),
                                            focusWindow: PatternsModel.shared.bestWindow(on: PlanClock.now))
        return (fixed + placed).sorted { $0.start < $1.start }
    }

    /// Priorities typed but with no room left in the day.
    var unplaced: [Priority] {
        let placed = Set(preview.map(\.id))
        return priorities.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && !placed.contains($0.id) }
    }

    @discardableResult
    func addMeeting(_ text: String) -> PlanItem? {
        guard let m = PlanScheduler.parseMeeting(text) else { return nil }
        withAnimation(Motion.morph) { addedMeetings.append(m) }
        return m
    }

    func removeMeeting(_ id: UUID) { withAnimation(Motion.morph) { addedMeetings.removeAll { $0.id == id } } }

    #if DEBUG
    func debugSet(priorities p: [Priority], meetings: [PlanItem], started: Bool = false) {
        priorities = p
        addedMeetings = meetings
        plan = DayPlan(day: DayPlan.key(), items: [], started: started)
    }
    #endif

    /// "Start my day": the preview becomes the plan, and Flow starts guiding.
    func commit() {
        let fresh = preview
        let ids = Set(fresh.map(\.id))
        // Replanning mid-day keeps what's behind you (done, or already over) exactly as it was.
        let kept = plan.started ? plan.items.filter { ($0.done || $0.end <= Date()) && !ids.contains($0.id) } : []
        var p = DayPlan(day: DayPlan.key())
        p.items = (kept + fresh).sorted { $0.start < $1.start }
        p.started = true
        p.fired = plan.fired
        plan = p
        save()
        // Carried items have had their turn once a morning's plan is made — except ones carried in today, for tomorrow.
        if UserDefaults.standard.string(forKey: "planCarryDay") != DayPlan.key() {
            carried = []
            carriedFrom = [:]
        } else {
            let placed = Set(p.focus.map(\.title))
            carried.removeAll { placed.contains($0) }
        }
        UserDefaults.standard.set(carried, forKey: "planCarry")
        UserDefaults.standard.set(carriedFrom, forKey: "planCarryFrom")
        DayGuide.shared.planChanged()
    }

    func skipToday() {
        plan.skipped = true
        save()
    }

    /// Adds one block to today's plan (Flow can do this: "add a call with Sam at 4").
    func add(_ item: PlanItem) {
        if plan.day != DayPlan.key() { rollOver() }
        plan.items.append(item)
        plan.items.sort { $0.start < $1.start }
        plan.started = true
        save()
        DayGuide.shared.planChanged()
    }

    func markDone(title: String) {
        guard let i = plan.items.firstIndex(where: { $0.kind == .focus && !$0.done && $0.title == title }) else { return }
        plan.items[i].done = true
        save()
    }

    func markFired(_ key: String) {
        plan.fired.insert(key)
        save()
    }

    private func save() { Storage.save(plan, to: Self.file) }

    /// For Flow's context: today's plan in one line each.
    var summary: String {
        guard plan.started, !plan.items.isEmpty else { return "" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "Today's plan: " + plan.items.map { "\(f.string(from: $0.start)) \($0.title) (\($0.minutes) min, \($0.kind.rawValue)\($0.done ? ", done" : ""))" }
            .joined(separator: "; ") + "."
    }
}

// MARK: - Guide

/// Walks you through the plan: a nudge as each block comes up, a mid-day check-in, an evening wrap-up.
/// Everything arrives through Flow's inbox, so nothing is lost if you're busy when it's due.
@MainActor
final class DayGuide {
    static let shared = DayGuide()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { DayGuide.shared.tick() } }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func planChanged() { tick() }

    private func tick() {
        let store = PlanStore.shared
        store.rollOver()
        let plan = store.plan
        guard plan.started, Prefs.shared.brainLevel != BrainLevel.off.rawValue else { return }
        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "h:mm"

        for item in plan.items where !item.done {
            let lead = item.start.timeIntervalSince(now)
            let at = "\(item.id)-\(Int(item.start.timeIntervalSince1970 / 60))"
            switch item.kind {
            case .focus:
                let key = at + "-start"
                // Already on it (its timer is running): nothing to say.
                if FocusTimer.shared.isActive, FocusTimer.shared.label == item.title { continue }
                if lead <= 120, lead > -15 * 60, !plan.fired.contains(key) {
                    store.markFired(key)
                    // With a room saved for it (or its project), the nudge sets the whole room, not just a timer.
                    let room = RoomStore.shared.room(for: item.title)
                    FlowInbox.shared.suggest(BrainSuggestion(kind: "plan.focus", symbol: "scope", title: "Up next: \(item.title)",
                                                             detail: "\(f.string(from: item.start))–\(f.string(from: item.end)) · " + (room.map { $0.summary } ?? "from your plan"),
                                                             actionTitle: room == nil ? "Start Focus" : "Set the Room",
                                                             action: .setRoom(title: item.title, minutes: item.minutes),
                                                             confidence: 0.9), lasts: TimeInterval(item.minutes * 60))
                }
            case .meeting:
                let key = at + "-soon"
                if lead <= 5 * 60, lead > -5 * 60, !plan.fired.contains(key) {
                    store.markFired(key)
                    FlowInbox.shared.suggest(BrainSuggestion(kind: "plan.meeting", symbol: "person.2.fill", title: "\(item.title) at \(f.string(from: item.start))",
                                                             detail: lead > 30 ? "In \(max(1, Int((lead / 60).rounded()))) min · from your plan" : "Starting now",
                                                             actionTitle: "Got It", action: .none, confidence: 0.9), lasts: 15 * 60)
                }
            case .rest:
                let key = at + "-start"
                if lead <= 0, lead > -10 * 60, !plan.fired.contains(key) {
                    store.markFired(key)
                    FlowInbox.shared.suggest(BrainSuggestion(kind: "plan.rest", symbol: "cup.and.saucer.fill", title: "Time for \(item.title.lowercased())",
                                                             detail: "\(item.minutes) min, as planned — step away for a bit",
                                                             actionTitle: "Start Break", action: .startTimer(minutes: item.minutes, label: item.title),
                                                             confidence: 0.85), lasts: 20 * 60)
                }
            case .calendar:
                break   // Calendar meetings already have their own countdown and Join button.
            }
        }

        let cal = Calendar.current
        let hour = cal.component(.hour, from: now), minute = cal.component(.minute, from: now)
        // Your sharpest hours are starting (learned): protect them — unless a meeting's about to take them.
        if let w = PatternsModel.shared.bestWindow(on: now), !plan.fired.contains("bestwindow"),
           (-5 * 60...15 * 60).contains(now.timeIntervalSince(w.start)), FocusTimer.shared.phase == .idle,
           !CalendarModel.shared.events.contains(where: { !$0.isAllDay && $0.start < w.start.addingTimeInterval(3600) && $0.end > now }) {
            store.markFired("bestwindow")
            let next = plan.items.filter { $0.kind == .focus && !$0.done && $0.end > now }.min { $0.start < $1.start }
            let minutes = Int(min(90, max(25, PatternsModel.shared.patterns.focusLength.rounded())))
            let title = next?.title ?? "Focus"
            FlowInbox.shared.suggest(BrainSuggestion(kind: "plan.bestwindow", symbol: "bolt.fill", title: "Your sharpest hours start now",
                                                     detail: "Usually \(Patterns.hours(PatternsModel.shared.patterns.bestStart ?? 9, PatternsModel.shared.patterns.bestEnd ?? 11)) · " + (next.map { "“\($0.title)” next" } ?? "\(minutes) min of focus"),
                                                     actionTitle: "Protect Them", action: .setRoom(title: title, minutes: next?.minutes ?? minutes),
                                                     confidence: 0.85), lasts: 30 * 60)
        }
        // Mid-day check-in.
        if (hour == 13 && minute >= 30) || (hour == 14 && minute < 30), !plan.fired.contains("checkin"), !plan.focus.isEmpty {
            store.markFired("checkin")
            let done = plan.focus.filter(\.done).count
            FlowInbox.shared.ask(BrainQuestion(key: "plan.checkin.\(plan.day)", text: "How’s the plan going?",
                                               detail: "\(done) of \(plan.focus.count) priorities done so far",
                                               options: [.init(label: "On Track", value: "on-track"), .init(label: "Behind", value: "behind"),
                                                         .init(label: "Replan", value: "replan")]))
        }
        // Evening wrap-up.
        if hour >= 18, hour < 22, !plan.fired.contains("wrapup"), !plan.focus.isEmpty {
            store.markFired("wrapup")
            let done = plan.focus.filter(\.done).count
            FlowInbox.shared.suggest(BrainSuggestion(kind: "plan.wrapup", symbol: "sun.horizon.fill", title: "Your day, drawn",
                                                     detail: "\(done) of \(plan.focus.count) priorities done — see how it went",
                                                     actionTitle: "See Your Day", action: .openDay, confidence: 0.7), lasts: 3 * 3600)
        }
    }
}

// MARK: - Morning

/// The first time you open the Mac each morning — unlock, wake or log in — the island opens to plan the day.
/// Once a day; never over a call; "Later" leaves Flow's card on Home until noon.
@MainActor
final class MorningPlanner {
    static let shared = MorningPlanner()
    private var started = false
    private var work: DispatchWorkItem?
    private static let offeredKey = "planOfferedDay"

    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MorningPlanner.shared.consider(after: 1.6) }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MorningPlanner.shared.consider(after: 1.0) }
        }
        // Logging in is opening the Mac too.
        consider(after: 4)
        DayGuide.shared.start()
    }

    /// Whether this morning's planner is still due.
    var isDue: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        guard Prefs.shared.planMorning, hour >= 5, hour < 12 else { return false }
        PlanStore.shared.rollOver()
        let plan = PlanStore.shared.plan
        return !plan.started && !plan.skipped && UserDefaults.standard.string(forKey: Self.offeredKey) != DayPlan.key()
    }

    func consider(after delay: TimeInterval, attempt: Int = 0) {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.offer(attempt: attempt) }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func offer(attempt: Int) {
        #if DEBUG
        if IslandManager.suppressAlerts || RenderMode.snapshot { return }
        #endif
        guard isDue else { return }
        // Busy (a call, StandBy, the island in use): look again in a minute, for a while.
        guard let model = IslandManager.shared.primary?.model, model.mode == .compact || model.mode == .alert,
              ActivityCenter.shared.call == nil, !StandByController.shared.isShowing,
              CGSessionCopyCurrentDictionary().map({ ($0 as NSDictionary)["CGSSessionScreenIsLocked"] as? Bool ?? false }) != true else {
            if attempt < 20 { consider(after: 60, attempt: attempt + 1) }
            return
        }
        UserDefaults.standard.set(DayPlan.key(), forKey: Self.offeredKey)
        IslandManager.shared.openPlan()
    }

    /// "Later" (or Esc): close, and leave Flow's card on Home for when you're ready.
    func later() {
        IslandManager.shared.primary?.model.collapse()
        guard !PlanStore.shared.plan.started, !PlanStore.shared.plan.skipped else { return }
        let noon = Calendar.current.date(bySettingHour: 12, minute: 30, second: 0, of: Date()) ?? Date().addingTimeInterval(3 * 3600)
        FlowInbox.shared.suggest(BrainSuggestion(kind: "plan.later", symbol: "sun.horizon.fill", title: "Plan your day",
                                                 detail: "Your priorities and meetings, in two minutes", actionTitle: "Plan",
                                                 action: .openPlan, confidence: 0.8),
                                 lasts: max(20 * 60, noon.timeIntervalSinceNow), pop: false)
    }

    func skip() {
        PlanStore.shared.skipToday()
        IslandManager.shared.primary?.model.collapse()
    }

    /// "Start my day": the plan is set; close, and say what's first.
    func startDay() {
        let store = PlanStore.shared
        store.commit()
        if let later = FlowInbox.shared.items.first(where: { $0.key == "s:plan.later" }) { FlowInbox.shared.resolve(later.id) }
        guard let model = IslandManager.shared.primary?.model else { return }
        model.collapse()
        Haptics.confirm()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            // Something due right now pops on its own; otherwise a quiet confirmation of what's first.
            if let due = FlowInbox.shared.top, due.key.hasPrefix("s:plan.") {
                IslandManager.shared.showBrain(due.alert)
            } else if let next = store.plan.next {
                let f = Date.FormatStyle(date: .omitted, time: .shortened)
                model.showAlert(.message(symbol: "sun.horizon.fill", text: "Day set · \(next.title) at \(next.start.formatted(f))",
                                         tint: Color(red: 1, green: 0.7, blue: 0.4)), duration: 3.2)
            } else {
                model.showAlert(.message(symbol: "sun.horizon.fill", text: "Day set", tint: Color(red: 1, green: 0.7, blue: 0.4)), duration: 2.4)
            }
        }
    }
}
