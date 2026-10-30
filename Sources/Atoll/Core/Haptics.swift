import AppKit

/// The 8.x haptics API, kept while call sites move to `HapticEngine` and `HapticEvent`. Both calls go through the
/// engine's rules (Settings, per-channel floors, a finger on the trackpad); new code names an event instead.
@MainActor
enum Haptics {
    /// An unconverted snap: played as an alignment on the shared channel, on the frame that shows the change.
    static func snap() { HapticEngine.shared.play(.legacySnap) }

    /// An unconverted confirm.
    static func confirm() { HapticEngine.shared.play(.legacyConfirm) }
}
