import Foundation

/// A moment, as Flow's learners see it: when it is, what kind of work, how deep into it, how scattered, how close the
/// next meeting is, whether music or a focus block is on. Plain values, so a learner can be trained and tested without
/// the app running.
struct Situation: Sendable, Hashable, Codable {
    var date: Date
    var mode: WorkMode = .other
    /// Minutes into the current stretch of this kind of work.
    var minutesInSession: Double = 0
    var switchesLast15: Int = 0
    /// Minutes to the next meeting; nil when there's none coming today.
    var minutesToMeeting: Double? = nil
    var musicPlaying = false
    var focusRunning = false
}

/// One situation (and, for a suggestion, what it points at) as a fixed-length vector. Deterministic: the same
/// situation always gives the same numbers, which is what lets the policy be tested and explained.
enum ContextFeatures {
    /// Part of the day, the way people talk about it.
    enum Part: Int, CaseIterable, Sendable {
        case night, morning, afternoon, evening

        init(hour: Int) {
            switch hour {
            case 0..<6: self = .night
            case 6..<12: self = .morning
            case 12..<17: self = .afternoon
            default: self = .evening
            }
        }

        var label: String {
            switch self {
            case .night: "at night"
            case .morning: "in the morning"
            case .afternoon: "in the afternoon"
            case .evening: "in the evening"
            }
        }

        /// "before noon", "before 5", "after 5", "at night": how the acknowledgement of a "not then" reads.
        var bound: String {
            switch self {
            case .night: "at night"
            case .morning: "before noon"
            case .afternoon: "before 5"
            case .evening: "after 5"
            }
        }

        /// A representative hour, for teaching a "not then" answer.
        var hours: [Int] {
            switch self {
            case .night: [1, 4]
            case .morning: [8, 10]
            case .afternoon: [13, 15, 16]
            case .evening: [18, 21]
            }
        }
    }

    /// Minutes-to-meeting buckets: none, more than an hour, 30–60, 10–30, under 10.
    static let meetingBuckets = 5
    /// What a suggestion points at (an app, a project, an artist), hashed into a few slots.
    static let targetBuckets = 8

    // Layout. Kept in one place so explanations can name what moved a decision.
    static let bias = 0
    static let hourSin = 1, hourCos = 2
    static let part = 3                                   // 4 slots
    static let weekend = 7
    static let mode = 8                                   // one per WorkMode
    static let session = mode + WorkMode.allCases.count   // log-scaled minutes in
    static let switches = session + 1
    static let meeting = switches + 1                     // 5 slots
    static let music = meeting + meetingBuckets
    static let focus = music + 1
    static let target = focus + 1                         // 8 slots
    static let count = target + targetBuckets

    static func vector(_ s: Situation, target: String? = nil, calendar: Calendar = .current) -> [Double] {
        var x = [Double](repeating: 0, count: count)
        x[bias] = 1
        let c = calendar.dateComponents([.hour, .minute], from: s.date)
        let hour = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        let angle = hour / 24 * 2 * .pi
        x[hourSin] = sin(angle)
        x[hourCos] = cos(angle)
        x[part + Part(hour: c.hour ?? 0).rawValue] = 1
        x[weekend] = calendar.isDateInWeekend(s.date) ? 1 : 0
        if let i = WorkMode.allCases.firstIndex(of: s.mode) { x[mode + i] = 1 }
        // Ten minutes in and two hours in differ more than two hours and four.
        x[session] = min(1.2, log1p(max(0, s.minutesInSession)) / log1p(240))
        x[switches] = Double(min(max(0, s.switchesLast15), 30)) / 15
        x[meeting + meetingBucket(s.minutesToMeeting)] = 1
        x[music] = s.musicPlaying ? 1 : 0
        x[focus] = s.focusRunning ? 1 : 0
        if let t = target?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty {
            x[Self.target + Int(stableHash(t) % UInt64(targetBuckets))] = 1
        }
        return x
    }

    static func meetingBucket(_ minutes: Double?) -> Int {
        guard let m = minutes, m >= 0 else { return 0 }
        switch m {
        case ..<10: return 4
        case ..<30: return 3
        case ..<60: return 2
        default: return 1
        }
    }

    /// FNV-1a: stable across launches, unlike `hashValue`.
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return h
    }

    /// What a feature means, for "why" lines and Settings. Nil for the ones that don't read as a reason.
    static func reason(_ i: Int, situation s: Situation) -> String? {
        switch i {
        case part..<(part + 4): return Part(rawValue: i - part)?.label
        case weekend: return "at weekends"
        case mode..<session:
            let m = WorkMode.allCases[i - mode]
            return m == .other || m == .idle ? nil : "while \(m.label.lowercased())"
        case session: return s.minutesInSession >= 60 ? "deep into a stretch" : nil
        case switches: return s.switchesLast15 >= 10 ? "when you’re switching a lot" : nil
        case meeting..<music: return i == meeting ? nil : "with a meeting coming up"
        case music: return "with music on"
        default: return nil
        }
    }
}
