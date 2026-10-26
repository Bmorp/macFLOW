import SwiftUI

/// Flow's inbox: what Flow suggested or asked waits here until you answer it, dismiss it, or it stops mattering —
/// a question for a day, a suggestion for as long as it's relevant. Each one pops once in the island; miss it and
/// it's at the top of Home the next time you open it, with Flow's star on the closed island until then.
@MainActor
final class FlowInbox: ObservableObject {
    static let shared = FlowInbox()

    struct Item: Identifiable, Equatable {
        enum Body: Equatable { case suggestion(BrainSuggestion), question(BrainQuestion) }
        let body: Body
        let added: Date
        let expires: Date

        var id: UUID {
            switch body {
            case .suggestion(let s): s.id
            case .question(let q): q.id
            }
        }

        /// Two items with one key are the same thing: a newer suggestion replaces the older.
        var key: String {
            switch body {
            case .suggestion(let s): "s:" + s.kind
            case .question(let q): "q:" + q.key
            }
        }

        var alert: IslandAlert {
            switch body {
            case .suggestion(let s): .brainSuggestion(s)
            case .question(let q): .brainQuestion(q)
            }
        }

        var isQuestion: Bool { if case .question = body { true } else { false } }
    }

    @Published private(set) var items: [Item] = []
    private var sweeper: Timer?

    /// The one on show: the newest.
    var top: Item? { items.last }

    /// Adds a suggestion and pops it in the island (unless `pop` is false: it just waits on Home).
    /// A waiting suggestion of the same kind is replaced.
    @discardableResult
    func suggest(_ s: BrainSuggestion, lasts: TimeInterval = 30 * 60, pop: Bool = true) -> Bool {
        add(Item(body: .suggestion(s), added: Date(), expires: Date().addingTimeInterval(lasts)), replacing: true, pop: pop)
    }

    /// Adds a question and pops it in the island. False if the same question is already waiting.
    @discardableResult
    func ask(_ q: BrainQuestion, lasts: TimeInterval = 24 * 3600) -> Bool {
        add(Item(body: .question(q), added: Date(), expires: Date().addingTimeInterval(lasts)), replacing: false, pop: true)
    }

    private func add(_ item: Item, replacing: Bool, pop: Bool) -> Bool {
        if items.contains(where: { $0.key == item.key }) {
            guard replacing else { return false }
            items.removeAll { $0.key == item.key }   // superseded, not ignored
        }
        withAnimation(Motion.morph) {
            items.append(item)
            if items.count > 6 { items.removeFirst(items.count - 6) }
        }
        startSweeping()
        // Never over a call or StandBy: it waits on Home instead.
        if pop, IslandManager.shared.primary != nil, ActivityCenter.shared.call == nil, !StandByController.shared.isShowing {
            IslandManager.shared.showBrain(item.alert)
        }
        return true
    }

    func contains(_ id: UUID) -> Bool { items.contains { $0.id == id } }

    /// Answered, accepted or dismissed: gone.
    func resolve(_ id: UUID) {
        guard contains(id) else { return }
        withAnimation(Motion.morph) { items.removeAll { $0.id == id } }
    }

    // MARK: Actions (shared by the alert and the Home card)

    func accept(_ s: BrainSuggestion) {
        resolve(s.id)
        BrainEngine.shared.accept(s)
    }

    func dismiss(_ s: BrainSuggestion) {
        resolve(s.id)
        BrainEngine.shared.dismiss(s)
    }

    func answer(_ q: BrainQuestion, _ option: BrainQuestion.Option) {
        resolve(q.id)
        BrainEngine.shared.answer(q, option)
    }

    /// Not this one: don't ask again for a few days.
    func skip(_ q: BrainQuestion) {
        resolve(q.id)
        BrainEngine.shared.skip(q)
    }

    // MARK: Expiry

    private func startSweeping() {
        guard sweeper == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { FlowInbox.shared.sweep() } }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        sweeper = t
    }

    private func sweep() {
        let now = Date()
        let expired = items.filter { $0.expires <= now }
        for item in expired {
            // A suggestion that ran out unanswered counts as ignored — once, here, not when the alert closed.
            if case .suggestion(let s) = item.body { BrainEngine.shared.ignored(s) }
        }
        if !expired.isEmpty { withAnimation(Motion.morph) { items.removeAll { $0.expires <= now } } }
        if items.isEmpty {
            sweeper?.invalidate()
            sweeper = nil
        }
    }

    #if DEBUG
    func debugSet(_ list: [Item]) { items = list }
    #endif
}

// MARK: - Home card

/// A waiting suggestion or question at the top of Home: Flow's seal, what it wants, and the answers.
/// It settles in a beat after the island opens, so the eye goes to it.
struct FlowInboxCard: View {
    let item: FlowInbox.Item
    var count = 1
    /// After an action that takes you somewhere else (opening Flow, starting a timer), the island closes.
    var onLeave: () -> Void = {}
    @Environment(\.islandShowing) private var showing
    @State private var arrived = RenderMode.snapshot

    static let suggestionHeight: CGFloat = 58
    static let questionHeight: CGFloat = 94
    /// Space below the card, before the player.
    static let gap: CGFloat = 8

    @MainActor static func height(_ item: FlowInbox.Item?) -> CGFloat {
        guard let item else { return 0 }
        return (item.isQuestion ? questionHeight : suggestionHeight) + gap
    }

    var body: some View {
        Group {
            switch item.body {
            case .suggestion(let s): suggestion(s)
            case .question(let q): question(q)
            }
        }
        .frame(height: item.isQuestion ? Self.questionHeight : Self.suggestionHeight)
        .background(FlowCardBackground())
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived ? 0 : -10)
        .scaleEffect(arrived ? 1 : 0.97, anchor: .top)
        .onChange(of: showing, initial: true) { _, on in settle(on) }
        .onChange(of: item.id) { _, _ in
            guard showing, !Access.reduceMotion else { return }
            arrived = false
            settle(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.isQuestion ? "Flow is asking" : "Flow suggests")
    }

    private func settle(_ on: Bool) {
        guard !RenderMode.snapshot else { return }
        if on {
            withAnimation(Access.reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.78).delay(0.12)) { arrived = true }
        } else {
            arrived = false
        }
    }

    private func suggestion(_ s: BrainSuggestion) -> some View {
        HStack(spacing: 12) {
            FlowSeal()
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Ink.primary).lineLimit(1)
                meta(s.detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            more
            Ghost(symbol: "xmark", label: "Dismiss", size: 10, tint: DS.Ink.tertiary, hit: 26) {
                FlowInbox.shared.dismiss(s)
            }
            Pill(title: s.actionTitle) {
                FlowInbox.shared.accept(s)
                // Flow's own places (the conversation, the planner) open in the island; anything else leaves it.
                if s.action != .none, !Self.staysInIsland(s.action) { onLeave() }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
    }

    private func question(_ q: BrainQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                FlowSeal()
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    meta(q.detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                more
                Ghost(symbol: "xmark", label: "Don’t Ask Again", size: 10, tint: DS.Ink.tertiary, hit: 26) {
                    FlowInbox.shared.skip(q)
                }
            }
            HStack(spacing: 6) {
                ForEach(q.options, id: \.self) { option in
                    FlowOptionButton(title: option.label) {
                        FlowInbox.shared.answer(q, option)
                        if q.key.hasPrefix("plan.checkin"), option.value == "replan" { onLeave() }
                    }
                }
            }
            .padding(.leading, 44)
        }
        .padding(.horizontal, 12)
    }

    /// The why, and how long it's been waiting — so a missed one reads as missed, not new.
    private func meta(_ detail: String) -> some View {
        let waited = Date().timeIntervalSince(item.added)
        let age = waited < 90 ? "" : " · " + (waited < 3600 ? "\(Int(waited / 60)) min ago" : item.added.formatted(date: .omitted, time: .shortened))
        return Text(detail + age).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Ink.secondary).lineLimit(1)
    }

    @ViewBuilder private var more: some View {
        if count > 1 {
            Text("+\(count - 1)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(BrainStyle.tint)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(BrainStyle.tint.opacity(0.16)))
                .accessibilityLabel("\(count - 1) more waiting")
        }
    }

    /// Actions that open another of the island's places rather than leaving it.
    static func staysInIsland(_ a: BrainAction) -> Bool {
        switch a {
        case .ask, .openPlan, .openRewind, .openDay: true
        default: false
        }
    }
}

/// Flow's seal: the star on a soft violet disc.
struct FlowSeal: View {
    var size: CGFloat = 32

    var body: some View {
        FlowGlyph(size: size * 0.38, color: .white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(LinearGradient(colors: [BrainStyle.tint, Color(red: 0.42, green: 0.36, blue: 0.95)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .shadow(color: BrainStyle.tint.opacity(0.45), radius: 6, y: 1)
            .accessibilityHidden(true)
    }
}

/// The card's surface: a violet wash fading right, a hairline edge.
struct FlowCardBackground: View {
    var corner: CGFloat = 16
    /// Flow's violet by default; each of Now's moments lights its card in its own colour.
    var tint: Color = BrainStyle.tint

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        shape.fill(LinearGradient(colors: [tint.opacity(0.2), tint.opacity(0.06)], startPoint: .leading, endPoint: .trailing))
            .overlay(shape.strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
    }
}

/// One answer: a capsule that lights white under the pointer.
struct FlowOptionButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover || prominent ? Color.black : DS.Ink.primary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(hover || prominent ? Color.white : DS.Ink.well))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}
