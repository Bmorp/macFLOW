import AppKit

/// What a closed island does with a sideways two-finger scroll over a live activity: vertical stays open/close,
/// sideways belongs to the activity (skip a track, nudge a timer). The island engine routes phased horizontal
/// scrolls here while compact. Placeholder until the activities redesign lands; the signature is the contract.
@MainActor
enum CompactGestures {
    /// `deltaX` in points this event, `phase` from the scroll event, `velocity` in points per second.
    /// Returns true when the activity used the scroll, so the island doesn't.
    static func scroll(kind: ActivityKind, deltaX: CGFloat, phase: NSEvent.Phase, velocity: CGFloat) -> Bool {
        false
    }
}
