import SwiftUI

/// Home's quick row: your apps, then Mac Flow's own features, on one strip you move sideways with two fingers.
/// It snaps to whole items, and each item that passes the strip's leading edge ticks under your fingers (thinned when
/// you flick); the seam between apps and features is a firmer landmark. Items shrink and dim as they leave the strip,
/// so it reads as a carousel with depth rather than a list. Right-click a feature for its options.
struct HomeCarousel: View {
    var model: IslandModel
    @ObservedObject private var catalog = AppCatalog.shared
    @State private var position: String?

    static let icon: CGFloat = 40
    static let spacing: CGFloat = 16

    enum Item: Identifiable, Equatable {
        case app(AppEntry)
        case seam(Int)
        case feature(HomeFeature)

        var id: String {
            switch self {
            case .app(let e): "app:" + e.id
            case .seam(let n): "seam\(n)"
            case .feature(let f): "feature:" + f.rawValue
            }
        }

        var isSeam: Bool { if case .seam = self { return true }; return false }
    }

    /// The apps you reach for most, then Mac Flow's features, then the rest of your apps: both kinds show at a
    /// glance, and the strip keeps going when you scroll.
    private var items: [Item] {
        var apps = catalog.recentEntries
        for p in catalog.pinnedEntries where !apps.contains(p) { apps.append(p) }
        let first = apps.prefix(6).map(Item.app), rest = apps.dropFirst(6).prefix(10).map(Item.app)
        return first + [.seam(0)] + HomeFeature.available.map(Item.feature) + (rest.isEmpty ? [] : [.seam(1)] + rest)
    }

    var body: some View {
        let items = items
        if RenderMode.snapshot {
            // A row wider than its frame is centred; a leading ZStack starts it at the first item, as the strip does.
            ZStack(alignment: .leading) {
                Color.clear
                HStack(spacing: Self.spacing) { ForEach(items) { cell($0) } }
                    .padding(.horizontal, 6).padding(.vertical, 8)
                    .fixedSize()
            }
            .clipped()
        } else {
            strip(items)
        }
    }

    private func strip(_ items: [Item]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.spacing) {
                ForEach(items) { item in
                    cell(item)
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(1 - abs(phase.value) * 0.22)
                                .opacity(1 - abs(phase.value) * 0.5)
                        }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $position, anchor: .leading)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.035),
                                     .init(color: .black, location: 0.965), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .claimsHorizontalScroll("home.carousel")
        .onChange(of: position) { old, new in tick(items, from: old, to: new) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Apps and features")
    }

    @ViewBuilder private func cell(_ item: Item) -> some View {
        switch item {
        case .app(let entry): CarouselApp(entry: entry, model: model)
        case .seam:
            Capsule().fill(Color.white.opacity(0.14)).frame(width: 1.5, height: Self.icon * 0.6)
                .accessibilityHidden(true)
        case .feature(let f): CarouselFeature(feature: f, model: model)
        }
    }

    /// One tick per item that passes the leading edge; crossing into or out of the features is a landmark.
    private func tick(_ items: [Item], from old: String?, to new: String?) {
        guard let old, let new,
              let a = items.firstIndex(where: { $0.id == old }), let b = items.firstIndex(where: { $0.id == new }), a != b
        else { return }
        let crossedSeam = items[min(a, b)...max(a, b)].contains(where: \.isSeam)
        HapticEngine.shared.play(crossedSeam ? .landmark : .detent, channel: .carousel, timing: .withFrame, steps: abs(b - a))
    }
}

extension HapticChannel {
    static let carousel = HapticChannel("carousel")
}

// MARK: - Cells

private struct CarouselApp: View {
    let entry: AppEntry
    var model: IslandModel
    @State private var hover = false

    var body: some View {
        Button {
            AppCatalog.shared.launch(entry)
            model.collapse()
        } label: {
            IconImage(image: AppCatalog.shared.icon(for: entry), size: HomeCarousel.icon)
                .scaleEffect(hover ? 1.14 : 1)
                .shadow(color: .black.opacity(hover ? 0.4 : 0), radius: 5, y: 2)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .onHover { h in withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) { hover = h } }
        .help(entry.name)
        .accessibilityLabel("Open \(entry.name)")
    }
}

/// A Mac Flow feature as a tile the size of an app icon: dark glass, its symbol in its own colour, lit while it runs.
private struct CarouselFeature: View {
    let feature: HomeFeature
    var model: IslandModel
    @ObservedObject private var timer = FocusTimer.shared
    @ObservedObject private var awake = KeepAwake.shared
    @State private var hover = false

    private var running: Bool {
        switch feature {
        case .focus: timer.isActive
        case .awake: awake.isOn
        default: false
        }
    }

    var body: some View {
        let size = HomeCarousel.icon
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Button { feature.run(model) } label: {
            ZStack {
                shape.fill(running ? feature.tint.opacity(0.26) : Color.white.opacity(hover ? 0.12 : 0.075))
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                                   lineWidth: 0.75)
                Image(systemName: feature.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(feature.tint)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: size, height: size)
            .overlay(alignment: .bottom) {
                if running { Circle().fill(feature.tint).frame(width: 4, height: 4).offset(y: 7) }
            }
            .scaleEffect(hover ? 1.14 : 1)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .onHover { h in withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) { hover = h } }
        .contextMenu { feature.options(model, running: running) }
        .help(feature.title)
        .accessibilityLabel(feature.title)
        .accessibilityValue(running ? "On" : "")
    }
}

// MARK: - Features

/// Mac Flow's own places and tools, one tap from Home.
enum HomeFeature: String, CaseIterable, Identifiable {
    case focus, tasks, plan, rewind, day, mirror, awake, flow

    var id: String { rawValue }

    /// Flow needs the on-device model; everything else is always there.
    @MainActor static var available: [HomeFeature] {
        allCases.filter { $0 != .flow || Mind.shared.isAvailable }
    }

    var title: String {
        switch self {
        case .focus: "Focus"
        case .tasks: "Tasks"
        case .plan: "Plan Your Day"
        case .rewind: "Rewind"
        case .day: "Your Day"
        case .mirror: "Mirror"
        case .awake: "Keep Awake"
        case .flow: "Flow"
        }
    }

    var symbol: String {
        switch self {
        case .focus: "timer"
        case .tasks: "checklist"
        case .plan: "sun.horizon.fill"
        case .rewind: "clock.arrow.circlepath"
        case .day: "circle.circle"
        case .mirror: "person.crop.square"
        case .awake: "cup.and.saucer.fill"
        case .flow: "sparkle"
        }
    }

    @MainActor var tint: Color {
        switch self {
        case .focus: DS.Palette.orange
        case .tasks: TaskStyle.tint
        case .plan: PlanView.morning
        case .rewind: Color(red: 0.55, green: 0.66, blue: 1)
        case .day: Color(red: 0.62, green: 0.9, blue: 0.78)
        case .mirror: DS.Ink.primary
        case .awake: Color(red: 1, green: 0.8, blue: 0.35)
        case .flow: BrainStyle.tint
        }
    }

    @MainActor func run(_ model: IslandModel) {
        switch self {
        case .focus:
            if !FocusTimer.shared.isActive { FocusTimer.shared.start(minutes: 25, label: "Focus") }
            model.select(.activity(.timer))
        case .tasks: model.select(.tasks)
        case .plan: model.openPlan()
        case .rewind: model.open(.rewind)
        case .day: model.open(.day)
        case .mirror: model.openMirror()
        case .awake: KeepAwake.shared.toggle()
        case .flow: model.openBrain()
        }
    }

    /// What a right-click offers.
    @MainActor @ViewBuilder func options(_ model: IslandModel, running: Bool) -> some View {
        switch self {
        case .focus:
            ForEach([15, 25, 50], id: \.self) { m in
                Button("Focus for \(m) Minutes") { FocusTimer.shared.start(minutes: m, label: "Focus"); model.select(.activity(.timer)) }
            }
            Button("Take a 5-Minute Break") { FocusTimer.shared.start(minutes: 5, label: "Break"); model.select(.activity(.timer)) }
        case .awake:
            Button(running ? "Let the Mac Sleep" : "Keep the Mac Awake") { KeepAwake.shared.toggle() }
        default:
            Button("Open \(title)") { run(model) }
        }
    }
}
