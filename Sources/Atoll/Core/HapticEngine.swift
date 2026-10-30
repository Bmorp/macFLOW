import AppKit
import CoreGraphics

/// A clock in system-uptime seconds, the timebase of `NSEvent.timestamp`. Injected so tests can step it.
@MainActor
protocol HapticClock: AnyObject {
    var now: TimeInterval { get }
}

/// Whatever actually plays a pattern. The real one is the trackpad; tests record.
@MainActor
protocol HapticPerformer: AnyObject {
    func perform(_ pattern: HapticPattern, timing: HapticTiming)
}

/// What the hands were just doing.
@MainActor
protocol TouchEvidenceSource: AnyObject {
    func evidence(at t: TimeInterval) -> TouchEvidence
}

/// Semantic haptics: every haptic in Mac Flow comes through here. A call says what happened (a cue, or an event from
/// `HapticEvent`'s table); the engine picks the pattern, lands it on the frame that shows the change, keeps each gesture
/// on its own channel, thins fast scrubs, and only plays when a finger is plausibly on the trackpad.
@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    private var policy: HapticPolicy
    private let clock: HapticClock
    private let performer: HapticPerformer
    private let evidence: TouchEvidenceSource
    private let enabled: @MainActor () -> Bool

    init(clock: HapticClock? = nil, performer: HapticPerformer? = nil, evidence: TouchEvidenceSource? = nil,
         tuning: HapticPolicy.Tuning = .init(), enabled: (@MainActor () -> Bool)? = nil) {
        self.clock = clock ?? SystemHapticClock()
        self.performer = performer ?? TrackpadPerformer()
        self.evidence = evidence ?? HapticInput.shared
        self.enabled = enabled ?? { Prefs.shared.haptics }
        policy = HapticPolicy(tuning: tuning)
        if evidence == nil { HapticInput.shared.start() }
    }

    /// The contract every stream calls. `.withFrame` plays on the frame that shows the change; `.now` answers a press.
    func play(_ cue: HapticCue, channel: HapticChannel = .ui, timing: HapticTiming = .withFrame) {
        play(cue, channel: channel, timing: timing, steps: 1)
    }

    /// `steps`: how many detents this call stands for, when one event crosses several (a drag over many moments).
    /// It feeds the speed the thinning reads; the call still fires at most once.
    @discardableResult
    func play(_ cue: HapticCue, channel: HapticChannel, timing: HapticTiming, steps: Int) -> HapticDecision {
        let decision = decide(cue, channel: channel, timing: timing, steps: steps)
        if case .play(let pattern, let timing) = decision { performer.perform(pattern, timing: timing) }
        return decision
    }

    /// An event from the rules table. Silent events play nothing.
    @discardableResult
    func play(_ event: HapticEvent, steps: Int = 1) -> HapticDecision {
        let rule = event.rule
        guard let cue = rule.cue else { return .skip(.silent) }
        return play(cue, channel: rule.channel, timing: rule.timing, steps: steps)
    }

    /// Asks the rules without playing, recording a play if it's allowed. For feedback something else performs
    /// (the alignment filter).
    fileprivate func decide(_ cue: HapticCue, channel: HapticChannel, timing: HapticTiming, steps: Int = 1) -> HapticDecision {
        let t = clock.now
        let on = enabled()
        // Read the hands only when it can matter.
        let touch = on ? evidence.evidence(at: t) : .none
        return policy.decide(cue, channel: channel, timing: timing, steps: steps, at: t, touch: touch, enabled: on)
    }

    func rate(on channel: HapticChannel) -> Double { policy.rate(on: channel) }
}

// MARK: - Alignment snaps

/// Snapping during a drag, through AppKit's `NSAlignmentFeedbackFilter`: it watches the drag's events and leaves out
/// snaps that come too fast or too close to feel, the way Finder and Keynote do. The engine's rules still apply on top
/// (Settings, the channel floor, a finger on the pad). One per drag target; feed it every drag event.
@MainActor
final class HapticAlignment {
    private let filter = NSAlignmentFeedbackFilter()
    private let event: HapticEvent
    private let engine: HapticEngine

    init(_ event: HapticEvent, engine: HapticEngine? = nil) {
        self.event = event
        self.engine = engine ?? .shared
    }

    /// Feeds the filter the event behind this drag step (`NSApp.currentEvent` inside a drag handler).
    func update(with event: NSEvent?) {
        guard let event, NSAlignmentFeedbackFilter.inputEventMask.contains(NSEvent.EventTypeMask(type: event.type)) else { return }
        filter.update(with: event)
    }

    /// One step of the drag. `previous`: where the object was last shown; `aligned`: where it's going, snapped;
    /// `unaligned`: where it would be without the snap. Points are in screen coordinates.
    func moved(previous: NSPoint, aligned: NSPoint, unaligned: NSPoint) {
        guard hypot(aligned.x - unaligned.x, aligned.y - unaligned.y) > 0.01,
              let token = filter.alignmentFeedbackTokenForMovement(in: nil, previousPoint: previous, alignedPoint: aligned, defaultPoint: unaligned),
              let cue = event.rule.cue,
              engine.decide(cue, channel: event.rule.channel, timing: .withFrame).plays else { return }
        filter.performFeedback([token], performanceTime: .drawCompleted)
    }
}

// MARK: - The real clock, trackpad and hands

@MainActor
final class SystemHapticClock: HapticClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@MainActor
final class TrackpadPerformer: HapticPerformer {
    func perform(_ pattern: HapticPattern, timing: HapticTiming) {
        let p: NSHapticFeedbackManager.FeedbackPattern = switch pattern {
        case .alignment: .alignment
        case .levelChange: .levelChange
        case .generic: .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: timing == .now ? .now : .drawCompleted)
    }
}

/// The touch evidence, read cheaply. Buttons, drags, scrolls and pointer motion come from the window server's record
/// of the last hardware event of each kind: a shared-memory read of about 1.5 µs, made only when a haptic is asked
/// for, and system-wide, so a file dragged in from Finder counts and a monitor that swallows scrolls (StandBy's)
/// can't hide them. Pressure shows up nowhere else, so a local monitor stamps its time; it runs only while a
/// Force Touch trackpad is pressed over Mac Flow's windows.
@MainActor
final class HapticInput: TouchEvidenceSource {
    static let shared = HapticInput()

    private var monitor: Any?
    private(set) var lastPressure: TimeInterval = -.infinity

    func start() {
        guard monitor == nil, !RenderMode.snapshot else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { event in
            MainActor.assumeIsolated { HapticInput.shared.note(event) }
            return event
        }
    }

    func note(_ event: NSEvent) {
        guard event.type == .pressure else { return }
        lastPressure = ProcessInfo.processInfo.systemUptime
        ForceTouch.shared.note(event)
    }

    func evidence(at t: TimeInterval) -> TouchEvidence {
        func last(_ type: CGEventType) -> TimeInterval {
            t - CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
        }
        var e = TouchEvidence()
        e.buttonHeld = NSEvent.pressedMouseButtons != 0
        e.buttonDown = max(last(.leftMouseDown), last(.rightMouseDown), last(.otherMouseDown))
        e.buttonUp = last(.leftMouseUp)
        e.drag = last(.leftMouseDragged)
        // The window server doesn't tell fingers on the pad from the momentum after they lift. That's harmless:
        // a pad nobody is touching plays nothing anyone feels.
        e.scroll = last(.scrollWheel)
        e.pointerMotion = max(last(.mouseMoved), e.drag)
        e.pressure = lastPressure
        return e
    }
}
