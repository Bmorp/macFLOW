import SwiftUI

/// The Brain's colour: a calm violet, distinct from Claude's orange and the activity tints.
enum BrainStyle {
    static let tint = Color(red: 0.62, green: 0.52, blue: 1.0)
    static let dots = Color(red: 0.85, green: 0.47, blue: 0.34)
}

// ThinkingDots lives in LayerMotion.swift (a Core Animation loop).

/// The Brain's visual on a row: an orb tile.
struct BrainTile: View {
    let symbol: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(LinearGradient(colors: [BrainStyle.tint, Color(red: 0.42, green: 0.36, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .accessibilityHidden(true)
    }
}

/// A suggestion: what, then why, then one action.
struct BrainSuggestionCard: View {
    var model: IslandModel
    let suggestion: BrainSuggestion

    var body: some View {
        Instrument(notch: model.notch, width: model.expandedWidth) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        LiveDot(color: BrainStyle.tint)
                        Text(suggestion.title).font(DS.Kit.title).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    }
                    Text(suggestion.detail).font(DS.Kit.meta).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                        .padding(.leading, 13)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .islandReveal(0)
                Ghost(symbol: "xmark", label: "Not Now", size: 11, tint: DS.Ink.tertiary, hit: 28) {
                    model.dismissAlert()
                    FlowInbox.shared.dismiss(suggestion)
                }
                Pill(title: suggestion.actionTitle) {
                    model.dismissAlert()
                    FlowInbox.shared.accept(suggestion)
                }
                .islandReveal(2)
            }
        }
    }
}

/// A question: what the Brain wants to know, and the answers to tap.
struct BrainQuestionCard: View {
    var model: IslandModel
    let question: BrainQuestion
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: model.notch.height)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Flow is learning", dot: BrainStyle.tint)
                    Text(question.text).font(DS.Kit.titleLarge).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    if !question.detail.isEmpty {
                        Text(question.detail).font(DS.Kit.meta).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Later, not never: it waits on Home.
                Ghost(symbol: "chevron.up", label: "Answer Later", size: 11, tint: DS.Ink.tertiary, hit: 28) {
                    model.dismissAlert()
                }
            }
            HStack(spacing: 8) {
                ForEach(question.options, id: \.self) { option in
                    Button {
                        model.dismissAlert()
                        FlowInbox.shared.answer(question, option)
                    } label: {
                        Text(option.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(hovered == option.label ? Color.black : DS.Ink.primary)
                            .padding(.horizontal, 15)
                            .frame(height: 30)
                            .background(Capsule().fill(hovered == option.label ? Color.white : DS.Ink.well))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle(scale: 0.95))
                    .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h ? option.label : nil } }
                }
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, IslandModel.expandedFlare + DS.Island.rowLeading + 2)
        .padding(.bottom, 16)
        .frame(width: model.expandedWidth, alignment: .top)
    }
}

/// Asking the Brain about your own day, on this Mac.
@MainActor
final class BrainChat: ObservableObject {
    static let shared = BrainChat()

    enum Phase: Equatable { case idle, thinking, answering, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var question = ""
    @Published private(set) var answer = ""
    private var task: Task<Void, Never>?

    func ask(_ q: String) {
        task?.cancel()
        question = q
        answer = ""
        phase = .thinking
        let context = BrainEngine.shared.digest()
        task = Task { @MainActor in
            do {
                for try await text in Mind.shared.answer(q, context: context) {
                    if Task.isCancelled { return }
                    answer = text
                    if phase != .answering { phase = .answering }
                }
                phase = answer.isEmpty ? .failed("I couldn’t come up with an answer.") : .done
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    #if DEBUG
    func debugSet(question q: String, answer a: String, phase p: Phase) { question = q; answer = a; phase = p }
    #endif
}

/// The Brain's answer in the search panel.
struct BrainAnswerPanel: View {
    @ObservedObject private var chat = BrainChat.shared
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BrainTile(symbol: "sparkles", size: 20)
                Text(chat.question)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Palette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                GlyphButton(symbol: "chevron.left", label: "Back to Results", size: 11, tint: DS.Palette.secondary, hit: 24, action: onBack)
            }
            Group {
                switch chat.phase {
                case .thinking, .idle:
                    HStack(spacing: 10) {
                        ThinkingDots(size: 26)
                        Text("Thinking about your day…").font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Palette.secondary)
                    }
                case .answering, .done:
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(LocalizedStringKey(chat.answer))
                            .font(.system(size: 14))
                            .foregroundStyle(DS.Palette.label)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .failed(let message):
                    Text(message).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Palette.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 8) {
                if chat.phase == .done {
                    SecondaryButton(title: "Copy", symbol: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(chat.answer, forType: .string)
                        Haptics.confirm()
                    }
                }
                Spacer(minLength: 0)
                Text("On this Mac").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Palette.tertiary)
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 4)
    }
}
