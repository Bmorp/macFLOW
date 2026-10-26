import SwiftUI

/// Talking to Atoll: a conversation in the island, on this Mac. Ask about your day, or tell it what to do —
/// what it does appears in the conversation as it happens.
struct BrainPlace: View {
    var model: IslandModel
    @ObservedObject private var agent = BrainAgent.shared
    @ObservedObject private var voice = VoiceInput.shared
    @FocusState private var focused: Bool
    @Environment(\.islandShowing) private var showing

    static let height: CGFloat = 250
    private var inset: CGFloat { IslandModel.expandedFlare + DS.Island.rowLeading }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notch.height)
            Group {
                if agent.messages.isEmpty { welcome } else { conversation }
            }
            .frame(maxHeight: .infinity)
            Group {
                if voice.isActive { listening } else { input }
            }
            .padding(.horizontal, inset)
            .padding(.bottom, 14)
        }
        .frame(width: model.expandedSize(.brain).width, height: model.expandedSize(.brain).height, alignment: .top)
        .background(alignment: .top) { ContentLight(color: BrainStyle.tint, origin: UnitPoint(x: 0.2, y: 1.1), strength: 0.6) }
        .overlay(alignment: .topTrailing) {
            if !agent.messages.isEmpty {
                GlyphButton(symbol: "square.and.pencil", label: "New Conversation", size: 12, tint: DS.Ink.secondary, hit: 26) { agent.reset() }
                    .frame(height: model.notch.height)
                    .padding(.trailing, inset)
            }
        }
        .onAppear { if showing && model.mode == .expanded(.brain) { takeKeyboard() } }
        .onChange(of: showing) { _, on in
            if on {
                takeKeyboard()
            } else {
                // Letting go of the keyboard also wakes the input system: after the switch has moved, not during it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { if !showing { focused = false } }
            }
        }
        .onChange(of: focused) { _, on in model.setSticky(on || agent.thinking) }
    }

    /// The keyboard comes to the conversation once the opening spring has settled (focus wakes the input system).
    private func takeKeyboard() {
        // Becoming the key window re-renders the island for the active appearance — do it after the spring, not in it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard model.mode == .expanded(.brain) else { return }
            model.panel?.makeKey()
            focused = true
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: greeting, dot: BrainStyle.tint)
                Text("What can I do for you?")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DS.Ink.primary)
            }
            HStack(spacing: 8) {
                ForEach(BrainAgent.starters, id: \.self) { s in
                    Button { agent.send(s) } label: {
                        Text(s)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.Ink.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Capsule().fill(DS.Ink.well))
                            .overlay(Capsule().strokeBorder(BrainStyle.tint.opacity(0.35), lineWidth: 0.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle(scale: 0.95))
                }
            }
            Text(agent.available
                 ? "On this Mac. Type, or press and hold the notch and talk. I can set up the room for your work, pick a project up where you left it, move meetings, take notes, rewind your day, play music and more."
                 : Mind.shared.unavailableReason)
                .font(.system(size: 11))
                .foregroundStyle(DS.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.top, 6)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Late night" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(agent.messages) { m in
                        row(m).id(m.id)
                    }
                }
                .padding(.horizontal, inset)
                .padding(.vertical, 8)
            }
            .onChange(of: agent.messages.last?.text) { _, _ in
                if let id = agent.messages.last?.id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onAppear { if let id = agent.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            .onChange(of: agent.messages.count) { _, _ in
                if let id = agent.messages.last?.id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private func row(_ m: BrainAgent.Message) -> some View {
        switch m.role {
        case .you:
            HStack {
                Spacer(minLength: 80)
                Text(m.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Ink.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.1)))
                    .textSelection(.enabled)
            }
        case .action:
            HStack(spacing: 6) {
                Image(systemName: m.symbol ?? "checkmark").font(.system(size: 10, weight: .bold))
                Text(m.text).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(BrainStyle.tint)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(BrainStyle.tint.opacity(0.14)))
            .transition(.scale(scale: 0.9, anchor: .leading))
        case .atoll:
            HStack(alignment: .top, spacing: 8) {
                FlowGlyph(size: 11)
                    .padding(.top, 3)
                if m.text.isEmpty && agent.thinking {
                    ThinkingDots(size: 18)
                } else {
                    Text(m.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(DS.Ink.primary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 40)
            }
        }
    }

    // MARK: Listening (press and hold the notch)

    private var listening: some View {
        HStack(spacing: 10) {
            FlowGlyph(size: 13)
                .scaleEffect(1 + CGFloat(voice.level) * 0.35)
                .animation(.easeOut(duration: 0.08), value: voice.level)
            Text(voice.transcript.isEmpty ? (voice.state == .finishing ? "…" : "Listening — let go when you’re done") : voice.transcript)
                .font(.system(size: 14, weight: voice.transcript.isEmpty ? .regular : .medium))
                .foregroundStyle(voice.transcript.isEmpty ? DS.Ink.tertiary : DS.Ink.primary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            VoiceLevels(level: voice.level, tint: BrainStyle.tint)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(BrainStyle.tint.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(BrainStyle.tint.opacity(0.45), lineWidth: 0.5))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voice.transcript.isEmpty ? "Listening" : "Heard: \(voice.transcript)")
    }

    // MARK: Input

    @ViewBuilder private var voiceFailure: some View {
        if case .failed(let message) = voice.state {
            HStack(spacing: 8) {
                Image(systemName: "mic.slash.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Palette.orange)
                Text(message).font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.Ink.secondary).lineLimit(2)
                Spacer(minLength: 4)
                Ghost(symbol: "xmark", label: "Dismiss", size: 9, tint: DS.Ink.tertiary, hit: 22) { voice.clearFailure() }
            }
            .padding(.bottom, 6)
        }
    }

    private var input: some View {
        VStack(spacing: 0) {
            voiceFailure
            inputField
        }
    }

    private var inputField: some View {
        HStack(spacing: 10) {
            FlowGlyph(size: 13)
            TextField("", text: $agent.draft, prompt: Text("Ask Flow, or tell it what to do").foregroundColor(DS.Ink.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(DS.Ink.primary)
                .focused($focused)
                .onSubmit { agent.send() }
                .disabled(!agent.available)
            if agent.thinking {
                ThinkingDots(size: 16)
            } else if !agent.draft.isEmpty {
                Button { agent.send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 24, height: 24).background(Circle().fill(Color.white))
                }
                .buttonStyle(PressStyle())
                .help("Send")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(focused ? 0.18 : 0.06), lineWidth: 0.5))
    }
}

/// Five bars that follow the voice.
struct VoiceLevels: View {
    var level: Float
    var tint: Color

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                let shape: [CGFloat] = [0.45, 0.8, 1, 0.75, 0.5]
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 4 + 16 * CGFloat(level) * shape[i])
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
