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
}
