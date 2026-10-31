import SwiftUI

/// Something the island told you, kept after it has gone: the history behind every alert worth remembering, grouped
/// by where it came from. Finished work (a download, a focus block, a Claude session, a build) is a completion, and
/// stays in the activity stack until you dismiss it.
struct Notice: Identifiable {
    enum Importance: Int, Comparable {
        case quiet, normal, important
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    let id = UUID()
    let date: Date
    let group: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let importance: Importance
    /// Finished work, rather than news.
    let completion: Bool
    /// Whether it may wait in history instead of interrupting deep work.
    let canWait: Bool
    var actionTitle: String? = nil
    var action: (@MainActor () -> Void)? = nil
    /// Kept back from popping up because you were focusing or on a call.
    var held = false
    var dismissed = false
}

@MainActor
final class NoticeLog: ObservableObject {
    static let shared = NoticeLog()

    @Published private(set) var notices: [Notice] = []
    static let capacity = 60
    /// How long finished work stays in the activity stack if you don't dismiss it.
    static let completionLifetime: TimeInterval = 3 * 3600

    /// Records an alert worth remembering; nil for the ones that are only ever a passing readout (volume, a track).
    @discardableResult
    func record(_ alert: IslandAlert, now: Date = Date()) -> Notice? {
        guard var n = Self.notice(for: alert, now: now) else { return nil }
        n.held = shouldHold(n)
        notices.insert(n, at: 0)
        if notices.count > Self.capacity { notices.removeLast(notices.count - Self.capacity) }
        return n
    }

    /// While a focus block runs or you're on a call, only what's important interrupts; the rest waits here.
    func shouldHold(_ n: Notice) -> Bool {
        guard Prefs.shared.quietDuringFocus, n.canWait, n.importance < .important, !RenderMode.snapshot else { return false }
        return FocusTimer.shared.phase == .running || ActivityCenter.shared.call != nil
    }

    func dismiss(_ id: UUID) {
        guard let i = notices.firstIndex(where: { $0.id == id }) else { return }
        notices[i].dismissed = true
    }

    func clearAll() { notices.removeAll() }

    /// Finished work still waiting to be seen, newest first.
    func completions(now: Date = Date()) -> [Notice] {
        notices.filter { $0.completion && !$0.dismissed && now.timeIntervalSince($0.date) < Self.completionLifetime }
    }

    /// How many notices waited while you were focusing, and haven't been dismissed.
    var heldCount: Int { notices.filter { $0.held && !$0.dismissed }.count }

    /// History grouped by source, groups ordered by their newest notice.
    var grouped: [(group: String, notices: [Notice])] {
        var order: [String] = []
        var by: [String: [Notice]] = [:]
        for n in notices where !n.dismissed {
            if by[n.group] == nil { order.append(n.group) }
            by[n.group, default: []].append(n)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    func debugSet(_ list: [Notice]) { notices = list }

    // MARK: From alerts

    static func notice(for alert: IslandAlert, now: Date) -> Notice? {
        switch alert {
        case .volume, .brightness, .charging, .trackChanged, .tip, .learn, .brainSuggestion, .brainQuestion, .lens:
            return nil
        case .lowBattery(let level):
            return Notice(date: now, group: "Power", title: "Battery low", detail: "\(level)% left", symbol: "battery.25",
                          tint: DS.Palette.red, importance: .important, completion: false, canWait: false)
        case .device(let d):
            let levels = [d.left.map { "L \($0)%" }, d.right.map { "R \($0)%" }, d.caseLevel.map { "Case \($0)%" }, d.single.map { "\($0)%" }]
                .compactMap { $0 }.joined(separator: " · ")
            return Notice(date: now, group: "Devices", title: d.name, detail: d.connected ? (levels.isEmpty ? "Connected" : levels) : "Disconnected",
                          symbol: d.symbol, tint: DS.Palette.green, importance: .normal, completion: false, canWait: false)
        case .privacy(let camera, let app):
            return Notice(date: now, group: "Privacy", title: camera ? "Camera in use" : "Microphone in use", detail: app ?? "",
                          symbol: camera ? "video.fill" : "mic.fill", tint: camera ? DS.Palette.green : DS.Palette.orange,
                          importance: .quiet, completion: false, canWait: true)
        case .downloadFinished(let url):
            return Notice(date: now, group: "Downloads", title: url.lastPathComponent, detail: "Downloaded", symbol: "arrow.down.circle.fill",
                          tint: DS.Palette.blue, importance: .normal, completion: true, canWait: true, actionTitle: "Show",
                          action: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        case .timerFinished(let label):
            return Notice(date: now, group: "Focus", title: "\(label) finished", detail: "Time's up", symbol: "timer",
                          tint: DS.Palette.orange, importance: .important, completion: true, canWait: false)
        case .meetingSoon(let e, let minutes):
            return Notice(date: now, group: "Calendar", title: e.title, detail: "In \(minutes) min", symbol: "calendar",
                          tint: DS.Palette.green, importance: .important, completion: false, canWait: false,
                          actionTitle: e.meetingURL != nil ? "Join" : "Open", action: { CalendarModel.shared.open(e) })
        case .message(let symbol, let text, let tint):
            // Only a build or script finishing (posted by your own tools) is worth keeping; confirmations aren't.
            guard symbol == "checkmark.circle.fill" || symbol == "xmark.octagon.fill" else { return nil }
            return Notice(date: now, group: "Activity", title: text, detail: symbol == "checkmark.circle.fill" ? "Finished" : "Failed",
                          symbol: symbol, tint: tint, importance: .normal, completion: true, canWait: true)
        case .claudeFinished(let id, let name, let duration):
            return Notice(date: now, group: "Claude", title: name, detail: "Finished · \(AlertView.duration(duration))", symbol: "asterisk",
                          tint: ClaudeSessions.tint, importance: .normal, completion: true, canWait: true, actionTitle: "Open",
                          action: { ClaudeSessions.shared.open(ClaudeSessions.shared.sessions.first { $0.id == id }) })
        case .claudeNeedsYou(let id, let name, let folder):
            return Notice(date: now, group: "Claude", title: name, detail: "Needs you · \(folder)", symbol: "asterisk",
                          tint: ClaudeSessions.tint, importance: .important, completion: false, canWait: false, actionTitle: "Open",
                          action: { ClaudeSessions.shared.open(ClaudeSessions.shared.sessions.first { $0.id == id }) })
        case .update(let version):
            return Notice(date: now, group: "Mac Flow", title: "Mac Flow \(version)", detail: "Update available", symbol: "arrow.down.app",
                          tint: BrainStyle.tint, importance: .normal, completion: false, canWait: true)
        }
    }
}
