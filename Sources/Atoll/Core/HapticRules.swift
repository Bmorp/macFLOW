import Foundation

extension HapticChannel {
    /// The Dock companion rising under the pointer.
    static let dock = HapticChannel("dock")
}

/// A haptic rule: what an event feels like. `cue == nil` means the event is deliberately silent.
struct HapticRule: Sendable, Equatable {
    let cue: HapticCue?
    let channel: HapticChannel
    let timing: HapticTiming
    /// The reason, in a sentence: the table is the documentation.
    let why: String

    init(_ cue: HapticCue?, _ channel: HapticChannel, _ timing: HapticTiming = .withFrame, why: String) {
        self.cue = cue
        self.channel = channel
        self.timing = timing
        self.why = why
    }
}

/// Every haptic moment in Mac Flow, in one place. Call sites name the event (`HapticEngine.shared.play(.sliderEnd)`)
/// and this table says what it feels like, so the language can't drift one call site at a time. Streams that call
/// `play(_:channel:timing:)` directly use the cue, channel and timing listed here for their event.
///
/// The silent events are listed on purpose: they are the places a haptic would be wrong, and nothing calls them.
enum HapticEvent: String, CaseIterable, Sendable {
    // Island
    case islandLanded, gestureCommitted, tabSelected, alertArrived, rubberBandLimit
    // Drops
    case dropTargetEntered, dropAccepted
    // Ranges
    case sliderEnd, seekEnd
    // Rewind
    case rewindMoment, rewindLandmark, rewindEnd, rewindAcceleratorLevel
    // StandBy
    case standByPageTurned, standByEnd, standByKeyboard
    // Widgets and the Dock
    case widgetSnapped, widgetAdded, dockLanded
    // Hold to talk
    case holdToTalkEngaged, holdToTalkReleased
    // Things handed off and done
    case copied, saved, checkedOff, workFinished
    // Flow Tasks
    case taskCompleted, taskLevelChanged, taskReordered
    // Presses whose result is on screen: launch, open, start, run, reopen, answer
    case buttonPressed
    // `Haptics.snap()` / `Haptics.confirm()` while call sites move to events
    case legacySnap, legacyConfirm

    /// A range end is felt on arrival only: moving into 0 or 1, not resting there or leaving it.
    static func reachedEnd(from old: Double, to new: Double) -> Bool {
        new != old && (new <= 0 || new >= 1)
    }

    var rule: HapticRule {
        switch self {
        case .islandLanded:
            HapticRule(.land, .island, why: "The island settled open under the pointer: play when the spring arrives, not when it starts.")
        case .gestureCommitted:
            HapticRule(.commit, .island, why: "Pull open, swipe up to close, Home to sheet and back, sideways tabs: the finger crossed the point where letting go completes it. Re-arms when the finger backs off.")
        case .tabSelected:
            HapticRule(nil, .island, why: "A click or a key already says it; the content sliding over shows it.")
        case .alertArrived:
            HapticRule(nil, .island, why: "Flow, Claude finished, Claude needs you, a track change: nobody's finger asked for it.")
        case .rubberBandLimit:
            HapticRule(nil, .island, why: "The resistance is the feedback.")
        case .dropTargetEntered:
            HapticRule(.edge, .drop, why: "A dragged file came over a place that takes it: it snapped into a target.")
        case .dropAccepted:
            HapticRule(.confirm, .drop, why: "The drop was taken.")
        case .sliderEnd:
            HapticRule(.edge, .slider, why: "A Control Center slider or the island's volume reached 0 or 100%, by drag or by scroll.")
        case .seekEnd:
            HapticRule(.edge, .seek, why: "The seek bar reached the start or the end of the track.")
        case .rewindMoment:
            HapticRule(.detent, .rewind, why: "The playhead moved to another moment. Thinned by speed, so a fast scrub never buzzes.")
        case .rewindLandmark:
            HapticRule(.landmark, .rewind, why: "The playhead crossed an hour mark or a change of app: never thinned.")
        case .rewindEnd:
            HapticRule(.edge, .rewind, why: "The playhead reached the start of the day or now.")
        case .rewindAcceleratorLevel:
            HapticRule(nil, .rewind, why: "Pressing harder on the Rewind arrows: the trackpad plays its own click at each level.")
        case .standByPageTurned:
            HapticRule(.commit, .standBy, why: "A two-finger swipe turned the page or the stack.")
        case .standByEnd:
            HapticRule(.edge, .standBy, why: "A swipe tried to go past the first or the last page.")
        case .standByKeyboard:
            HapticRule(nil, .standBy, why: "Arrow keys: no finger is on the trackpad.")
        case .widgetSnapped:
            HapticRule(.landmark, .widgets, why: "A dragged widget snapped onto a neighbour's edge. AppKit's alignment filter decides, so a fast drag doesn't rattle.")
        case .widgetAdded:
            HapticRule(.confirm, .widgets, why: "A widget went onto the desktop, which the gallery may be covering.")
        case .dockLanded:
            HapticRule(.land, .dock, why: "The Dock companion rose under the pointer resting on its handle. Not when opened from a menu.")
        case .holdToTalkEngaged:
            HapticRule(.level, .talk, .now, why: "The press crossed 0.45 s and Flow is listening: answer the press right away.")
        case .holdToTalkReleased:
            HapticRule(nil, .talk, why: "The trackpad already plays its own release click; another would double it.")
        case .copied:
            HapticRule(.confirm, .ui, why: "Something went onto the clipboard, which you can't see.")
        case .saved:
            HapticRule(.confirm, .ui, why: "A file was written: a day card saved to Pictures.")
        case .checkedOff:
            HapticRule(.confirm, .tasks, why: "A reminder was checked off: done.")
        case .workFinished:
            HapticRule(.confirm, .drop, why: "Work you started finished later: a compress. Shares the drop channel, so a drop that finishes at once confirms once.")
        case .taskCompleted:
            HapticRule(.level, .tasks, why: "The day's completion ring stepped up.")
        case .taskLevelChanged:
            HapticRule(.level, .tasks, why: "A stepped value changed: a priority, an estimate length.")
        case .taskReordered:
            HapticRule(.landmark, .tasks, why: "A dragged task snapped into a new place in the list, through the alignment filter.")
        case .buttonPressed:
            HapticRule(nil, .ui, why: "The click was the feedback and the result is on screen: launching, opening, starting, running, reopening, answering.")
        case .legacySnap:
            HapticRule(.land, .ui, why: "Migration only: an unconverted Haptics.snap(). Played as a landing so the island's hover-open keeps its haptic until it moves to islandLanded.")
        case .legacyConfirm:
            HapticRule(.confirm, .ui, why: "Migration only: an unconverted Haptics.confirm().")
        }
    }
}
