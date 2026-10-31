import AppKit

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

    /// A GitHub Actions run (CI, a deployment) in one of your repositories.
    struct Run: Identifiable, Equatable, Sendable {
        let id: Int
        let repo: String
        let workflow: String
        let title: String
        let branch: String
        let status: String
        let conclusion: String?
        let updated: Date?
        let url: String
        var running: Bool { status != "completed" }
        var passed: Bool { conclusion == "success" }
    }

    struct Container: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let image: String
        let status: String
        let ports: String
    }

    enum Docker: Equatable, Sendable { case unknown, notInstalled, notRunning, ready }

    @Published private(set) var repos: [Repo] = []
    @Published private(set) var servers: [Server] = []
    @Published private(set) var reviews: [PullRequest] = []
    @Published private(set) var github: GitHub = .unknown
    @Published private(set) var loading = false
    /// The latest runs of each repository's workflows, newest first.
    @Published private(set) var runs: [Run] = []
    @Published private(set) var containers: [Container] = []
    @Published private(set) var docker: Docker = .unknown
    /// Runs seen in progress: when one finishes, you hear about it.
    private var watching: [Int: Run] = [:]
    private var watchWork: DispatchWorkItem?

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
            let repos = Self.repos(in: candidates)
            let servers = local ? Self.listeningServers() : nil
            let docker = local ? Self.dockerContainers() : nil
            let gh = remote ? Self.reviewRequests() : nil
            let runs = remote && gh?.0 == .ready ? Self.workflowRuns(for: repos.map(\.path)) : nil
            await MainActor.run {
                let shared = DevStatus.shared
                shared.repos = repos
                shared.knownRepos = Array(Set(shared.knownRepos + repos.map(\.path))).sorted()
                if let servers { shared.servers = servers }
                if let docker { shared.docker = docker.0; shared.containers = docker.1 }
                if let gh { shared.github = gh.0; shared.reviews = gh.1 }
                if let runs { shared.received(runs) }
                shared.loading = false
            }
        }
    }

    // MARK: Watching runs

    /// New runs replace the old; a watched run that has finished is announced (it lands in the notice history as
    /// finished work), and while any run is still going, runs are checked again in a minute — never otherwise.
    private func received(_ fresh: [Run]) {
        for run in fresh {
            if let was = watching[run.id], was.running, !run.running { announce(run) }
            if run.running { watching[run.id] = run } else { watching[run.id] = nil }
        }
        runs = fresh
        watchWork?.cancel()
        guard watching.values.contains(where: \.running) else { return }
        let paths = repos.map(\.path)
        let work = DispatchWorkItem {
            Task.detached(priority: .utility) {
                let runs = Self.workflowRuns(for: paths)
                await MainActor.run { DevStatus.shared.received(runs) }
            }
        }
        watchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func announce(_ run: Run) {
        let name = run.repo.split(separator: "/").last.map(String.init) ?? run.repo
        IslandManager.shared.primary?.model.showAlert(
            .message(symbol: run.passed ? "checkmark.circle.fill" : "xmark.octagon.fill",
                     text: "\(run.workflow) \(run.passed ? "passed" : run.conclusion == "cancelled" ? "was cancelled" : "failed") · \(name)",
                     tint: run.passed ? DS.Palette.green : DS.Palette.red),
            duration: 4)
    }

    /// Stops a local server after you confirm: the same quit signal Ctrl-C sends in its terminal.
    func stop(_ server: Server) {
        let alert = NSAlert()
        alert.messageText = "Stop \(server.process) on port \(server.port)?"
        alert.informativeText = "Mac Flow sends it the standard quit signal, as Ctrl-C in its terminal would. Anything it hasn't saved may be lost."
        alert.addButton(withTitle: "Stop").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        kill(server.pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { DevStatus.shared.refresh(force: true) }
    }

    /// Asks for a folder and watches it if it's a Git repository.
    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        panel.message = "Choose a folder inside a Git repository"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        Task.detached(priority: .userInitiated) {
            guard let root = Self.run("/usr/bin/git", ["-C", path, "rev-parse", "--show-toplevel"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty else { return }
            await MainActor.run {
                let shared = DevStatus.shared
                shared.knownRepos = Array(Set(shared.knownRepos + [root])).sorted()
                shared.refresh(force: true)
            }
        }
    }

    /// Stops reading a repository (until a Claude session works in it again).
    func forget(_ path: String) {
        knownRepos.removeAll { $0 == path }
        repos.removeAll { $0.path == path }
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

    // MARK: GitHub Actions

    /// `owner/name` for a GitHub remote (https, ssh or scp-style), nil for anything else.
    nonisolated static func githubSlug(_ remote: String) -> String? {
        var r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:"] where r.hasPrefix(prefix) {
            r = String(r.dropFirst(prefix.count))
            if r.hasSuffix(".git") { r = String(r.dropLast(4)) }
            let parts = r.split(separator: "/")
            return parts.count == 2 ? "\(parts[0])/\(parts[1])" : nil
        }
        return nil
    }

    nonisolated static func workflowRuns(for repoPaths: [String]) -> [Run] {
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        var out: [Run] = []
        for path in repoPaths {
            guard let remote = run("/usr/bin/git", ["-C", path, "remote", "get-url", "origin"]), let slug = githubSlug(remote),
                  let json = run(gh, ["run", "list", "--repo", slug, "--limit", "2", "--json",
                                      "databaseId,workflowName,displayTitle,status,conclusion,headBranch,updatedAt,url"], timeout: 10) else { continue }
            out += parseRuns(json, repo: slug)
        }
        return out.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    nonisolated static func parseRuns(_ json: String, repo: String) -> [Run] {
        guard let data = json.data(using: .utf8), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return rows.compactMap { r in
            guard let id = r["databaseId"] as? Int, let status = r["status"] as? String, let url = r["url"] as? String else { return nil }
            let conclusion = (r["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Run(id: id, repo: repo, workflow: r["workflowName"] as? String ?? "Workflow", title: r["displayTitle"] as? String ?? "",
                       branch: r["headBranch"] as? String ?? "", status: status, conclusion: conclusion,
                       updated: (r["updatedAt"] as? String).flatMap(iso.date(from:)), url: url)
        }
    }

    // MARK: Docker

    nonisolated static func dockerContainers() -> (Docker, [Container]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "\(home)/.docker/bin/docker",
                          "/Applications/Docker.app/Contents/Resources/bin/docker"]
        guard let docker = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return (.notInstalled, []) }
        guard let out = run(docker, ["ps", "--format", "{{json .}}"], timeout: 3) else { return (.notRunning, []) }
        return (.ready, parseContainers(out))
    }

    nonisolated static func parseContainers(_ text: String) -> [Container] {
        text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8), let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = r["ID"] as? String else { return nil }
            return Container(id: id, name: r["Names"] as? String ?? id, image: r["Image"] as? String ?? "",
                             status: r["Status"] as? String ?? "", ports: r["Ports"] as? String ?? "")
        }
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
