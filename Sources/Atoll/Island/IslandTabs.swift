import SwiftUI

/// The island's places — Home and each live activity — beside the notch, one click apart.
/// A trackpad swipe sideways walks the same order.
struct IslandTabs: View {
    var model: IslandModel
    let current: IslandFocus

    var body: some View {
        let tabs = Array(model.tabs.prefix(5))
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { focus in
                Tab(focus: focus, selected: focus == current) { model.select(focus) }
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.Ink.well))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Places")
    }

    private struct Tab: View {
        let focus: IslandFocus
        let selected: Bool
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                glyph
                    .frame(width: 30, height: 22)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.17) : hover ? DS.Ink.well : .clear))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .help(name)
            .accessibilityLabel(name)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        }

        private var tint: Color {
            guard selected else { return hover ? DS.Ink.secondary : DS.Ink.tertiary }
            if case .activity(let k) = focus { return k.tint }
            return DS.Ink.primary
        }

        @ViewBuilder private var glyph: some View {
            switch focus {
            case .glance:
                Image(systemName: "house.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            case .controls:
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            case .brain:
                FlowGlyph(size: 10, color: selected ? BrainStyle.tint : tint)
            case .plan:
                Image(systemName: "sun.horizon.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? PlanView.morning : tint)
            case .rewind:
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            case .day:
                Image(systemName: "circle.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            case .sheet:
                Image(systemName: "rectangle.portrait.bottomhalf.inset.filled").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            case .activity(.claude):
                ClaudeGlyph(size: 12, spinning: false, tint: tint)
            case .activity(let k):
                Image(systemName: k.tabSymbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            }
        }

        private var name: String {
            switch focus {
            case .glance: "Home"
            case .controls: "Controls"
            case .brain: "Flow"
            case .plan: "Plan"
            case .rewind: "Rewind"
            case .day: "Your Day"
            case .sheet: "Today"
            case .activity(let k):
                switch k {
                case .call: "Call"
                case .claude: "Claude"
                case .timer: "Timer"
                case .custom: CustomActivity.shared.current?.title ?? "Activity"
                case .meeting: "Meeting"
                case .download: "Download"
                case .nowPlaying: "Music"
                case .shelf: "Shelf"
                case .awake: "Keep Awake"
                case .flow: "Flow"
                }
            }
        }
    }
}
