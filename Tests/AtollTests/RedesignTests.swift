import Testing
import SwiftUI
@testable import Atoll

@MainActor
@Suite("Redesign: Home's hero and Today strip")
struct HomeHeroTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, in minutes: Double, lasting: Double = 30) -> CalendarModel.Event {
        CalendarModel.Event(id: id, title: id, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + lasting) * 60),
                            isAllDay: false, color: .blue, location: nil, meetingURL: nil)
    }

    private func flow() -> FlowInbox.Item {
        .init(body: .question(BrainQuestion(key: "k", text: "Q?", detail: "", options: [])), added: now, expires: .distantFuture)
    }

    private func resolve(flow f: FlowInbox.Item? = nil, task: UUID? = nil, timer: String? = nil, meetings: [CalendarModel.Event] = [],
                         moment: NowModel.Moment? = nil, music: Bool = false) -> HomeHeroKind {
        .resolve(flow: f, activeTask: task, timer: timer, meetings: meetings, moment: moment, music: music, now: now)
    }

    @Test func idleWhenNothingNeedsYou() {
        #expect(resolve() == .idle)
    }

    @Test func flowWaitingOutranksEverything() {
        let item = flow()
        #expect(resolve(flow: item, task: UUID(), timer: "Focus", meetings: [event("m", in: 5)], music: true) == .flow(item))
    }

    @Test func theTaskYouAreOnComesNext() {
        let id = UUID()
        #expect(resolve(task: id, timer: "Focus", meetings: [event("m", in: 5)], music: true) == .task(id))
    }

    @Test func aTimerWithoutATaskStillCounts() {
        #expect(resolve(timer: "Deep Work", meetings: [event("m", in: 5)], music: true) == .timer("Deep Work"))
    }

    @Test func aMeetingCloseBeatsMusic() {
        let soon = event("soon", in: 20)
        #expect(resolve(meetings: [soon], music: true) == .meeting(soon))
        // Under way counts too.
        let underway = event("now", in: -10)
        #expect(resolve(meetings: [underway], music: true) == .meeting(underway))
    }

    @Test func aMeetingHoursOffWaitsBehindMusic() {
        let later = event("later", in: 180)
        #expect(resolve(meetings: [later], music: true) == .music)
        #expect(resolve(meetings: [later], music: false) == .meeting(later))
    }

    @Test func aFinishedMeetingIsNotNext() {
        #expect(resolve(meetings: [event("over", in: -90, lasting: 30)]) == .idle)
    }

    @Test func nowsOtherMomentsBeatMusicButNotAMeeting() {
        let m = NowModel.Moment.plan
        #expect(resolve(moment: m, music: true) == .moment(m))
        let soon = event("soon", in: 20)
        #expect(resolve(meetings: [soon], moment: m, music: true) == .meeting(soon))
    }

    @Test func todayStripSkipsTheTaskInFocusAndStopsAtThree() {
        let tasks = (1...6).map { FlowTask(title: "Task \($0)") }
        let strip = TodayStrip.next(tasks, excluding: tasks[1].id)
        #expect(strip.count == 3)
        #expect(strip.map(\.title) == ["Task 1", "Task 3", "Task 4"])
        #expect(TodayStrip.next([], excluding: nil).isEmpty)
    }

    @Test func readingsSayWhatTheNumberIs() {
        #expect(HeroReading.elapsed(42).0 == "42" && HeroReading.elapsed(42).1 == "sec")
        #expect(HeroReading.elapsed(12 * 60 + 20).0 == "12" && HeroReading.elapsed(12 * 60 + 20).1 == "min")
        #expect(HeroReading.elapsed(3600 + 4 * 60).0 == "1:04" && HeroReading.elapsed(3664).1 == "h")
        #expect(HeroReading.minutes(6).0 == "6")
        #expect(HeroReading.minutes(80).0 == "1:20")
    }

    @Test func homeKeepsTheIslandsArithmetic() {
        // The island sizes Home as homeHeight + momentHeight (+ the Claude strip): that must add up to the layout's body,
        // plus the air left under the carousel for the grabber when there's no Claude strip.
        let foot = HomeView.showsStrip ? 0 : HomeView.footRoom
        #expect(DS.Size.homeHeight + HomeView.momentHeight == HomeView.bodyHeight + foot)
        #expect(HomeView.bodyHeight == 4 + HomeView.heroHeight + HomeView.dockHeight)
    }
}

@MainActor
@Suite("Redesign: Now Playing")
struct NowPlayingRedesignTests {
    @Test func ribbonTimeSplitsIntoTwoHalves() {
        #expect(NowPlayingPresentation.Expanded.ribbon(97).lead == "1")
        #expect(NowPlayingPresentation.Expanded.ribbon(97).trail == "37")
        #expect(NowPlayingPresentation.Expanded.ribbon(5).lead == "0")
        #expect(NowPlayingPresentation.Expanded.ribbon(5).trail == "05")
        #expect(NowPlayingPresentation.Expanded.ribbon(3723).lead == "1:02")
        #expect(NowPlayingPresentation.Expanded.ribbon(3723).trail == "03")
        #expect(NowPlayingPresentation.Expanded.ribbon(-4).trail == "00")
    }

    @Test func theClosedHairlineRunsLeftWingThenRight() {
        typealias Edge = NowPlayingPresentation.CompactProgressEdge
        let run: CGFloat = 60
        // A quarter of the way: half the left wing, none of the right.
        #expect(Edge.filled(fraction: 0.25, run: run, side: .leading) == 30)
        #expect(Edge.filled(fraction: 0.25, run: run, side: .trailing) == 0)
        // Three quarters: the left wing full, half the right.
        #expect(Edge.filled(fraction: 0.75, run: run, side: .leading) == 60)
        #expect(Edge.filled(fraction: 0.75, run: run, side: .trailing) == 30)
        // Out of range stays in range.
        #expect(Edge.filled(fraction: 1.4, run: run, side: .trailing) == 60)
        #expect(Edge.filled(fraction: -1, run: run, side: .leading) == 0)
    }

    @Test func nowPlayingIsTallerThanTheOldRow() {
        #expect(NowPlayingPresentation.Expanded.rowHeight == ActivityKind.nowPlaying.rowHeight)
        #expect(NowPlayingPresentation.Expanded.rowHeight > 78)
    }
}

@MainActor
@Suite("Redesign: Prism cards")
struct PrismCardTests {
    @Test func cardGlassCarriesNoSparks() {
        // Sparks are for one moment a day, not for every card.
        #expect(PrismStyle.card.sparks == 0)
        #expect(PrismStyle.card.pitch >= PrismStyle.flow.pitch)
    }

    @Test func aWaitedCardSaysHowLong() {
        let fresh = FlowInbox.Item(body: .question(BrainQuestion(key: "k", text: "Q", detail: "", options: [])), added: Date(), expires: .distantFuture)
        #expect(FlowAskCard.waited(fresh) == "")
        let old = FlowInbox.Item(body: .question(BrainQuestion(key: "k", text: "Q", detail: "", options: [])),
                                 added: Date().addingTimeInterval(-12 * 60), expires: .distantFuture)
        #expect(FlowAskCard.waited(old) == "12 min ago")
    }

    @Test func theFlatLookStillShadesTheFlutes() {
        // Reduce Transparency forced on: the card still builds and the environment says it samples nothing behind.
        var env = PrismEnvironment(libraryLoaded: true)
        env.reduceTransparency = true
        #expect(!env.samplesBehind)
        #expect(env.tier == .full)
    }
}
