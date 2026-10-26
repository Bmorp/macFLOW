import AppKit

/// Force Touch feedback, used only where Apple documents a meaning for it
/// (`playing-haptics.md › Desktop`): alignment for snapping and range ends, generic for completion.
/// Nothing fires on hover, list movement or incoming alerts.
@MainActor
enum Haptics {
    private static var last: TimeInterval = 0

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern, minInterval: TimeInterval = 0.08) {
        guard Prefs.shared.haptics else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last >= minInterval else { return }
        last = now
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// The island settles open under the pointer, a gesture crosses its commit point,
    /// or a scrubber reaches either end.
    static func snap() { perform(.alignment) }

    /// A discrete action completed: a drop was accepted, an item was copied.
    static func confirm() { perform(.generic) }
}
