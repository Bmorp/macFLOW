import AppKit
import SwiftUI

/// Ask Claude from the notch. Uses the Claude Code that ships inside the Claude app (or one on your PATH),
/// signed in to your own account, with every tool turned off — it can answer, never act. The answer streams
/// into the island as it's written.
@MainActor
final class ClaudeAsk: ObservableObject {
    static let shared = ClaudeAsk()

    enum Phase: Equatable {
        case idle
        case checking
        case signedOut
        case thinking
        case answering
        case done
        case failed(String)
        case unavailable
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var question = ""
    @Published private(set) var answer = ""
    /// nil until checked.
    @Published private(set) var signedIn: Bool?

    private var process: Process?
    private var generation = 0

    // MARK: Finding Claude Code

    nonisolated static var binary: URL? {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Claude/claude-code")
        var bundled: [URL] = []
        for version in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            let dir = base.appendingPathComponent(version)
            for build in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let bin = dir.appendingPathComponent(build).appendingPathComponent("claude.app/Contents/MacOS/claude")
                if fm.isExecutableFile(atPath: bin.path) { bundled.append(bin) }
            }
        }
        if let newest = bundled.max(by: { $0.path.compare($1.path, options: .numeric) == .orderedAscending }) { return newest }
        for path in ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            let p = (path as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    var isInstalled: Bool { Self.binary != nil }

    /// `claude auth status` — a local check, no prompt is sent.
    func refreshSignIn() {
        guard let bin = Self.binary else { signedIn = false; return }
        Task.detached(priority: .utility) {
            let ok = Self.authStatus(bin)
            await MainActor.run { ClaudeAsk.shared.signedIn = ok }
        }
    }

    nonisolated private static func authStatus(_ bin: URL) -> Bool {
        let p = Process()
        p.executableURL = bin
        p.arguments = ["auth", "status"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["loggedIn"] as? Bool) ?? false
    }

    // MARK: Asking

    func ask(_ prompt: String, display: String? = nil) {
        cancel()
        generation += 1
        let gen = generation
        question = display ?? prompt
        answer = ""
        guard let bin = Self.binary else { phase = .unavailable; return }
        phase = .checking
        let known = signedIn
        Task.detached(priority: .userInitiated) {
            let ok = known ?? Self.authStatus(bin)
            await MainActor.run {
                let me = ClaudeAsk.shared
                guard me.generation == gen else { return }
                me.signedIn = ok
                if ok { me.start(bin, prompt: prompt, generation: gen) } else { me.phase = .signedOut }
            }
        }
    }

    private func start(_ bin: URL, prompt: String, generation gen: Int) {
        phase = .thinking
        let p = Process()
        p.executableURL = bin
        p.arguments = ["-p", prompt,
                       "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                       "--tools", "",
                       "--no-session-persistence",
                       "--append-system-prompt",
                       "You are answering inside a small panel in the Mac's notch. Be brief and direct: a few short sentences or a short list, no headings, unless asked for more."]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        let reader = StreamReader()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for event in reader.feed(data) {
                DispatchQueue.main.async { ClaudeAsk.shared.handle(event, generation: gen) }
            }
        }
        p.terminationHandler = { _ in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                let me = ClaudeAsk.shared
                guard me.generation == gen else { return }
                if me.phase == .thinking || me.phase == .answering {
                    me.phase = me.answer.isEmpty ? .failed("Claude didn’t answer. Try again, or ask in Claude.") : .done
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            phase = .failed("Couldn’t start Claude Code.")
        }
    }

    private func handle(_ event: StreamReader.Event, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case .delta(let text):
            if phase != .answering { phase = .answering }
            answer += text
        case .message(let text):
            if answer.isEmpty { answer = text; phase = .answering }
        case .result(let text, let isError):
            if isError {
                let lower = text.lowercased()
                if lower.contains("log in") || lower.contains("login") || lower.contains("auth") {
                    signedIn = false
                    phase = .signedOut
                } else {
                    phase = .failed(text.isEmpty ? "Claude couldn’t answer that." : String(text.prefix(160)))
                }
            } else {
                if answer.isEmpty { answer = text }
                phase = .done
            }
        }
    }

    func cancel() {
        generation += 1
        if let process, process.isRunning { process.terminate() }
        process = nil
        if phase != .idle { phase = .idle }
    }

    #if DEBUG
    func debugSet(question q: String, answer a: String, phase p: Phase) { question = q; answer = a; phase = p }
    #endif

    // MARK: Elsewhere

    /// Opens Terminal to sign Claude Code in to your account (one time).
    func signIn() {
        guard let bin = Self.binary else { return }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Sign in to Claude for Mac Flow.command")
        let body = """
        #!/bin/zsh
        clear
        echo "Sign in to Claude so Mac Flow can answer from the notch."
        echo
        "\(bin.path)" auth login
        echo
        echo "All set — you can close this window and ask again from the notch."
        """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
        signedIn = nil
    }

    /// Hands the question to Claude itself.
    func openInClaude(_ text: String? = nil) {
        var comps = URLComponents(string: "https://claude.ai/new")!
        comps.queryItems = [URLQueryItem(name: "q", value: text ?? question)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}

/// Splits Claude Code's `stream-json` output into answer text.
final class StreamReader: @unchecked Sendable {
    enum Event { case delta(String), message(String), result(String, Bool) }
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ data: Data) -> [Event] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var events: [Event] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { continue }
            switch type {
            case "stream_event":
                if let e = obj["event"] as? [String: Any], e["type"] as? String == "content_block_delta",
                   let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String {
                    events.append(.delta(t))
                }
            case "assistant":
                if let m = obj["message"] as? [String: Any], let content = m["content"] as? [[String: Any]] {
                    let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                    if !text.isEmpty { events.append(.message(text)) }
                }
            case "result":
                events.append(.result(obj["result"] as? String ?? "", obj["is_error"] as? Bool ?? false))
            default:
                break
            }
        }
        return events
    }
}
