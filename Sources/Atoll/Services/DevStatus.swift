import Foundation

/// What a developer has going on, read from the Mac itself: the Git repositories you're working in (the folders your
/// Claude sessions are in, and ones seen before), servers listening on local ports, and — when the GitHub CLI is
/// installed and signed in — pull requests waiting on your review. Read on demand while the Developer section is open,
/// off the main thread; nothing is invented, and an integration that isn't set up says so.
@MainActor
final class DevStatus: ObservableObject {
    static let shared = DevStatus()

    struct Repo: Identifiable, Equatable, Sendable {
        var id: String { path }
        let path: String
        let name: String
        let branch: String
        let ahead: Int
        let behind: Int
        let changes: Int
        let lastCommit: String
        let lastWhen: String
    }

    struct Server: Identifiable, Equatable, Sendable {
        var id: String { "\(pid):\(port)" }
        let pid: Int32
        let process: String
        let port: Int
        var url: URL? { URL(string: "http://localhost:\(port)") }
    }

    struct PullRequest: Identifiable, Equatable, Sendable {
        var id: String { url }
        let title: String
        let repo: String
        let number: Int
        let url: String
    }

    enum GitHub: Equatable, Sendable { case unknown, notInstalled, signedOut, ready }

    @Published private(set) var repos: [Repo] = []
    @Published private(set) var servers: [Server] = []
    @Published private(set) var reviews: [PullRequest] = []
    @Published private(set) var github: GitHub = .unknown
    @Published private(set) var loading = false

    private var lastLocal: TimeInterval = -.infinity
    private var lastGitHub: TimeInterval = -.infinity
    private static let reposKey = "devRepos"

    /// Folders seen to be repositories before, so a repo stays listed after its Claude session ends.
    private var knownRepos: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.reposKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(12)), forKey: Self.reposKey) }
    }

    /// Local state every 10 s at most; GitHub every 2 min at most (it's a network call).
    func refresh(force: Bool = false) {
        guard !RenderMode.snapshot else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let local = force || now - lastLocal > 10
        let remote = force || now - lastGitHub > 120
        guard local || remote else { return }
        if local { lastLocal = now }
        if remote { lastGitHub = now }
        let candidates = Array(Set(ClaudeSessions.shared.sessions.map(\.cwd) + knownRepos))
        loading = true
        Task.detached(priority: .utility) {
            let repos = local ? Self.repos(in: candidates) : nil
            let servers = local ? Self.listeningServers() : nil
            let gh = remote ? Self.reviewRequests() : nil
            await MainActor.run {
                let shared = DevStatus.shared
                if let repos {
                    shared.repos = repos
                    shared.knownRepos = Array(Set(shared.knownRepos + repos.map(\.path))).sorted()
                }
                if let servers { shared.servers = servers }
                if let gh { shared.github = gh.0; shared.reviews = gh.1 }
                shared.loading = false
            }
        }
    }

    func debugSet(repos: [Repo], servers: [Server], reviews: [PullRequest], github: GitHub) {
        self.repos = repos; self.servers = servers; self.reviews = reviews; self.github = github
    }

    // MARK: Git

    nonisolated static func repos(in folders: [String]) -> [Repo] {
        var roots = Set<String>()
        for f in folders where FileManager.default.fileExists(atPath: f) {
            if let root = run("/usr/bin/git", ["-C", f, "rev-parse", "--show-toplevel"])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !root.isEmpty { roots.insert(root) }
        }
        return roots.sorted().compactMap(repo(at:))
    }

    nonisolated static func repo(at root: String) -> Repo? {
        guard let status = run("/usr/bin/git", ["-C", root, "status", "--porcelain=v2", "--branch"]) else { return nil }
        let parsed = parseStatus(status)
        let log = run("/usr/bin/git", ["-C", root, "log", "-1", "--format=%s%x1f%cr"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = log.components(separatedBy: "\u{1f}")
        return Repo(path: root, name: (root as NSString).lastPathComponent, branch: parsed.branch, ahead: parsed.ahead, behind: parsed.behind,
                    changes: parsed.changes, lastCommit: parts.first ?? "", lastWhen: parts.count > 1 ? parts[1] : "")
    }

    /// `git status --porcelain=v2 --branch`: the branch, how far ahead and behind its upstream, and changed paths.
    nonisolated static func parseStatus(_ text: String) -> (branch: String, ahead: Int, behind: Int, changes: Int) {
        var branch = "", ahead = 0, behind = 0, changes = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                for token in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if token.hasPrefix("+") { ahead = Int(token.dropFirst()) ?? 0 }
                    if token.hasPrefix("-") { behind = Int(token.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") {
                changes += 1
            }
        }
        return (branch == "(detached)" ? "detached" : branch, ahead, behind, changes)
    }

    // MARK: Servers

    /// Processes that build and serve things locally; plus anything on the usual development ports.
    nonisolated private static let devProcesses: Set<String> = [
        "node", "python", "Python", "python3", "ruby", "java", "go", "deno", "bun", "php", "uvicorn", "gunicorn", "vite",
        "next-serv", "com.docke", "docker", "postgres", "redis-ser", "mongod", "mysqld", "nginx", "caddy", "hugo",
        "jekyll", "swift", "beam.smp", "dotnet", "rails", "puma", "flask", "esbuild", "webpack",
    ]
    /// System listeners that sit on development-looking ports (AirPlay on 5000 and 7000, sharing).
    nonisolated private static let systemProcesses: Set<String> = ["ControlCe", "rapportd", "sharingd", "remoted", "IPNExtens", "launchd"]

    nonisolated static func listeningServers() -> [Server] {
        guard let out = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]) else { return [] }
        return parseListeners(out)
    }

    /// `lsof -F pcn`: `p` starts a process, `c` names it, each `n` is an address it listens on.
    nonisolated static func parseListeners(_ text: String) -> [Server] {
        var out: [Server] = [], seen = Set<String>()
        var pid: Int32 = 0, command = ""
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let portText = value.split(separator: ":").last, let port = Int(portText), port >= 1024,
                      !systemProcesses.contains(command) else { continue }
                let devPort = (3000...9999).contains(port)
                guard devProcesses.contains(command) || devPort else { continue }
                let key = "\(pid):\(port)"
                if seen.insert(key).inserted { out.append(Server(pid: pid, process: command, port: port)) }
            default: break
            }
        }
        return out.sorted { $0.port < $1.port }
    }

    // MARK: GitHub

    nonisolated static func reviewRequests() -> (GitHub, [PullRequest]) {
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return (.notInstalled, [])
        }
        guard run(gh, ["auth", "status"]) != nil else { return (.signedOut, []) }
        guard let json = run(gh, ["search", "prs", "--review-requested=@me", "--state=open", "--limit", "6",
                                  "--json", "title,number,url,repository"], timeout: 12),
              let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return (.ready, []) }
        let prs = rows.compactMap { r -> PullRequest? in
            guard let title = r["title"] as? String, let number = r["number"] as? Int, let url = r["url"] as? String else { return nil }
            let repo = (r["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
            return PullRequest(title: title, repo: repo, number: number, url: url)
        }
        return (.ready, prs)
    }

    // MARK: Running tools

    /// Runs a tool and returns its output, or nil if it failed or ran past `timeout` (then it's stopped).
    nonisolated static func run(_ path: String, _ args: [String], timeout: TimeInterval = 4) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationReason == .exit, p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
