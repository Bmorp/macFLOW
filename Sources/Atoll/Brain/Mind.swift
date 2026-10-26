import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The Brain's on-device language model (Apple's, macOS 26 and later). Everything stays on this Mac.
/// Used where judgement and language matter: chatting with you about your own day, summarising, and
/// classifying things the rules don't know.
@MainActor
final class Mind {
    static let shared = Mind()

    static let instructions = """
    You are Flow, the calm, highly capable personal assistant in Mac Flow, living in the notch of the user's Mac.
    You know only what's in the context you're given: what they've been doing, their schedule, music and preferences.
    Be specific, warm and brief — usually one to three short sentences. Never invent activities or facts not in the context.
    If you don't know, say so plainly and suggest what Atoll could learn.
    """

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return ""
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This Mac doesn’t support Apple’s on-device model."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings to let Flow think."
                case .modelNotReady: return "Apple’s on-device model is still downloading."
                @unknown default: return "Apple’s on-device model isn’t available right now."
                }
            }
        }
        #endif
        return "Flow’s thinking needs macOS 26 or later."
    }

    /// Streams an answer, as cumulative text.
    func answer(_ question: String, context: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), isAvailable {
                let task = Task { @MainActor in
                    do {
                        let session = LanguageModelSession(instructions: Self.instructions)
                        let prompt = "Context about the user:\n\(context)\n\nThe user asks: \(question)"
                        for try await partial in session.streamResponse(to: prompt) {
                            continuation.yield(partial.content)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            #endif
            continuation.finish(throwing: MindError.unavailable(unavailableReason))
        }
    }

    /// Something done with a page's words (summarize, explain), streamed. Its own small session — no tools, no day
    /// digest — and the text shrinks until it fits the on-device model's context window.
    func onPage(_ instruction: String, title: String, text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), isAvailable {
                let task = Task { @MainActor in
                    var budget = 6000
                    while true {
                        do {
                            let session = LanguageModelSession(instructions: """
                            You read web pages for the user and say what they contain. Be faithful to the text: never add facts it                             doesn't state. Plain language, no preamble.
                            """)
                            let excerpt = Self.excerpt(text, budget)
                            for try await partial in session.streamResponse(to: "Page: \(title)\n\n\(excerpt)\n\n\(instruction)") {
                                continuation.yield(partial.content)
                            }
                            continuation.finish()
                            return
                        } catch let error as LanguageModelSession.GenerationError {
                            if case .exceededContextWindowSize = error, budget > 1200 {
                                budget /= 2
                                continue
                            }
                            continuation.finish(throwing: error)
                            return
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            #endif
            continuation.finish(throwing: MindError.unavailable(unavailableReason))
        }
    }

    /// The start of a long text and a little of its end, within `budget` characters.
    nonisolated static func excerpt(_ text: String, _ budget: Int) -> String {
        guard text.count > budget else { return text }
        let head = Int(Double(budget) * 0.8)
        return String(text.prefix(head)) + "\n…\n" + String(text.suffix(budget - head))
    }

    enum MindError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case .unavailable(let reason) = self { return reason }; return nil }
    }

    /// One short line, or nil — for summaries and phrasing.
    func complete(_ prompt: String, context: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            let session = LanguageModelSession(instructions: Self.instructions)
            let text = try? await session.respond(to: "Context about the user:\n\(context)\n\n\(prompt)").content
            return text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        return nil
    }

    /// Which mode an unfamiliar app (or page) belongs to.
    func classify(app: String, title: String) async -> WorkMode? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            let session = LanguageModelSession(instructions: "Classify what a Mac user is doing in an app. Answer with exactly one word from the list.")
            let options = WorkMode.allCases.filter { $0 != .idle }.map(\.rawValue).joined(separator: ", ")
            let prompt = "App: \(app). Window: \(title.isEmpty ? "unknown" : title). Choose one of: \(options)."
            guard let raw = try? await session.respond(to: prompt).content.lowercased() else { return nil }
            return WorkMode.allCases.first { raw.contains($0.rawValue) }
        }
        #endif
        return nil
    }

    /// A meeting, written up: what was discussed and decided, and who agreed to do what. Faithful to the transcript.
    func meetingNotes(_ transcript: String, title: String) async -> (summary: String, actions: [String])? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            // The on-device context is small: keep the opening and most of the end, where decisions usually land.
            let text = transcript.count > 9000 ? String(transcript.prefix(1500)) + "\n…\n" + String(transcript.suffix(7000)) : transcript
            let session = LanguageModelSession(instructions: """
            You write meeting notes from a transcript. "You" is the user; "Them" is everyone else on the call.
            Be faithful: include only what was actually said. Never invent names, dates or tasks.
            """)
            let prompt = "Meeting: \(title)\n\nTranscript:\n\(text)"
            guard let notes = try? await session.respond(to: prompt, generating: MeetingNotes.self).content else { return nil }
            let actions = notes.actionItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return (notes.summary.trimmingCharacters(in: .whitespacesAndNewlines), Array(actions.prefix(6)))
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct MeetingNotes {
    @Guide(description: "Two sentences: what was discussed, and what was decided")
    var summary: String
    @Guide(description: "Things someone agreed or was asked to do, one short imperative line each, naming who if it was said. Empty if none.")
    var actionItems: [String]
}
#endif
