import Foundation

// The decisions behind every haptic, with no AppKit in sight, so they can be tested to the millisecond.
// `HapticEngine` feeds this the time, the cue and what the hands were just doing; it answers play or skip.

/// The three things a Mac trackpad can play. Nothing else exists: no intensity, no custom waveforms.
enum HapticPattern: Sendable, Hashable {
    /// A snap: something lined up, a step passed, a range ended.
    case alignment
    /// A stepped value changed level.
    case levelChange
    /// Everything else: something finished.
    case generic

    init(_ cue: HapticCue) {
        switch cue {
        case .detent, .landmark, .edge, .commit, .land: self = .alignment
        case .confirm: self = .generic
        case .level: self = .levelChange
        }
    }
}

/// When the hands last did something a finger on the trackpad would cause. Times are system uptime in seconds;
/// `-infinity` means never.
struct TouchEvidence: Sendable, Equatable {
    /// A mouse button (or the trackpad) is pressed right now: a drag or a press in progress.
    var buttonHeld = false
    /// A two-finger scroll.
    var scroll: TimeInterval = -.infinity
    /// A Force Touch pressure event.
    var pressure: TimeInterval = -.infinity
    var buttonDown: TimeInterval = -.infinity
    /// A release is a finger on the pad too: drops land on it.
    var buttonUp: TimeInterval = -.infinity
    var drag: TimeInterval = -.infinity
    /// The pointer moved. Only counts for `.land`, which answers the pointer coming to rest.
    var pointerMotion: TimeInterval = -.infinity

    static let none = TouchEvidence()

    /// Whether a finger was plausibly on the trackpad, doing the thing that asked for this cue.
    func touched(for cue: HapticCue, at t: TimeInterval, window: TimeInterval, landWindow: TimeInterval) -> Bool {
        if buttonHeld { return true }
        for when in [scroll, pressure, buttonDown, buttonUp, drag] where t - when <= window { return true }
        return cue == .land && t - pointerMotion <= landWindow
    }
}

/// Why a haptic didn't play.
enum HapticSkip: Sendable, Equatable {
    /// Haptic Feedback is off in Settings.
    case off
    /// The event is silent by rule (`HapticEvent`'s table).
    case silent
    /// Nothing suggests a finger on the trackpad caused this: a key press, a timer, an incoming alert.
    case untouched
    /// The channel played too recently; two pulses this close feel like one buzz.
    case floor
    /// A fast scrub: this detent is one of the ones left out so the rest stay distinct.
    case thinned
    /// Faster than any hand can feel steps: only landmarks and edges come through.
    case tooFast
}

enum HapticDecision: Sendable, Equatable {
    case play(HapticPattern, HapticTiming)
    case skip(HapticSkip)

    var plays: Bool { if case .play = self { return true }; return false }
}

/// The rules: per-channel floors, velocity thinning of detents, and the touch-evidence gate.
struct HapticPolicy {
    struct Tuning: Sendable, Equatable {
        /// Closest two haptics on one channel may be.
        var floor: TimeInterval = 0.035
        /// Edges get a shorter floor: a range end must come through even right after a detent.
        var edgeFloor: TimeInterval = 0.025
        /// One "done" per action: a drop that's accepted and then finishes quickly is still one confirm.
        var confirmFloor: TimeInterval = 0.25
        /// Detents per second that can each be felt as a separate step (N = ⌈v / feltRate⌉).
        var feltRate: Double = 25
        /// Above this many detents per second, only landmarks and edges fire.
        var landmarksOnlyAbove: Double = 60
        /// A pause this long ends a gesture; the next detent starts a new one at rest.
        var gestureGap: TimeInterval = 0.3
        /// How recent touch evidence must be.
        var touchWindow: TimeInterval = 0.12
        /// `.land` answers the pointer coming to rest, and the island lands a spring after that (hover delay plus
        /// about 0.3 s), so the pointer's motion counts for longer. Playing into an untouched pad is felt by no one.
        var landWindow: TimeInterval = 0.75
    }

    private struct Channel {
        var lastPlayed: TimeInterval = -.infinity
        var lastConfirm: TimeInterval = -.infinity
        var lastArrival: TimeInterval = -.infinity
        /// Detents per second, smoothed over the gesture. Zero at the start of one.
        var rate: Double = 0
        /// Detents since the last one that played.
        var pending = 0
    }

    var tuning = Tuning()
    private var channels: [HapticChannel: Channel] = [:]

    init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    /// How many detents make one felt step at this speed: every N-th fires.
    static func stride(rate: Double, feltRate: Double) -> Int {
        max(1, Int((rate / feltRate).rounded(.up)))
    }

    /// The current detent speed on a channel, for tests and diagnostics.
    func rate(on channel: HapticChannel) -> Double { channels[channel]?.rate ?? 0 }

    /// Decides one haptic. `steps` is how many detents this one call stands for (a drag can cross several moments
    /// in one event); it feeds the speed, and the call still fires at most once.
    mutating func decide(_ cue: HapticCue, channel: HapticChannel, timing: HapticTiming = .withFrame, steps: Int = 1,
                         at t: TimeInterval, touch: TouchEvidence, enabled: Bool = true) -> HapticDecision {
        guard enabled else { return .skip(.off) }
        var ch = channels[channel] ?? Channel()
        defer { channels[channel] = ch }

        // Speed is measured from every step that arrives, felt or not.
        if cue == .detent || cue == .landmark {
            let dt = t - ch.lastArrival
            if dt > tuning.gestureGap {
                ch.rate = 0
                ch.pending = 0
            } else {
                // Several steps in one event (or one turn of the run loop) count as very fast, not as infinite.
                let instant = Double(max(1, steps)) / max(dt, 1.0 / 240)
                ch.rate = ch.rate == 0 ? instant : ch.rate * 0.5 + instant * 0.5
            }
            ch.lastArrival = t
        }

        guard touch.touched(for: cue, at: t, window: tuning.touchWindow, landWindow: tuning.landWindow) else {
            return .skip(.untouched)
        }

        if cue == .detent {
            if ch.rate > tuning.landmarksOnlyAbove {
                ch.pending = 0
                return .skip(.tooFast)
            }
            ch.pending += max(1, steps)
            guard ch.pending >= Self.stride(rate: ch.rate, feltRate: tuning.feltRate) else { return .skip(.thinned) }
        }

        let since = t - ch.lastPlayed
        switch cue {
        case .edge:
            guard since >= tuning.edgeFloor else { return .skip(.floor) }
        case .confirm:
            guard since >= tuning.floor, t - ch.lastConfirm >= tuning.confirmFloor else { return .skip(.floor) }
        default:
            guard since >= tuning.floor else { return .skip(.floor) }
        }

        ch.lastPlayed = t
        if cue == .confirm { ch.lastConfirm = t }
        if cue == .detent || cue == .landmark { ch.pending = 0 }
        return .play(HapticPattern(cue), timing)
    }
}
