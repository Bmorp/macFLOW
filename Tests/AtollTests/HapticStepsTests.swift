import Testing
@testable import Atoll

@Suite("Haptics: steps along ranges and lists")
struct HapticStepsTests {
    @Test func countsTheStepsAMoveCrosses() {
        #expect(HapticEvent.steps(from: 0.10, to: 0.12, count: 16) == 0)     // inside one sixteenth
        #expect(HapticEvent.steps(from: 0.12, to: 0.13, count: 16) == 1)     // across 0.125
        #expect(HapticEvent.steps(from: 0.10, to: 0.60, count: 16) == 8)
        #expect(HapticEvent.steps(from: 0.60, to: 0.10, count: 16) == 8)     // either way
        #expect(HapticEvent.steps(from: -0.2, to: 1.4, count: 20) == 20)     // clamped to the range
    }

    @Test func anEndWinsOverTheStepsBeforeIt() throws {
        let toEnd = try #require(HapticEvent.along(from: 0.9, to: 1, count: 16, step: .sliderStep, end: .sliderEnd))
        #expect(toEnd.0 == .sliderEnd && toEnd.1 == 1)
        let step = try #require(HapticEvent.along(from: 0.2, to: 0.4, count: 16, step: .sliderStep, end: .sliderEnd))
        #expect(step.0 == .sliderStep && step.1 == 3)
        #expect(HapticEvent.along(from: 0.2, to: 0.21, count: 16, step: .sliderStep, end: .sliderEnd) == nil)
        // Resting at an end is not arriving at it.
        #expect(HapticEvent.along(from: 1, to: 1, count: 16, step: .sliderStep, end: .sliderEnd) == nil)
    }

    @Test func stepsAndRowsAreDetentsThatTheEngineThins() {
        for e in [HapticEvent.sliderStep, .seekStep, .volumeStep, .listRow] {
            #expect(e.rule.cue == .detent)
        }
        #expect(HapticEvent.gestureCommitted.rule.cue == .commit)
    }

    @Test func aFlickThroughAListDoesNotBuzz() {
        // 40 rows in 0.4 s: far past what a hand can feel as steps. Only a few get through.
        var policy = HapticPolicy()
        let touch = TouchEvidence(scroll: 0)
        var played = 0
        for i in 0..<40 {
            let t = Double(i) * 0.01
            var e = touch
            e.scroll = t
            if policy.decide(.detent, channel: .list, steps: 1, at: t, touch: e).plays { played += 1 }
        }
        #expect(played > 0 && played <= 6)
    }

    @Test func aSlowScrollTicksEveryRow() {
        var policy = HapticPolicy()
        var played = 0
        for i in 0..<10 {
            let t = Double(i) * 0.12   // about 8 rows a second
            if policy.decide(.detent, channel: .list, steps: 1, at: t, touch: TouchEvidence(scroll: t)).plays { played += 1 }
        }
        #expect(played == 10)
    }
}
