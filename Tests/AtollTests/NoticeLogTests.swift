import Testing
import Foundation
@testable import Atoll

@MainActor
@Suite("Notices: history, completions and quiet presentation", .serialized)
struct NoticeLogTests {
    @Test func passingReadoutsAreNotKept() {
        let now = Date()
        #expect(NoticeLog.notice(for: .volume(level: 0.4, muted: false), now: now) == nil)
        #expect(NoticeLog.notice(for: .trackChanged, now: now) == nil)
        #expect(NoticeLog.notice(for: .message(symbol: "doc.on.doc", text: "Copied", tint: .white), now: now) == nil)
    }

    @Test func finishedWorkIsACompletionAndNewsIsNot() throws {
        let now = Date()
        let download = try #require(NoticeLog.notice(for: .downloadFinished(URL(fileURLWithPath: "/tmp/a.pdf")), now: now))
        #expect(download.completion && download.group == "Downloads" && download.actionTitle == "Show")
        let build = try #require(NoticeLog.notice(for: .message(symbol: "checkmark.circle.fill", text: "Build", tint: .green), now: now))
        #expect(build.completion)
        let needs = try #require(NoticeLog.notice(for: .claudeNeedsYou(id: "a", name: "Atoll", folder: "x"), now: now))
        #expect(!needs.completion && needs.importance == .important && !needs.canWait)
    }

    @Test func completionsStayUntilDismissedOrStale() {
        let log = NoticeLog()
        let now = Date()
        log.record(.downloadFinished(URL(fileURLWithPath: "/tmp/a.pdf")), now: now)
        log.record(.claudeNeedsYou(id: "a", name: "Atoll", folder: "x"), now: now)
        #expect(log.completions(now: now).count == 1)
        #expect(log.completions(now: now.addingTimeInterval(NoticeLog.completionLifetime + 1)).isEmpty)
        log.dismiss(log.completions(now: now)[0].id)
        #expect(log.completions(now: now).isEmpty)
    }

    @Test func historyGroupsBySourceNewestFirst() {
        let log = NoticeLog()
        let now = Date()
        log.record(.claudeFinished(id: "a", name: "One", duration: 60), now: now)
        log.record(.downloadFinished(URL(fileURLWithPath: "/tmp/a.pdf")), now: now.addingTimeInterval(1))
        log.record(.claudeFinished(id: "b", name: "Two", duration: 60), now: now.addingTimeInterval(2))
        #expect(log.grouped.map(\.group) == ["Claude", "Downloads"])
        #expect(log.grouped.first?.notices.map(\.title) == ["Two", "One"])
    }

    @Test func historyIsBounded() {
        let log = NoticeLog()
        for i in 0..<(NoticeLog.capacity + 10) { log.record(.update(version: "9.\(i)")) }
        #expect(log.notices.count == NoticeLog.capacity)
    }
}
