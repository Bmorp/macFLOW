import AppKit

/// Semantic haptics. Placeholder until the Haptics 2.0 stream lands: it forwards to `Haptics`
/// so call sites can move to cues now. The signature of `play` is the contract; the body is not.
@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    func play(_ cue: HapticCue, channel: HapticChannel = .ui, timing: HapticTiming = .withFrame) {
        switch cue {
        case .confirm: Haptics.confirm()
        default: Haptics.snap()
        }
    }
}
