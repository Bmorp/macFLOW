import SwiftUI

/// The language models Mac Flow can use, each with an honest status and a way to set it up. Flow (chat, summaries,
/// parsing) runs on Apple's on-device model; Ask Claude in search runs your own Claude Code, signed in to your account,
/// with every tool turned off. Neither is faked when it isn't there: its status says why, and how to fix it.
struct AIProviderStatus: Identifiable {
    enum State: Equatable { case ready, unavailable(String), signedOut, checking }

    struct Setup {
        let title: String
        let run: @MainActor () -> Void
    }

    let id: String
    let name: String
    let usedFor: String
    let state: State
    /// What to press to set it up, when it isn't ready.
    var setup: Setup?
}

@MainActor
enum AIProviders {
    static var all: [AIProviderStatus] { [apple, claude] }

    static var apple: AIProviderStatus {
        let mind = Mind.shared
        var status = AIProviderStatus(id: "apple", name: "Apple Intelligence, on this Mac", usedFor: "Flow: chat, summaries, plans, meeting notes",
                                      state: .ready)
        if !mind.isAvailable {
            status = AIProviderStatus(id: "apple", name: status.name, usedFor: status.usedFor, state: .unavailable(mind.unavailableReason))
            status.setup = .init(title: "Apple Intelligence Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") { NSWorkspace.shared.open(url) }
            }
        }
        return status
    }

    static var claude: AIProviderStatus {
        let state: AIProviderStatus.State
        if ClaudeAsk.binary == nil {
            state = .unavailable("Install the Claude app to ask Claude from search.")
        } else if let signedIn = ClaudeAsk.shared.signedIn {
            state = signedIn ? .ready : .signedOut
        } else {
            state = .checking
        }
        var status = AIProviderStatus(id: "claude", name: "Claude, through your Claude app", usedFor: "Ask Claude in search (answers only, no tools)", state: state)
        if state == .signedOut { status.setup = .init(title: "Sign In…") { ClaudeAsk.shared.signIn() } }
        return status
    }
}
