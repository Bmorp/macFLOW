import Foundation

/// What a line of typed words means as a task: "review deck tomorrow 3pm 45m #launch !high" →
/// "Review deck", tomorrow at 3 PM, 45 minutes, project launch, high priority.
struct TaskDraft: Equatable, Sendable {
    var title: String
    var project: String?
    var due: Date?
    var scheduled: Date?
    /// Minutes.
    var estimate: Double?
    var priority: TaskPriority = .none
    var repeats: RepeatRule?
    var someday = false

    var isEmpty: Bool { title.isEmpty }
    /// Whether the words said anything beyond the title.
    var hasDetails: Bool {
        project != nil || due != nil || scheduled != nil || estimate != nil || priority != .none || repeats != nil || someday
    }
}

/// Rules, not a model: instant on every keystroke, the same on every Mac, and testable. The on-device model
/// (`TaskLanguage`) only fills gaps the rules leave, after the task exists.
enum TaskParser {
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> TaskDraft {
        var p = Pass(text: text.trimmingCharacters(in: .whitespacesAndNewlines), now: now, calendar: calendar)
        p.run()
        return p.draft
    }

    // MARK: - Vocabulary

    static let weekdayNames: [(pattern: String, weekday: Int)] = [
        ("sun(?:day)?", 1), ("mon(?:day)?", 2), ("tue(?:s|sday)?", 3), ("wed(?:s|nesday)?", 4),
        ("thu(?:r|rs|rsday)?", 5), ("fri(?:day)?", 6), ("sat(?:urday)?", 7),
    ]
    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func weekday(_ word: String) -> Int? {
        let w = word.lowercased()
        for (pattern, n) in weekdayNames where w.range(of: "^\(pattern)$", options: .regularExpression) != nil { return n }
        return nil
    }

    static func month(_ word: String) -> Int? {
        let w = word.lowercased()
        guard w.count >= 3 else { return nil }
        if w.hasPrefix("sept") { return 9 }
        return monthNames.firstIndex { w.hasPrefix($0) }.map { $0 + 1 }
    }
}

// MARK: - One pass over the words

private struct Pass {
    enum Role { case when, due }
    struct Day { var date: Date; var role: Role; var range: NSRange }
    struct Clock { var hour: Int; var minute: Int; var role: Role?; var range: NSRange }

    let text: String
    let ns: NSString
    let now: Date
    let cal: Calendar
    var used: [NSRange] = []
    var days: [Day] = []
    var clocks: [Clock] = []
    /// A moment fixed outright ("in 2 hours").
    var exact: (date: Date, role: Role)?
    var draft: TaskDraft
    var weeklyNeedsDay = false

    init(text: String, now: Date, calendar: Calendar) {
        self.text = text
        ns = text as NSString
        self.now = now
        cal = calendar
        draft = TaskDraft(title: text)
    }

    var today: Date { cal.startOfDay(for: now) }

    func day(_ offset: Int, from base: Date? = nil) -> Date {
        cal.date(byAdding: .day, value: offset, to: base ?? today) ?? today
    }

    // Weekday names that are also ordinary words need a lead-in ("on sat", "next sun").
    static let weekdayAlternation = TaskParser.weekdayNames.map(\.pattern).joined(separator: "|")
    static let rolePrefix = #"(?:(by|due(?:\s+(?:on|by))?|before|until)\s+)?"#

    // MARK: Matching

    private func overlaps(_ r: NSRange) -> Bool { used.contains { NSIntersectionRange($0, r).length > 0 } }

    /// Matches not already claimed by an earlier rule.
    private func matches(_ pattern: String) -> [NSTextCheckingResult] {
        guard let re = Pass.regex(pattern) else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { !overlaps($0.range) }
    }

    private func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }

    private static let cache = NSCache<NSString, NSRegularExpression>()
    static func regex(_ pattern: String) -> NSRegularExpression? {
        if let hit = cache.object(forKey: pattern as NSString) { return hit }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        cache.setObject(re, forKey: pattern as NSString)
        return re
    }

    private static func role(_ word: String?) -> Role { word == nil ? .when : .due }

    // MARK: Rules, most specific first

    mutating func run() {
        guard !text.isEmpty else { draft.title = ""; return }
        repeats()
        relative()
        dates()
        times()
        durations()
        priority()
        tags()
        someday()
        resolve()
        draft.title = Pass.clean(title())
    }

    /// "every Monday", "every weekday", "daily", "every month on the 1st".
    private mutating func repeats() {
        for m in matches(#"\bevery\s+(day|weekday|week|month|year)\b"#) {
            switch group(m, 1)?.lowercased() {
            case "day": draft.repeats = .daily
            case "weekday": draft.repeats = .weekdays
            case "week": draft.repeats = .weekly([]); weeklyNeedsDay = true
            case "month": draft.repeats = .monthly(cal.component(.day, from: now))
            default: draft.repeats = .yearly
            }
            used.append(m.range)
            return
        }
        let wd = Pass.weekdayAlternation
        for m in matches(#"\bevery\s+((?:\#(wd))s?(?:\s*(?:,|and|&)\s*(?:\#(wd))s?)*)\b"#) {
            let words = (group(m, 1) ?? "").components(separatedBy: CharacterSet(charactersIn: ", &")).filter { !$0.isEmpty && $0.lowercased() != "and" }
            let set = Set(words.compactMap { TaskParser.weekday($0.hasSuffix("s") && $0.count > 3 && TaskParser.weekday($0) == nil ? String($0.dropLast()) : $0) })
            guard !set.isEmpty else { continue }
            draft.repeats = .weekly(set)
            used.append(m.range)
            return
        }
        for m in matches(#"\bevery\s+(\d{1,2})(?:st|nd|rd|th)(?:\s+of\s+the\s+month)?\b"#) {
            if let n = Int(group(m, 1) ?? ""), (1...31).contains(n) {
                draft.repeats = .monthly(n)
                used.append(m.range)
                return
            }
        }
        // A bare adverb repeats only when it isn't the task's first word ("Weekly review" is a title).
        for m in matches(#"\b(daily|weekly|monthly|yearly|annually)\b"#) where m.range.location > 0 {
            switch group(m, 1)?.lowercased() {
            case "daily": draft.repeats = .daily
            case "weekly": draft.repeats = .weekly([]); weeklyNeedsDay = true
            case "monthly": draft.repeats = .monthly(cal.component(.day, from: now))
            default: draft.repeats = .yearly
            }
            used.append(m.range)
            return
        }
    }

    /// "in 2 hours", "in 30 min", "in 3 days", "in two weeks".
    private mutating func relative() {
        let n = #"(an?|one|two|three|four|five|six|seven|eight|nine|ten|a\s+couple\s+of|a\s+few|\d+(?:\.\d+)?)"#
        for m in matches(#"\b(?:(due)\s+)?in\s+\#(n)\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|wks?|w|months?)\b"#) {
            guard let amount = Pass.number(group(m, 2) ?? ""), amount > 0 else { continue }
            let unit = (group(m, 3) ?? "").lowercased()
            let role = Pass.role(group(m, 1))
            if unit.hasPrefix("mi") || unit == "m" {
                exact = (now.addingTimeInterval(amount * 60).roundedToMinute(cal), role)
            } else if unit.hasPrefix("h") {
                exact = (now.addingTimeInterval(amount * 3600).roundedToMinute(cal), role)
            } else if unit.hasPrefix("d") {
                days.append(Day(date: day(Int(amount.rounded())), role: role, range: m.range))
            } else if unit.hasPrefix("w") {
                days.append(Day(date: day(Int((amount * 7).rounded())), role: role, range: m.range))
            } else {
                days.append(Day(date: cal.date(byAdding: .month, value: Int(amount.rounded()), to: today) ?? today, role: role, range: m.range))
            }
            used.append(m.range)
            return
        }
    }

    static func number(_ s: String) -> Double? {
        let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        let w = s.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if let v = words[w] { return Double(v) }
        if w == "a couple of" { return 2 }
        if w == "a few" { return 3 }
        return Double(w)
    }

    /// Days: today, tomorrow, weekdays (this / next), next week, the weekend, "Nov 3", "the 3rd", end of month.
    private mutating func dates() {
        let rp = Pass.rolePrefix
        let part = #"(?:\s+(morning|afternoon|evening|night))?"#

        for m in matches(#"\b\#(rp)(?:on\s+)?(the\s+)?day\s+after\s+tomorrow\#(part)\b"#) {
            add(day(2), m, roleGroup: 1, partGroup: 3)
        }
        for m in matches(#"\b\#(rp)(today|tonight|eod|tomorrow|tmrw|tmr)\#(part)\b"#) {
            let word = (group(m, 2) ?? "").lowercased()
            add(["today", "tonight", "eod"].contains(word) ? today : day(1), m, roleGroup: 1, partGroup: 3)
            if word == "tonight" { clocks.append(Clock(hour: 19, minute: 0, role: Pass.role(group(m, 1)), range: m.range)) }
        }
        // Weekdays. Full names stand alone; "sat" and "sun" are words, so they need "on", "this", "next", "by".
        let full = "sunday|monday|tuesday|wednesday|thursday|friday|saturday|mon|tue|tues|wed|weds|thu|thur|thurs|fri"
        for m in matches(#"\b\#(rp)(?:(on|this|next|coming)\s+)?(\#(full))\#(part)\b"#) {
            if let wd = TaskParser.weekday(group(m, 3) ?? "") { add(weekday(wd, modifier: group(m, 2)), m, roleGroup: 1, partGroup: 4) }
        }
        for m in matches(#"\b\#(rp)(on|this|next|coming)\s+(sat|sun)\#(part)\b"#) {
            if let wd = TaskParser.weekday(group(m, 3) ?? "") { add(weekday(wd, modifier: group(m, 2)), m, roleGroup: 1, partGroup: 4) }
        }
        for m in matches(#"\b(by)\s+(sat|sun)\b"#) {
            if let wd = TaskParser.weekday(group(m, 2) ?? "") { add(weekday(wd, modifier: nil), m, roleGroup: 1, partGroup: nil) }
        }
        for m in matches(#"\b\#(rp)(?:(?:on|at|over)\s+the\s+|(this|next)\s+)weekend\b"#) {
            let saturday = weekday(7, modifier: "this")
            add(group(m, 2)?.lowercased() == "next" ? (cal.date(byAdding: .day, value: 7, to: saturday) ?? saturday) : saturday, m, roleGroup: 1, partGroup: nil)
        }
        for m in matches(#"\b\#(rp)next\s+(week|month|year)\b"#) {
            switch (group(m, 2) ?? "").lowercased() {
            case "week": add(cal.date(byAdding: .day, value: 7, to: startOfWeek(today)) ?? day(7), m, roleGroup: 1, partGroup: nil)
            case "month":
                let first = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
                add(cal.date(byAdding: .month, value: 1, to: first) ?? first, m, roleGroup: 1, partGroup: nil)
            default:
                let first = cal.date(from: cal.dateComponents([.year], from: today)) ?? today
                add(cal.date(byAdding: .year, value: 1, to: first) ?? first, m, roleGroup: 1, partGroup: nil)
            }
        }
        for m in matches(#"\b\#(rp)(?:(?:the\s+)?end\s+of\s+(?:the\s+)?(week|month)|(eow|eom))\b"#) {
            let which = (group(m, 2) ?? group(m, 3) ?? "").lowercased()
            if which == "week" || which == "eow" {
                add(weekday(6, modifier: "this"), m, roleGroup: 1, partGroup: nil)
            } else {
                let next = cal.date(byAdding: .month, value: 1, to: cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today) ?? today
                add(day(-1, from: next), m, roleGroup: 1, partGroup: nil)
            }
        }
        // "Nov 3", "November 3rd, 2027", "3 Nov", "3rd of November".
        let mon = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?"#
        for m in matches(#"\b\#(rp)(?:on\s+)?\#(mon)\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#) {
            if let d = calendarDay(month: group(m, 2), day: group(m, 3), year: group(m, 4)) { add(d, m, roleGroup: 1, partGroup: nil) }
        }
        for m in matches(#"\b\#(rp)(?:on\s+)?(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?\#(mon)(?:,?\s+(\d{4}))?\b"#) {
            if let d = calendarDay(month: group(m, 3), day: group(m, 2), year: group(m, 4)) { add(d, m, roleGroup: 1, partGroup: nil) }
        }
        for m in matches(#"\b(\d{4})-(\d{2})-(\d{2})\b"#) {
            var c = DateComponents()
            c.year = Int(group(m, 1) ?? ""); c.month = Int(group(m, 2) ?? ""); c.day = Int(group(m, 3) ?? "")
            if let d = cal.date(from: c) { add(d, m, roleGroup: nil, partGroup: nil) }
        }
        // "on the 3rd": this month, or next if it's gone.
        for m in matches(#"\b\#(rp)on\s+the\s+(\d{1,2})(?:st|nd|rd|th)\b"#) {
            guard let n = Int(group(m, 2) ?? ""), (1...31).contains(n) else { continue }
            var c = cal.dateComponents([.year, .month], from: today)
            c.day = n
            if var d = cal.date(from: c) {
                if d < today, let next = cal.date(byAdding: .month, value: 1, to: d) { d = next }
                add(d, m, roleGroup: 1, partGroup: nil)
            }
        }
    }

    private mutating func add(_ date: Date, _ m: NSTextCheckingResult, roleGroup: Int?, partGroup: Int?) {
        let role = roleGroup.map { Pass.role(group(m, $0)) } ?? .when
        days.append(Day(date: cal.startOfDay(for: date), role: role, range: m.range))
        if let partGroup, let part = group(m, partGroup)?.lowercased() {
            let hour = part == "morning" ? 9 : part == "afternoon" ? 14 : part == "evening" ? 18 : 20
            clocks.append(Clock(hour: hour, minute: 0, role: role, range: m.range))
        }
        used.append(m.range)
    }

    /// Weeks start on Monday here, whatever the region's calendar says, so "next Friday" means the same everywhere.
    private func startOfWeek(_ d: Date) -> Date {
        let wd = cal.component(.weekday, from: d)       // 1 = Sunday
        return day(-((wd + 5) % 7), from: d)
    }

    /// "friday": the next one after today. "this friday": this week's (today counts). "next friday": next week's.
    private func weekday(_ target: Int, modifier: String?) -> Date {
        let current = cal.component(.weekday, from: today)
        let ahead = (target - current + 7) % 7
        switch modifier?.lowercased() {
        case "this":
            return day(ahead)
        case "next":
            let nextWeek = day(7, from: startOfWeek(today))
            return day((target + 5) % 7, from: nextWeek)
        default:
            return day(ahead == 0 ? 7 : ahead)
        }
    }

    private func calendarDay(month: String?, day: String?, year: String?) -> Date? {
        guard let month = month.flatMap(TaskParser.month), let d = day.flatMap({ Int($0) }), (1...31).contains(d) else { return nil }
        var c = DateComponents()
        c.year = year.flatMap { Int($0) } ?? cal.component(.year, from: today)
        c.month = month
        c.day = d
        guard var date = cal.date(from: c), cal.component(.day, from: date) == d else { return nil }
        if year == nil, date < today, let next = cal.date(byAdding: .year, value: 1, to: date) { date = next }
        return date
    }

    /// Times: "3pm", "3:30 pm", "15:00", "at 4", "noon", "by 5pm".
    private mutating func times() {
        let rp = #"(?:(by|due|before|until)\s+)?(?:(?:at|@)\s*)?"#
        for m in matches(#"(?:^|(?<=\s))\#(rp)(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)(?=$|[\s,.;!?])"#) {
            guard var h = Int(group(m, 2) ?? ""), h >= 1, h <= 12 else { continue }
            let mm = Int(group(m, 3) ?? "0") ?? 0
            guard mm < 60 else { continue }
            let pm = (group(m, 4) ?? "").lowercased().hasPrefix("p")
            if pm, h < 12 { h += 12 }
            if !pm, h == 12 { h = 0 }
            clocks.append(Clock(hour: h, minute: mm, role: group(m, 1) == nil ? nil : .due, range: m.range))
            used.append(m.range)
        }
        for m in matches(#"(?:^|(?<=\s))\#(rp)(\d{1,2}):(\d{2})(?=$|[\s,.;!?])"#) {
            guard var h = Int(group(m, 2) ?? ""), let mm = Int(group(m, 3) ?? ""), h <= 23, mm < 60 else { continue }
            if h >= 1, h <= 7 { h += 12 }   // "4:00" in a working day is the afternoon
            clocks.append(Clock(hour: h, minute: mm, role: group(m, 1) == nil ? nil : .due, range: m.range))
            used.append(m.range)
        }
        // A bare hour only counts after "at" ("at 4"), so "chapter 4" stays a title.
        for m in matches(#"(?:^|(?<=\s))(?:(by|due|before|until)\s+)?(?:at|@)\s*(\d{1,2})(?=$|[\s,.;!?])"#) {
            guard var h = Int(group(m, 2) ?? ""), h <= 23 else { continue }
            if h >= 1, h <= 7 { h += 12 }
            clocks.append(Clock(hour: h, minute: 0, role: group(m, 1) == nil ? nil : .due, range: m.range))
            used.append(m.range)
        }
        for m in matches(#"\b\#(rp)(noon|midday)\b"#) {
            clocks.append(Clock(hour: 12, minute: 0, role: group(m, 1) == nil ? nil : .due, range: m.range))
            used.append(m.range)
        }
        for m in matches(#"\bthis\s+(morning|afternoon|evening)\b"#) {
            let part = (group(m, 1) ?? "").lowercased()
            days.append(Day(date: today, role: .when, range: m.range))
            clocks.append(Clock(hour: part == "morning" ? 9 : part == "afternoon" ? 14 : 18, minute: 0, role: .when, range: m.range))
            used.append(m.range)
        }
    }

    /// How long: "45m", "1h30", "1.5h", "90 min", "for an hour", "half an hour".
    private mutating func durations() {
        for m in matches(#"\b(?:for\s+)?(an?\s+hour\s+and\s+a\s+half|half\s+an\s+hour|(?:an?|one)\s+hour)\b"#) {
            let phrase = (group(m, 1) ?? "").lowercased()
            // "an hour" alone is ambiguous; "for an hour" or "half an hour" isn't.
            guard phrase.hasPrefix("half") || phrase.contains("and a half") || ns.substring(with: m.range).lowercased().hasPrefix("for") else { continue }
            draft.estimate = phrase.hasPrefix("half") ? 30 : phrase.contains("and a half") ? 90 : 60
            used.append(m.range)
            return
        }
        // "1h30" needs no unit on the minutes; "1h 30m" does, so "1h 30 slides" keeps its slides.
        for m in matches(#"(?:\bfor\s+|~|\b)(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hours?)(?:(\d{1,2})(?:m|min|mins|minutes?)?|\s+(\d{1,2})\s*(?:m|min|mins|minutes?))?(?=$|[\s,.;!?])"#) {
            guard let h = Double(group(m, 1) ?? "") else { continue }
            let minutes = h * 60 + (Double(group(m, 2) ?? group(m, 3) ?? "0") ?? 0)
            guard minutes > 0, minutes <= 24 * 60 else { continue }
            draft.estimate = minutes.rounded()
            used.append(m.range)
            return
        }
        for m in matches(#"(?:\bfor\s+|~|\b)(\d{1,4})\s*(?:m|min|mins|minutes?)(?=$|[\s,.;!?])"#) {
            guard let n = Double(group(m, 1) ?? ""), n > 0, n <= 24 * 60 else { continue }
            draft.estimate = n
            used.append(m.range)
            return
        }
    }

    /// "!", "!!", "!!!" (as in Reminders: low, medium, high), "!high", "p1".
    private mutating func priority() {
        for m in matches(#"(?:^|(?<=\s))(!{1,3})(?=$|\s)"#) {
            draft.priority = TaskPriority(rawValue: min(3, (group(m, 1) ?? "").count)) ?? .none
            used.append(m.range)
            return
        }
        for m in matches(#"(?:^|(?<=\s))!(high|hi|h|medium|med|m|low|lo|l|[123])(?=$|[\s,.;])"#) {
            switch (group(m, 1) ?? "").lowercased() {
            case "high", "hi", "h", "1": draft.priority = .high
            case "medium", "med", "m", "2": draft.priority = .medium
            default: draft.priority = .low
            }
            used.append(m.range)
            return
        }
        for m in matches(#"(?:^|(?<=\s))p([123])(?=$|[\s,.;])"#) {
            draft.priority = group(m, 1) == "1" ? .high : group(m, 1) == "2" ? .medium : .low
            used.append(m.range)
            return
        }
    }

    /// "#launch": the project. A tag starts with a letter, so "#123" stays an issue number in the title.
    private mutating func tags() {
        for m in matches(#"(?:^|(?<=\s))#(\p{L}[\p{L}\p{N}_\-/]*)"#) {
            if draft.project == nil { draft.project = group(m, 1) }
            used.append(m.range)
        }
    }

    private mutating func someday() {
        for m in matches(#"\bsome\s?day\b"#) {
            draft.someday = true
            used.append(m.range)
            return
        }
    }

    // MARK: Putting it together

    private mutating func resolve() {
        // A time with no "by" of its own goes with the day written right beside it.
        func roleNearby(_ clock: Clock) -> Role {
            if let r = clock.role { return r }
            let near = days.min { distance($0.range, clock.range) < distance($1.range, clock.range) }
            if let near, distance(near.range, clock.range) <= 3 { return near.role }
            return .when
        }
        var whenDay = days.first { $0.role == .when }?.date
        let dueDay = days.first { $0.role == .due }?.date
        let whenClock = clocks.first { roleNearby($0) == .when }
        let dueClock = clocks.first { roleNearby($0) == .due }

        func at(_ day: Date, _ clock: Clock) -> Date {
            cal.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: day) ?? day
        }
        /// A time alone means today — or tomorrow, once today's has passed.
        func soonest(_ clock: Clock) -> Date {
            let t = at(today, clock)
            return t > now ? t : at(day(1), clock)
        }

        if let exact {
            if exact.role == .when { draft.scheduled = exact.date } else { draft.due = exact.date }
        }
        if let rule = draft.repeats {
            if case .weekly(let set) = rule, set.isEmpty || weeklyNeedsDay {
                draft.repeats = .weekly([cal.component(.weekday, from: whenDay ?? today)])
            }
            if whenDay == nil, draft.scheduled == nil { whenDay = draft.repeats?.next(onOrAfter: today, calendar: cal) }
        }
        if draft.scheduled == nil {
            if let d = whenDay { draft.scheduled = whenClock.map { at(d, $0) } ?? d } else if let c = whenClock { draft.scheduled = soonest(c) }
        }
        if draft.due == nil {
            if let d = dueDay { draft.due = dueClock.map { at(d, $0) } ?? d } else if let c = dueClock { draft.due = soonest(c) }
        }
        if draft.scheduled != nil || draft.due != nil { draft.someday = false }
    }

    private func distance(_ a: NSRange, _ b: NSRange) -> Int {
        if NSIntersectionRange(a, b).length > 0 || a == b { return 0 }
        return a.location < b.location ? b.location - NSMaxRange(a) : a.location - NSMaxRange(b)
    }

    /// Where words were taken out, a marker stays for a moment, so `clean` knows which "at" or "by" lost its
    /// object ("call Sam at 4pm") and which is part of the title ("check in").
    static let gap = "\u{1}"

    private func title() -> String {
        var out = text as NSString
        for r in used.sorted(by: { $0.location > $1.location }) where NSMaxRange(r) <= out.length {
            out = out.replacingCharacters(in: r, with: " \(Pass.gap) ") as NSString
        }
        return out as String
    }

    /// What's left, tidied: no stranded "at" or "by" before a removed date, no doubled spaces, a capital first letter.
    static func clean(_ raw: String) -> String {
        var t = raw
        let stranded = #"(?i)(?:^|\s)(?:at|on|by|for|in|due|from|this|next|every|and|@)\s*\#u{1}"#
        while let r = t.range(of: stranded, options: .regularExpression) {
            t.replaceSubrange(r, with: " \(gap)")
        }
        t = t.replacingOccurrences(of: gap, with: " ")
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,;-–—"))
        guard let first = t.first else { return "" }
        return first.uppercased() + t.dropFirst()
    }
}

private extension Date {
    func roundedToMinute(_ cal: Calendar) -> Date {
        let s = cal.component(.second, from: self)
        return addingTimeInterval(TimeInterval(-s))
    }
}

// MARK: - Words for dates and lengths

/// How tasks say when and how long, everywhere they appear (rows, the search preview, Flow's plan).
enum TaskFormat {
    static func length(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m < 60 ? "\(m)m" : (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m")
    }

    /// "Today", "Tomorrow", "Friday", "Mon 9 Nov", "3 Jan 2028".
    static func day(_ date: Date, now: Date = Date(), calendar cal: Calendar = .current) -> String {
        let today = cal.startOfDay(for: now)
        let d = cal.startOfDay(for: date)
        let diff = cal.dateComponents([.day], from: today, to: d).day ?? 0
        switch diff {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return date.formatted(.dateTime.weekday(.wide))
        default:
            if cal.component(.year, from: d) == cal.component(.year, from: today) {
                return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            }
            return date.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// A day, with its time when it has one: "Tomorrow 3:00 PM".
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        FlowTask.hasTime(date, calendar: calendar) ? "\(day(date, now: now, calendar: calendar)) \(time(date))" : day(date, now: now, calendar: calendar)
    }

    static func priorityMarks(_ p: TaskPriority) -> String { String(repeating: "!", count: p.rawValue) }

    /// The parsed parts of a draft, for a live preview: ["Tomorrow 3:00 PM", "45m", "#launch"].
    static func parts(of d: TaskDraft, now: Date = Date()) -> [String] {
        var out: [String] = []
        if let s = d.scheduled { out.append(when(s, now: now)) }
        if let due = d.due { out.append("Due " + when(due, now: now)) }
        if let r = d.repeats { out.append(r.describe()) }
        if d.someday { out.append("Someday") }
        if let e = d.estimate { out.append(length(e)) }
        if let p = d.project { out.append("#" + p) }
        if d.priority != .none { out.append(priorityMarks(d.priority)) }
        return out
    }
}
