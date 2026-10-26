import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Learning: anything worth keeping — a page you read, a passage you copied — becomes a few short question-and-answer
/// cards (written on this Mac from what you saved, never from thin air), and Flow brings them back at quiet moments,
/// spaced so they stick: again in ten minutes, then a day, then longer each time you know it.
struct StudyCard: Codable, Identifiable, Equatable {
    var id = UUID()
    var question: String
    var answer: String
    var source: String
    var url: URL?
    var created = Date()
    var due = Date()
    /// Days until the next review once remembered.
    var interval: Double = 0
    var ease: Double = 2.3
    var reps = 0

    enum Grade { case again, good, easy }

    /// Spaced repetition (SM-2, simplified): forget it and it comes back in ten minutes; know it and the gap grows.
    mutating func review(_ grade: Grade, now: Date = Date()) {
        switch grade {
        case .again:
            reps = 0
            interval = 0
            ease = max(1.3, ease - 0.2)
            due = now.addingTimeInterval(10 * 60)
        case .good, .easy:
            reps += 1
            interval = reps == 1 ? 1 : reps == 2 ? 3 : (interval * ease).rounded()
            if grade == .easy {
                interval = (interval * 1.4).rounded()
                ease += 0.15
            }
            due = now.addingTimeInterval(interval * 86_400)
        }
    }
}

@MainActor
final class LearnStore: ObservableObject {
    static let shared = LearnStore()
    @Published private(set) var cards: [StudyCard]
    @Published private(set) var making = false
    private static let file = "cards.json"
    private var lastQuiz = Date.distantPast
    private var quizzesToday = (day: "", count: 0)

    init() { cards = Storage.load([StudyCard].self, from: Self.file) ?? [] }

    var due: [StudyCard] { cards.filter { $0.due <= Date() }.sorted { $0.due < $1.due } }
    var sources: [String] { Array(NSOrderedSet(array: cards.sorted { $0.created > $1.created }.map(\.source)).array as? [String] ?? []) }

    /// Turns something you saved into cards: the on-device model writes them from the text; without it, the text's
    /// clearest sentences become cards to recall.
    func make(from text: String, title: String, url: URL?) {
        making = true
        IslandManager.shared.confirm("rectangle.stack.badge.plus", "Making cards from “\(title.prefix(40))”…", tint: BrainStyle.tint)
        Task { @MainActor in
            var made = await Self.write(text, title: title)
            if made.isEmpty { made = Self.fallback(text, title: title) }
            let new = made.map { StudyCard(question: $0.0, answer: $0.1, source: title, url: url) }
            cards.append(contentsOf: new)
            save()
            making = false
            Memory.shared.remember([(id: "learn.\(UUID(stable: title + (url?.absoluteString ?? "")).uuidString)", date: Date(), kind: "learn",
                                     text: "Saved to learn: “\(title)” — " + new.map(\.question).joined(separator: " "))])
            IslandManager.shared.confirm(new.isEmpty ? "exclamationmark.triangle" : "rectangle.stack.fill",
                                         new.isEmpty ? "Nothing to make cards from" : "\(new.count) cards — Flow will quiz you",
                                         tint: new.isEmpty ? DS.Palette.orange : BrainStyle.tint)
        }
    }

    func grade(_ card: StudyCard, _ g: StudyCard.Grade) {
        guard let i = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[i].review(g)
        save()
    }

    func remove(_ card: StudyCard) {
        cards.removeAll { $0.id == card.id }
        save()
    }

    private func save() { Storage.save(cards, to: Self.file) }

    /// A quiet moment (back from a break, a block just ended): one due card, if it's been a while — at most six a day.
    func quizIfQuiet() {
        let today = DayPlan.key()
        if quizzesToday.day != today { quizzesToday = (today, 0) }
        guard Prefs.shared.learnQuizzes, let card = due.first, quizzesToday.count < 6, Date().timeIntervalSince(lastQuiz) > 45 * 60,
              ActivityCenter.shared.call == nil, FocusTimer.shared.phase == .idle,
              let model = IslandManager.shared.primary?.model, model.mode == .compact else { return }
        lastQuiz = Date()
        quizzesToday.count += 1
        model.showAlert(.learn(card), duration: 25)
    }

    // MARK: Writing cards

    private static func write(_ text: String, title: String) async -> [(String, String)] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), Mind.shared.isAvailable {
            // The on-device context is small (and the cards' schema takes some of it): shrink the text until it fits.
            var budget = 4500
            while budget >= 1100 {
                let session = LanguageModelSession(instructions: """
                You write study flashcards from a text the user saved. Only use facts stated in the text. Questions are short and \
                specific; answers are one or two sentences. No trivia about the website itself.
                """)
                let prompt = "Title: \(title)\n\nText:\n\(Mind.excerpt(text, budget))"
                do {
                    let r = try await session.respond(to: prompt, generating: StudySet.self).content
                    return r.cards.prefix(4).map { ($0.question.trimmingCharacters(in: .whitespacesAndNewlines), $0.answer.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .filter { !$0.0.isEmpty && !$0.1.isEmpty }
                } catch let error as LanguageModelSession.GenerationError {
                    guard case .exceededContextWindowSize = error else { return [] }
                    budget /= 2
                } catch {
                    return []
                }
            }
        }
        #endif
        return []
    }

    /// Without the model: the clearest sentences, to recall from the title.
    nonisolated static func fallback(_ text: String, title: String) -> [(String, String)] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 40 && $0.count <= 260 && $0.split(separator: " ").count >= 7 }
        return sentences.prefix(3).enumerated().map { i, s in
            ("“\(title.prefix(50))” — what’s point \(i + 1)?", s + ".")
        }
    }

    #if DEBUG
    func debugSet(_ list: [StudyCard]) { cards = list }
    static func debugWrite(_ text: String, title: String) async -> [(String, String)] { await write(text, title: title) }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct StudySet {
    @Guide(description: "Two to four flashcards from the text")
    var cards: [StudyItem]
}

@available(macOS 26.0, *)
@Generable
struct StudyItem {
    @Guide(description: "A short, specific question answered by the text")
    var question: String
    @Guide(description: "The answer, from the text, in one or two sentences")
    var answer: String
}
#endif

// MARK: - A card in the notch

/// A card to recall: the question first; "Show Answer" turns it over; then how well you knew it.
struct StudyCardView: View {
    var model: IslandModel
    let card: StudyCard
    var inSheet = false
    var onDone: () -> Void = {}
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(BrainStyle.tint)
                Text("RECALL · \(card.source.uppercased())").font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking)
                    .foregroundStyle(BrainStyle.tint).lineLimit(1)
                Spacer(minLength: 4)
                if !inSheet {
                    Ghost(symbol: "xmark", label: "Later", size: 10, tint: DS.Ink.tertiary, hit: 24) { model.dismissAlert() }
                }
            }
            Text(card.question).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if shown {
                Text(card.answer).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                HStack(spacing: 6) {
                    FlowOptionButton(title: "Again") { finish(.again) }
                    FlowOptionButton(title: "Got It", prominent: true) { finish(.good) }
                    FlowOptionButton(title: "Easy") { finish(.easy) }
                }
            } else {
                FlowOptionButton(title: "Show Answer", prominent: true) {
                    withAnimation(Motion.morph) { shown = true }
                    if !inSheet { model.holdAlert() }
                }
            }
        }
        .padding(.horizontal, inSheet ? 0 : IslandModel.expandedFlare + DS.Island.rowLeading + 2)
        .padding(.top, inSheet ? 0 : model.notch.height + 6)
        .padding(.bottom, inSheet ? 0 : 14)
        .frame(width: inSheet ? nil : model.alertSize.width, alignment: .topLeading)
        .onChange(of: card.id) { _, _ in shown = false }
    }

    private func finish(_ g: StudyCard.Grade) {
        LearnStore.shared.grade(card, g)
        Haptics.confirm()
        if inSheet { onDone() } else { model.dismissAlert() }
    }
}
