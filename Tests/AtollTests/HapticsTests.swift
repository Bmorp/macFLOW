import Testing
import Foundation
@testable import Atoll

/// A finger on the pad, pressing.
private let held = TouchEvidence(buttonHeld: true)

/// Runs `count` detents at `rate` per second on one channel and returns the times that played.
private func scrub(_ policy: inout HapticPolicy, rate: Double, count: Int, from t0: TimeInterval = 100,
                   channel: HapticChannel = .rewind) -> [TimeInterval] {
    var played: [TimeInterval] = []
    for i in 0..<count {
        let t = t0 + Double(i) / rate
        if policy.decide(.detent, channel: channel, at: t, touch: held).plays { played.append(t) }
    }
    return played
}

@Suite("Haptic policy")
struct HapticPolicyTests {
    @Test func cuesMapToTheThreePatterns() {
        #expect(HapticPattern(.detent) == .alignment)
        #expect(HapticPattern(.landmark) == .alignment)
        #expect(HapticPattern(.edge) == .alignment)
        #expect(HapticPattern(.commit) == .alignment)
        #expect(HapticPattern(.land) == .alignment)
        #expect(HapticPattern(.confirm) == .generic)
        #expect(HapticPattern(.level) == .levelChange)
    }

    @Test func timingIsPassedThrough() {
        var p = HapticPolicy()
        #expect(p.decide(.commit, channel: .island, at: 1, touch: held) == .play(.alignment, .withFrame))
        #expect(p.decide(.level, channel: .talk, timing: .now, at: 1, touch: held) == .play(.levelChange, .now))
    }

    @Test func thinningStride() {
        #expect(HapticPolicy.stride(rate: 0, feltRate: 25) == 1)
        #expect(HapticPolicy.stride(rate: 25, feltRate: 25) == 1)
        #expect(HapticPolicy.stride(rate: 25.1, feltRate: 25) == 2)
        #expect(HapticPolicy.stride(rate: 50, feltRate: 25) == 2)
        #expect(HapticPolicy.stride(rate: 60, feltRate: 25) == 3)
    }

    @Test func slowScrubFeelsEveryDetent() {
        var p = HapticPolicy()
        #expect(scrub(&p, rate: 20, count: 20).count == 20)
    }

    @Test func fastScrubIsThinnedToFeltRate() {
        var p = HapticPolicy()
        let played = scrub(&p, rate: 40, count: 40)   // one second
        #expect(played.count >= 15 && played.count <= 25)
        // Never closer than the floor: no buzz.
        for (a, b) in zip(played, played.dropFirst()) { #expect(b - a >= 0.035 - 1e-9) }
    }

    @Test func feltRateNeverExceeds25PerSecondAtAnySpeed() {
        for rate in stride(from: 5.0, through: 240, by: 5) {
            var p = HapticPolicy()
            let played = scrub(&p, rate: rate, count: Int(rate * 2))   // two seconds
            #expect(Double(played.count) / 2 <= 25.5, "rate \(rate)")
        }
    }

    @Test func aboveSixtyOnlyLandmarksAndEdgesFire() {
        var p = HapticPolicy()
        var detents = 0, landmarks = 0
        for i in 0..<100 {
            let t = 100 + Double(i) / 100   // 100 per second
            let cue: HapticCue = i % 20 == 10 ? .landmark : .detent
            if p.decide(cue, channel: .rewind, at: t, touch: held).plays {
                if cue == .detent { detents += 1 } else { landmarks += 1 }
            }
        }
        #expect(detents <= 1)    // only the first, before the speed is known
        #expect(landmarks == 5)
        #expect(p.decide(.edge, channel: .rewind, at: 101.0, touch: held).plays)
        #expect(p.decide(.detent, channel: .rewind, at: 101.01, touch: held) == .skip(.tooFast))
    }

    @Test func manyStepsInOneEventCountAsFast() {
        var p = HapticPolicy()
        // A drag crossing 5 moments per 60 Hz event is 300 moments a second.
        var played = 0
        for i in 0..<30 where p.decide(.detent, channel: .rewind, steps: 5, at: 100 + Double(i) / 60, touch: held).plays { played += 1 }
        #expect(played <= 1)
        #expect(p.rate(on: .rewind) > 60)
    }

    @Test func aPauseStartsANewGesture() {
        var p = HapticPolicy()
        _ = scrub(&p, rate: 100, count: 30)
        #expect(p.decide(.detent, channel: .rewind, at: 101, touch: held).plays)   // 0.7 s later
    }

    @Test func floorStopsADoubleFireOnAChannel() {
        var p = HapticPolicy()
        #expect(p.decide(.commit, channel: .island, at: 10, touch: held).plays)
        #expect(p.decide(.commit, channel: .island, at: 10.02, touch: held) == .skip(.floor))
        #expect(p.decide(.commit, channel: .island, at: 10.034, touch: held) == .skip(.floor))
        #expect(p.decide(.commit, channel: .island, at: 10.036, touch: held).plays)
    }

    @Test func channelsAreIndependent() {
        var p = HapticPolicy()
        #expect(p.decide(.confirm, channel: .drop, at: 10, touch: held).plays)
        // A confirm on one channel never swallows a range end on another (the old global throttle did).
        #expect(p.decide(.edge, channel: .slider, at: 10.001, touch: held).plays)
        #expect(p.decide(.commit, channel: .island, at: 10.002, touch: held).plays)
    }

    @Test func edgesHaveAShorterFloorAndNeverDoubleUp() {
        var p = HapticPolicy()
        #expect(p.decide(.detent, channel: .slider, at: 10, touch: held).plays)
        // 30 ms after a detent: too soon for another detent, not for the end.
        #expect(p.decide(.edge, channel: .slider, at: 10.03, touch: held).plays)
        // The same end twice inside 25 ms is one end.
        #expect(p.decide(.edge, channel: .slider, at: 10.04, touch: held) == .skip(.floor))
        #expect(p.decide(.edge, channel: .slider, at: 10.06, touch: held).plays)
    }

    @Test func edgesComeThroughAtAnySpeed() {
        var p = HapticPolicy()
        _ = scrub(&p, rate: 200, count: 100, channel: .seek)
        #expect(p.decide(.edge, channel: .seek, at: 100 + 100.0 / 200, touch: held).plays)
    }

    @Test func oneConfirmPerAction() {
        var p = HapticPolicy()
        #expect(p.decide(.confirm, channel: .drop, at: 10, touch: held).plays)
        // A drop that finishes 60 ms later is the same "done".
        #expect(p.decide(.confirm, channel: .drop, at: 10.06, touch: held) == .skip(.floor))
        #expect(p.decide(.confirm, channel: .drop, at: 10.3, touch: held).plays)
    }

    @Test func offMeansNothingAndRemembersNothing() {
        var p = HapticPolicy()
        #expect(p.decide(.edge, channel: .slider, at: 10, touch: held, enabled: false) == .skip(.off))
        #expect(p.decide(.edge, channel: .slider, at: 10.001, touch: held).plays)
    }
}

@Suite("Haptic touch gate")
struct HapticGateTests {
    @Test func nothingTouchedNothingPlays() {
        var p = HapticPolicy()
        #expect(p.decide(.confirm, channel: .ui, at: 10, touch: .none) == .skip(.untouched))
        #expect(p.decide(.edge, channel: .slider, at: 10, touch: .none) == .skip(.untouched))
    }

    @Test func recentEvidenceCounts() {
        for touch in [TouchEvidence(scroll: 9.9), TouchEvidence(pressure: 9.95), TouchEvidence(buttonDown: 9.89),
                      TouchEvidence(buttonUp: 9.99), TouchEvidence(drag: 9.9)] {
            var p = HapticPolicy()
            #expect(p.decide(.commit, channel: .island, at: 10, touch: touch).plays)
        }
    }

    @Test func staleEvidenceDoesNot() {
        var p = HapticPolicy()
        #expect(p.decide(.commit, channel: .island, at: 10, touch: TouchEvidence(scroll: 9.8)) == .skip(.untouched))
        #expect(p.decide(.commit, channel: .island, at: 10, touch: TouchEvidence(buttonDown: 9.5)) == .skip(.untouched))
    }

    @Test func pointerMotionOnlyCountsForLanding() {
        let rested = TouchEvidence(pointerMotion: 9.6)   // the pointer came to rest 0.4 s ago
        var p = HapticPolicy()
        #expect(p.decide(.commit, channel: .island, at: 10, touch: rested) == .skip(.untouched))
        #expect(p.decide(.land, channel: .island, at: 10, touch: rested).plays)
        var q = HapticPolicy()
        #expect(q.decide(.land, channel: .island, at: 10, touch: TouchEvidence(pointerMotion: 9)) == .skip(.untouched))
    }

    @Test func keyboardStepsKeepTheSpeedButArentFelt() {
        var p = HapticPolicy()
        for i in 0..<5 { #expect(p.decide(.detent, channel: .rewind, at: 10 + Double(i) * 0.1, touch: .none) == .skip(.untouched)) }
        #expect(p.rate(on: .rewind) > 5)
    }
}

@MainActor
private final class FakeClock: HapticClock { var now: TimeInterval = 1000 }

@MainActor
private final class FakePerformer: HapticPerformer {
    var played: [HapticDecision] = []
    func perform(_ pattern: HapticPattern, timing: HapticTiming) { played.append(.play(pattern, timing)) }
}

@MainActor
private final class FakeHands: TouchEvidenceSource {
    var touch = TouchEvidence(buttonHeld: true)
    func evidence(at t: TimeInterval) -> TouchEvidence { touch }
}

@Suite("Haptic engine") @MainActor
struct HapticEngineTests {
    @Test func playsThroughThePerformer() {
        let clock = FakeClock(), performer = FakePerformer(), hands = FakeHands()
        let engine = HapticEngine(clock: clock, performer: performer, evidence: hands, enabled: { true })
        engine.play(.edge, channel: .slider)
        clock.now += 0.1
        engine.play(.level, channel: .talk, timing: .now)
        clock.now += 0.1
        engine.play(.sliderEnd)
        #expect(performer.played == [.play(.alignment, .withFrame), .play(.levelChange, .now), .play(.alignment, .withFrame)])
    }

    @Test func respectsTheSetting() {
        let performer = FakePerformer()
        let engine = HapticEngine(clock: FakeClock(), performer: performer, evidence: FakeHands(), enabled: { false })
        engine.play(.commit, channel: .island)
        #expect(engine.play(.dropAccepted) == .skip(.off))
        #expect(performer.played.isEmpty)
    }

    @Test func silentEventsPlayNothing() {
        let performer = FakePerformer()
        let engine = HapticEngine(clock: FakeClock(), performer: performer, evidence: FakeHands(), enabled: { true })
        for event in HapticEvent.allCases where event.rule.cue == nil {
            #expect(engine.play(event) == .skip(.silent))
        }
        #expect(performer.played.isEmpty)
    }

    @Test func noDoubleFireFromTwoCallsInOneTurn() {
        let performer = FakePerformer()
        let engine = HapticEngine(clock: FakeClock(), performer: performer, evidence: FakeHands(), enabled: { true })
        engine.play(.dropTargetEntered)
        engine.play(.dropTargetEntered)
        engine.play(.dropAccepted)
        #expect(performer.played.count == 1)
    }

    @Test func untouchedIsSilent() {
        let performer = FakePerformer(), hands = FakeHands()
        hands.touch = .none
        let engine = HapticEngine(clock: FakeClock(), performer: performer, evidence: hands, enabled: { true })
        engine.play(.copied)
        engine.play(.standByPageTurned)
        #expect(performer.played.isEmpty)
    }
}

@Suite("Haptic rules table")
struct HapticRulesTests {
    @Test func everyEventIsExplained() {
        for event in HapticEvent.allCases { #expect(!event.rule.why.isEmpty, "\(event)") }
    }

    @Test func designRulesHold() {
        // Nothing for tabs, incoming alerts, rubber bands, keyboard page turns, plain presses, or the release of a
        // hold (the trackpad clicks its own), and none on top of the accelerator's level clicks.
        for event: HapticEvent in [.tabSelected, .alertArrived, .rubberBandLimit, .standByKeyboard, .buttonPressed,
                                   .holdToTalkReleased, .rewindAcceleratorLevel] {
            #expect(event.rule.cue == nil, "\(event)")
        }
        #expect(HapticEvent.holdToTalkEngaged.rule == HapticRule(.level, .talk, .now, why: HapticEvent.holdToTalkEngaged.rule.why))
        // Everything else lands with the frame that shows it.
        for event in HapticEvent.allCases where event != .holdToTalkEngaged { #expect(event.rule.timing == .withFrame, "\(event)") }
        for event: HapticEvent in [.sliderEnd, .seekEnd, .rewindEnd, .standByEnd, .dropTargetEntered] { #expect(event.rule.cue == .edge) }
        for event: HapticEvent in [.dropAccepted, .copied, .saved, .checkedOff, .workFinished, .widgetAdded] { #expect(event.rule.cue == .confirm) }
        #expect(HapticEvent.islandLanded.rule.cue == .land)
        #expect(HapticEvent.gestureCommitted.rule.cue == .commit)
        #expect([HapticEvent.rewindMoment, .rewindLandmark, .rewindEnd].allSatisfy { $0.rule.channel == .rewind })
        // A drop and the work it starts share a channel, so a fast finish confirms once.
        #expect(HapticEvent.workFinished.rule.channel == HapticEvent.dropAccepted.rule.channel)
    }

    @Test func rangeEndsAreFeltOnArrival() {
        #expect(HapticEvent.reachedEnd(from: 0.98, to: 1))
        #expect(HapticEvent.reachedEnd(from: 0.02, to: 0))
        #expect(!HapticEvent.reachedEnd(from: 1, to: 1))       // resting at the end
        #expect(!HapticEvent.reachedEnd(from: 1, to: 0.97))    // leaving it
        #expect(!HapticEvent.reachedEnd(from: 0.4, to: 0.5))
    }
}

@Suite("Rewind haptics")
struct RewindHapticsTests {
    private let cal = Calendar(identifier: .gregorian)

    private func moments() -> [BrainStore.Moment] {
        let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 13, minute: 40))!
        let apps = ["Xcode", "Xcode", "Xcode", "Xcode", "Safari", "Safari", "Safari"]
        return apps.enumerated().map { i, app in BrainStore.Moment(ts: base.addingTimeInterval(Double(i) * 300), mode: "coding", app: app) }
        // 13:40 13:45 13:50 13:55 | 14:00 (Safari) 14:05 14:10
    }

    @Test func endsLandmarksAndMoments() {
        let m = moments()
        #expect(RewindModel.feel(m, from: 1, to: 0, calendar: cal) == .rewindEnd)
        #expect(RewindModel.feel(m, from: 5, to: 6, calendar: cal) == .rewindEnd)
        #expect(RewindModel.feel(m, from: 1, to: 2, calendar: cal) == .rewindMoment)
        #expect(RewindModel.feel(m, from: 3, to: 4, calendar: cal) == .rewindLandmark)   // 14:00 and Safari
        #expect(RewindModel.feel(m, from: 4, to: 3, calendar: cal) == .rewindLandmark)   // either way
        #expect(RewindModel.feel(m, from: 1, to: 5, calendar: cal) == .rewindLandmark)   // a jump across it still counts
        #expect(RewindModel.feel(m, from: 2, to: 2, calendar: cal) == nil)
    }

    @Test func appChangeAloneIsALandmark() {
        var m = moments()
        m[2].app = "Notes"
        #expect(RewindModel.feel(m, from: 1, to: 2, calendar: cal) == .rewindLandmark)
    }

    @Test func pressureLevelsDoubleTheSpeed() {
        #expect((1...5).map(RewindModel.acceleratedRate(level:)) == [1, 2, 4, 8, 16])
        #expect(RewindModel.acceleratedRate(level: 9) == 16)
        #expect(RewindModel.acceleratedRate(level: 0) == 1)
    }
}

@Suite("Force Touch")
struct ForceTouchTests {
    @Test func swellFollowsThePress() {
        #expect(ForcePress(stage: 0, pressure: 0).towardDeep == 0)
        #expect(ForcePress(stage: 1, pressure: 0.3, stageTransition: 0).towardDeep == 0)
        #expect(ForcePress(stage: 1, pressure: 0.8, stageTransition: 0.6).towardDeep == 0.6)
        #expect(ForcePress(stage: 2, pressure: 0.2, stageTransition: 0).towardDeep == 1)
        #expect(ForcePress(stage: 2, pressure: 0.1, stageTransition: -0.25).towardDeep == 0.75)
    }

    @Test func normalizedAcrossStages() {
        #expect(ForcePress(stage: 0, pressure: 1).normalized(stages: 2) == 0)
        #expect(ForcePress(stage: 1, pressure: 0.5).normalized(stages: 2) == 0.25)
        #expect(ForcePress(stage: 2, pressure: 1).normalized(stages: 2) == 1)
        #expect(ForcePress(stage: 3, pressure: 0.5).normalized(stages: 5) == 0.5)
        #expect(ForcePress(stage: 1, pressure: 7).pressure == 1)   // clamped
    }

    @Test func trackerReportsTheMomentsThatMatter() {
        var t = ForcePressTracker()
        #expect(t.update(ForcePress(stage: 1, pressure: 0.1)) == .pressed)
        #expect(t.update(ForcePress(stage: 1, pressure: 0.6)) == nil)
        #expect(t.update(ForcePress(stage: 2, pressure: 0)) == .deepened(2))
        #expect(t.deepest == 2)
        #expect(t.update(ForcePress(stage: 1, pressure: 0.9)) == .eased(1))
        #expect(t.update(ForcePress(stage: 2, pressure: 0)) == .deepened(2))
        #expect(t.update(ForcePress(stage: 0, pressure: 0)) == .released)
        #expect(t.deepest == 0)
    }
}
