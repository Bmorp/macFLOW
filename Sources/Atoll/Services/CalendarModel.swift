import EventKit
import SwiftUI
import AppKit

/// Upcoming events + one-click meeting join + "starting soon" live activity.
@MainActor
final class CalendarModel: ObservableObject {
    static let shared = CalendarModel()

    enum Access { case unknown, granted, denied }

    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: Color
        let location: String?
        let meetingURL: URL?
        /// The event's notes — usually the agenda.
        var notes: String? = nil

        var isNow: Bool { start <= Date() && end > Date() }
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [Event] = []

    var onMeetingSoon: ((Event, Int) -> Void)?

    private let store = EKEventStore()
    private var alerted: Set<String> = []
    private var timer: Timer?
    private var ticks = 0

    init() {
        updateAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        reload()
    }

    var nextEvent: Event? {
        events.first(where: { !$0.isAllDay }) ?? events.first
    }

    private func updateAccess() {
        let now: Access
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: now = .granted
        case .notDetermined: now = .unknown
        default: now = .denied
        }
        if now != access { access = now }
    }

    func requestAccess() {
        if access == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSApp.activate()
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateAccess()
                self?.reload()
            }
        }
    }

    func reload() {
        updateAccess()
        guard access == .granted else {
            if !events.isEmpty { events = [] }
            return
        }
        let now = Date()
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: 2, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let fresh = store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)
            .map { ek -> Event in
                Event(id: "\(ek.eventIdentifier ?? UUID().uuidString)-\(ek.startDate.timeIntervalSince1970)",
                      title: ek.title?.isEmpty == false ? ek.title! : "Untitled",
                      start: ek.startDate,
                      end: ek.endDate,
                      isAllDay: ek.isAllDay,
                      color: Color(nsColor: ek.calendar?.color ?? .systemBlue),
                      location: ek.location,
                      meetingURL: Self.meetingURL(in: ek),
                      notes: Self.agenda(ek.notes))
            }
        if fresh != events { events = Array(fresh) }
    }

    /// Every 30 s: drop events that have ended and raise "starting soon". The store itself is re-read only every
    /// five minutes — edits arrive through `EKEventStoreChanged` — so the calendar isn't fetched on the main
    /// thread (and every view showing it re-rendered) twice a minute.
    private func tick() {
        ticks += 1
        let now = Date()
        if ticks % 10 == 0 {
            reload()
        } else {
            updateAccess()
            guard access == .granted else { return }
            if events.contains(where: { $0.end <= now }) { events.removeAll { $0.end <= now } }
        }
        for e in events where !e.isAllDay {
            let secs = e.start.timeIntervalSince(now)
            if secs > 0, secs <= 300, !alerted.contains(e.id) {
                alerted.insert(e.id)
                onMeetingSoon?(e, max(1, Int((secs / 60).rounded(.up))))
            }
        }
    }

    func open(_ e: Event) {
        if let url = e.meetingURL {
            NSWorkspace.shared.open(url)
        } else if let cal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: cal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static let meetingRegex = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"']*(zoom\.us/(j|my|w)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|webex\.com/|facetime\.apple\.com/join|whereby\.com/|meet\.jit\.si/|chime\.aws/)[^\s<>"']*"#,
        options: [.caseInsensitive])

    private static func meetingURL(in ek: EKEvent) -> URL? {
        let candidates = [ek.url?.absoluteString, ek.location, ek.notes].compactMap { $0 }
        for text in candidates {
            let range = NSRange(text.startIndex..., in: text)
            if let m = meetingRegex?.firstMatch(in: text, range: range),
               let r = Range(m.range, in: text),
               let url = URL(string: String(text[r])) {
                return url
            }
        }
        return nil
    }

    /// The notes without meeting boilerplate (join links, dial-ins), trimmed.
    nonisolated static func agenda(_ notes: String?) -> String? {
        guard let notes else { return nil }
        let lines = notes.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            !line.isEmpty && !line.contains("://") && !line.lowercased().contains("dial") && !line.lowercased().contains("meeting id")
                && !line.lowercased().contains("passcode") && !line.hasPrefix("─") && !line.hasPrefix("--")
        }
        let text = lines.prefix(8).joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(600))
    }

    /// A new event in your default calendar (Flow Lens: "Lunch with Sam Friday 1pm").
    func addEvent(title: String, start: Date, minutes: Int) -> Bool {
        guard access == .granted, let calendar = store.defaultCalendarForNewEvents else { return false }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))
        e.calendar = calendar
        do {
            try store.save(e, span: .thisEvent, commit: true)
        } catch {
            return false
        }
        reload()
        return true
    }

    // MARK: Moving an event (Flow: "move my 3 o'clock to tomorrow")

    /// Finds the event meant by `which` ("3 o'clock", "4:30", "standup") today or tomorrow, and moves it to `to`
    /// ("tomorrow", "4pm", "tomorrow at 10"), keeping its length. Events with other people are left for you to move
    /// in Calendar, so they're notified properly. Returns what happened, in words.
    func move(_ which: String, to: String) -> String {
        guard access == .granted else { return "I need Calendar access for that — allow it in Settings › Activities." }
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: 2, to: start) else { return "I couldn't read your calendar." }
        let candidates = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
        guard let ek = Self.pick(candidates, which: which, now: now) else { return "I couldn't find “\(which)” on your calendar today or tomorrow." }
        if let attendees = ek.attendees, !attendees.isEmpty, ek.organizer?.isCurrentUser != true {
            return "“\(ek.title ?? "That meeting")” has other people in it — move it in Calendar so they're told."
        }
        guard let newStart = Self.target(to, from: ek.startDate, now: now) else { return "I didn't understand when to move it to." }
        let length = ek.endDate.timeIntervalSince(ek.startDate)
        let oldStart: Date = ek.startDate
        ek.startDate = newStart
        ek.endDate = newStart.addingTimeInterval(length)
        do {
            try store.save(ek, span: .thisEvent, commit: true)
        } catch {
            return "Calendar wouldn't let me move it (\(error.localizedDescription))."
        }
        reload()
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Moved “\(ek.title ?? "the event")” from \(f.string(from: oldStart)) to \(f.string(from: newStart))."
    }

    /// The event a phrase means: by time ("3", "3 o'clock", "4:30pm") or by words in its title.
    nonisolated static func pick(_ events: [EKEvent], which: String, now: Date) -> EKEvent? {
        let lower = which.lowercased()
        let cal = Calendar.current
        if let m = try? NSRegularExpression(pattern: #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#).firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let hr = Range(m.range(at: 1), in: lower), var hour = Int(lower[hr]) {
            let minute = Range(m.range(at: 2), in: lower).flatMap { Int(lower[$0]) }
            let ampm = Range(m.range(at: 3), in: lower).map { String(lower[$0]) }
            if ampm == "pm", hour < 12 { hour += 12 }
            if ampm == "am", hour == 12 { hour = 0 }
            if ampm == nil, hour >= 1, hour <= 7 { hour += 12 }
            let matches = events.filter {
                cal.component(.hour, from: $0.startDate) == hour && (minute == nil || cal.component(.minute, from: $0.startDate) == minute)
            }
            if let first = matches.min(by: { $0.startDate < $1.startDate }) { return first }
        }
        let words = lower.split(separator: " ").map(String.init).filter { $0.count > 2 && !["my", "the", "meeting", "call", "event"].contains($0) }
        return events.filter { e in
            let title = (e.title ?? "").lowercased()
            return !words.isEmpty && words.allSatisfy { title.contains($0) }
        }.min { $0.startDate < $1.startDate }
    }

    /// When "tomorrow" / "4pm" / "tomorrow at 10" / "Friday" lands, keeping the original time if none is given and
    /// the original day if only a time is. "Tomorrow" means the day after `now`.
    nonisolated static func target(_ text: String, from original: Date, now: Date) -> Date? {
        let cal = Calendar.current
        let lower = text.lowercased()
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let found = detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date
        let hasTime = lower.range(of: #"\d"#, options: .regularExpression) != nil || lower.contains("noon")
        let time: (h: Int, m: Int) = {
            if hasTime, let found { let c = cal.dateComponents([.hour, .minute], from: found); return (c.hour ?? 9, c.minute ?? 0) }
            let c = cal.dateComponents([.hour, .minute], from: original)
            return (c.hour ?? 9, c.minute ?? 0)
        }()
        let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let day: Date?
        if lower.contains("tomorrow") {
            day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
        } else if lower.contains("today") || lower.contains("tonight") {
            day = cal.startOfDay(for: now)
        } else if weekdays.contains(where: lower.contains) || lower.contains("next"), let found {
            day = cal.startOfDay(for: found)
        } else if hasTime {
            day = cal.startOfDay(for: original)   // just a time: same day as it was
        } else {
            day = found.map { cal.startOfDay(for: $0) }
        }
        guard let day else { return nil }
        return cal.date(bySettingHour: time.h, minute: time.m, second: 0, of: day)
    }

    static func relative(_ e: Event) -> String {
        let now = Date()
        if e.isAllDay { return "All day" }
        if e.isNow {
            let left = Int(e.end.timeIntervalSince(now) / 60)
            return left <= 1 ? "Ending now" : "Now · \(left) min left"
        }
        let mins = Int((e.start.timeIntervalSince(now) / 60).rounded(.up))
        if mins < 60 { return "in \(mins) min" }
        if Calendar.current.isDateInToday(e.start) {
            let h = mins / 60, m = mins % 60
            return m == 0 ? "in \(h)h" : "in \(h)h \(m)m"
        }
        return "Tomorrow"
    }

    static func timeRange(_ e: Event) -> String {
        if e.isAllDay { return "All day" }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return "\(f.string(from: e.start)) – \(f.string(from: e.end))"
    }

    #if DEBUG
    func debugSet(_ list: [Event]) {
        access = .granted
        events = list
    }
    #endif
}
