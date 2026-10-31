import Testing
@testable import Atoll

@Suite("Developer status: reading git and lsof")
struct DevStatusTests {
    @Test func readsBranchAheadBehindAndChanges() {
        let out = """
        # branch.oid 93690f7
        # branch.head pro
        # branch.upstream origin/pro
        # branch.ab +3 -1
        1 .M N... 100644 100644 100644 a b Sources/Atoll/Surfaces/Workspace.swift
        ? Tests/AtollTests/DevStatusTests.swift
        """
        let s = DevStatus.parseStatus(out)
        #expect(s.branch == "pro" && s.ahead == 3 && s.behind == 1 && s.changes == 2)
        #expect(DevStatus.parseStatus("# branch.head (detached)\n").branch == "detached")
    }

    @Test func findsDevServersAndSkipsSystemListeners() {
        let out = """
        p501
        cControlCe
        n*:5000
        n*:7000
        p812
        cnode
        n*:3000
        n[::1]:3000
        p900
        cpython3
        n127.0.0.1:8000
        p950
        cSpotify
        n*:57621
        """
        let servers = DevStatus.parseListeners(out)
        #expect(servers.map(\.port) == [3000, 8000])           // AirPlay's 5000/7000 and Spotify's high port aren't dev servers
        #expect(servers.first?.process == "node")
        #expect(servers.count == 2)                              // IPv4 and IPv6 on one port count once
    }

    @Test func readsGitHubRemotesInEveryForm() {
        #expect(DevStatus.githubSlug("git@github.com:Bmorp/macFLOW.git") == "Bmorp/macFLOW")
        #expect(DevStatus.githubSlug("https://github.com/Bmorp/macFLOW") == "Bmorp/macFLOW")
        #expect(DevStatus.githubSlug("ssh://git@github.com/Bmorp/macFLOW.git\n") == "Bmorp/macFLOW")
        #expect(DevStatus.githubSlug("https://gitlab.com/a/b.git") == nil)
    }

    @Test func readsActionsRuns() throws {
        let json = """
        [{"conclusion":"success","databaseId":40378371611,"displayTitle":"pages build and deployment","headBranch":"main","status":"completed","updatedAt":"2026-10-26T18:31:13Z","url":"https://github.com/Bmorp/macFLOW/actions/runs/40378371611","workflowName":"pages-build-deployment"},
         {"conclusion":"","databaseId":7,"displayTitle":"Release","headBranch":"main","status":"in_progress","updatedAt":"2026-10-26T18:40:00Z","url":"u","workflowName":"Release"}]
        """
        let runs = DevStatus.parseRuns(json, repo: "Bmorp/macFLOW")
        #expect(runs.count == 2)
        let done = try #require(runs.first)
        #expect(done.passed && !done.running && done.updated != nil && done.workflow == "pages-build-deployment")
        #expect(runs[1].running && runs[1].conclusion == nil)       // an empty conclusion means not finished
    }

    @Test func readsDockerContainers() {
        let lines = """
        {"ID":"a1","Image":"postgres:16","Names":"db","Ports":"0.0.0.0:5432->5432/tcp","Status":"Up 2 hours"}
        {"ID":"b2","Image":"redis","Names":"cache","Ports":"","Status":"Up 5 minutes"}
        """
        let c = DevStatus.parseContainers(lines)
        #expect(c.map(\.name) == ["db", "cache"])
        #expect(c.first?.ports.contains("5432") == true)
    }
}

@MainActor
@Suite("Command centre")
struct CommandCentreTests {
    @Test func plainWordsOpenWorkspaceSections() {
        #expect(SmartCommand.parse("servers").contains(.workspace(.developer)))
        #expect(SmartCommand.parse("show my running servers").contains(.workspace(.developer)))
        #expect(SmartCommand.parse("show my connected devices").contains(.workspace(.devices)))
        #expect(SmartCommand.parse("summarise my active work").contains(.workspace(.overview)))
        #expect(SmartCommand.parse("clipboard").contains(.workspace(.clipboard)))
        #expect(SmartCommand.parse("cpu").contains(.workspace(.system)))
    }

    @Test func focusModeIsALocalActionAndStoppingAsksFirst() {
        #expect(SmartCommand.parse("switch to focus mode").contains(.focusMode))
        #expect(SmartCommand.focusMode.category == .localAction)
        #expect(SmartCommand.stopServer(pid: 1, port: 3000, process: "node").asksFirst)
        #expect(SmartCommand.workspace(.system).category == .readOnly)
    }
}
