import SwiftUI
import AppKit
import Combine

/// StandBy's state: which page, which widget in each stack, the wallpaper on show, night and burn-in drift.
@MainActor
final class StandByModel: ObservableObject {
    enum Page: Int, CaseIterable { case clock, widgets, nowPlaying }

    @Published var page: Page = .clock
    @Published var stacks = [0, 0]
    @Published var night = false
    @Published var drift = CGSize.zero
    @Published var chromeVisible = true
    @Published var showHint = false
    @Published private(set) var wallpaper: Wallpaper?
    @Published private(set) var images: Wallpapers.Images?
    /// The cover as a soft field of colour, for the album backdrop.
    @Published private(set) var albumField: StandByStage.AlbumField?
    private var chromeWork: DispatchWorkItem?
    private var screen = CGSize(width: 1470, height: 956)
    private var scale: CGFloat = 2
    private var artwork: AnyCancellable?
    private var fieldToken = 0
    private var shownAt = Date()

    /// The last picture shown, so Shuffle never opens on the same one twice running.
    private static var lastShown: String? {
        get { UserDefaults.standard.string(forKey: "standByLastWallpaper") }
        set { UserDefaults.standard.set(newValue, forKey: "standByLastWallpaper") }
    }

    var pages: [Page] { NowPlayingModel.shared.mode == .idle ? [.clock, .widgets] : Page.allCases }

    /// Loads the wallpaper for this screen and starts following the album's cover.
    func prepare(screen: CGSize, scale: CGFloat) {
        self.screen = screen
        self.scale = scale
        show(Wallpapers.resolve(Prefs.shared.standByWallpaper, after: Self.lastShown))
        artwork = NowPlayingModel.shared.$artwork
            .removeDuplicates { $0 === $1 }
            .sink { [weak self] image in MainActor.assumeIsolated { self?.makeField(image) } }
    }

    func show(_ w: Wallpaper?) {
        wallpaper = w
        shownAt = Date()
        guard let w else {
            withAnimation(.easeInOut(duration: 1)) { images = nil }
            return
        }
        if !RenderMode.snapshot { Self.lastShown = w.id }
        Wallpapers.load(w.id, for: screen, scale: scale) { [weak self] loaded in
            guard let self, self.wallpaper?.id == w.id else { return }
            withAnimation(.easeInOut(duration: 1.2)) { self.images = loaded }
        }
    }

    /// ↑ and ↓ on the clock: the next picture (for this time in StandBy).
    func cycleWallpaper(by delta: Int) {
        guard page == .clock, Prefs.shared.standByWallpaper != Wallpapers.none else { return }
        show(Wallpapers.next(after: wallpaper?.id, by: delta))
        flashChrome()
    }

    private func makeField(_ image: NSImage?) {
        fieldToken += 1
        let token = fieldToken
        guard let image else { albumField = nil; return }
        nonisolated(unsafe) let source = image
        DispatchQueue.global(qos: .userInitiated).async {
            let field = StandByStage.albumField(source)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fieldToken == token else { return }
                self.albumField = field
            }
        }
    }

    /// Smart stacks: only widgets with something to show, without asking for anything.
    func stack(_ i: Int) -> [WidgetKind] {
        let candidates: [WidgetKind] = i == 0
            ? (FocusTimer.shared.isActive ? [.timer] : []) + [.upNext, .worldClock]
            : [.nowPlaying, .weather, .batteries, .system]
        let ready = candidates.filter(Self.isReady)
        return ready.isEmpty ? [i == 0 ? .worldClock : .system] : ready
    }

    private static func isReady(_ k: WidgetKind) -> Bool {
        switch k {
        case .upNext: CalendarModel.shared.access == .granted
        case .weather: Prefs.shared.weatherEnabled && WeatherService.shared.snapshot != nil
        case .nowPlaying: NowPlayingModel.shared.mode != .idle
        case .batteries: BatteryMonitor.shared.hasBattery
        case .timer: FocusTimer.shared.isActive
        default: true
        }
    }

    func turn(_ delta: Int) {
        let list = pages
        let i = list.firstIndex(of: page) ?? 0
        let next = min(max(i + delta, 0), list.count - 1)
        guard next != i else { Haptics.snap(); return }
        withAnimation(Motion.duo) { page = list[next] }
        flashChrome()
    }

    func go(to p: Page) {
        guard p != page, pages.contains(p) else { return }
        withAnimation(.spring(response: 0.9, dampingFraction: 0.9)) { page = p }
    }

    func cycle(stack s: Int, by delta: Int) {
        guard page == .widgets else { return }
        let count = stack(s).count
        guard count > 1 else { return }
        withAnimation(Motion.duo) { stacks[s] = (stacks[s] + delta + count) % count }
        flashChrome()
    }

    func flashChrome() {
        withAnimation(.easeOut(duration: 0.25)) { chromeVisible = true }
        chromeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.8)) { self?.chromeVisible = false } }
        chromeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func tickMinute(_ date: Date = Date()) {
        let hour = Calendar.current.component(.hour, from: date)
        let isNight = Prefs.shared.standByNightMode && (hour >= 22 || hour < 6)
        if isNight != night { withAnimation(.easeInOut(duration: 2)) { night = isNight } }
        // Burn-in care: wander a few points, slowly.
        let m = Double(Calendar.current.component(.minute, from: date))
        withAnimation(.easeInOut(duration: 3)) {
            drift = CGSize(width: sin(m * 0.9) * 6, height: cos(m * 1.3) * 5)
        }
        // Shuffle: a new picture every quarter of an hour, while the clock is up.
        if Prefs.shared.standByWallpaper == Wallpapers.shuffle, page == .clock, !night, date.timeIntervalSince(shownAt) >= 900 {
            show(Wallpapers.resolve(Wallpapers.shuffle, after: wallpaper?.id))
        }
    }
}

struct StandByView: View {
    @ObservedObject var model: StandByModel
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var np = NowPlayingModel.shared

    private var style: StandByClockStyle { StandByClockStyle(rawValue: prefs.standByClockStyle) ?? .glass }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let album = model.page == .nowPlaying && np.mode == .track && model.albumField != nil
            ZStack {
                StandByBackdrop(scene: album ? .album : .picture, images: model.images, album: model.albumField,
                                playing: np.isPlaying, shade: shade, night: red)
                ambient(page(size).id(model.page).transition(pageTransition))
                // The wallpaper's foreground, over the time and under everything else.
                StandByDepth(image: model.images?.depth,
                             visible: model.page == .clock && prefs.standByDepth && style.tucksBehindDepth && !red)
                if model.page == .clock {
                    ambient(StandByClockPage(layer: .front, size: size, frost: nil))
                        .transition(.opacity)
                }
                chrome(size)
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    /// Night Mode's dim red: the clock and widgets only. Now Playing always keeps the album's colours.
    private var red: Bool { model.night && model.page != .nowPlaying }

    /// Drifting against burn-in, and dim red at night (the backdrop goes dark by itself).
    private func ambient<V: View>(_ v: V) -> some View {
        v.offset(model.drift)
            .saturation(red ? 0 : 1)
            .colorMultiply(red ? WidgetPalette.night : .white)
    }

    /// How much to quiet the picture behind each page.
    private var shade: Double {
        switch model.page {
        case .clock: 0.08
        case .widgets: 0.5
        case .nowPlaying: 0.55
        }
    }

    private var pageTransition: AnyTransition {
        Access.reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.03)), removal: .opacity)
    }

    @ViewBuilder private func page(_ size: CGSize) -> some View {
        switch model.page {
        case .clock: StandByClockPage(layer: .back, size: size, frost: red ? nil : model.images?.frost)
        case .widgets: StandByWidgetsPage(model: model, size: size)
        case .nowPlaying: StandByNowPlayingPage(size: size)
        }
    }

    private func chrome(_ size: CGSize) -> some View {
        VStack {
            if model.showHint {
                Text(hint)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(Capsule().fill(.black.opacity(0.35)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .transition(.opacity.combined(with: .offset(y: -8)))
                    .padding(.top, max(22, size.height * 0.035))
            }
            Spacer()
            HStack(spacing: 8) {
                ForEach(model.pages, id: \.self) { p in
                    Capsule()
                        .fill(.white.opacity(p == model.page ? 0.9 : 0.3))
                        .frame(width: p == model.page ? 18 : 7, height: 7)
                }
            }
            .animation(Motion.duo, value: model.page)
            .padding(.bottom, max(16, size.height * 0.022))
        }
        .opacity(model.chromeVisible ? 1 : 0)
        .colorMultiply(red ? WidgetPalette.night : .white)
        .accessibilityHidden(true)
    }

    private var hint: String {
        switch model.page {
        case .nowPlaying: "Space plays and pauses. L shows or hides lyrics. ← → change pages. Move the pointer to leave."
        case .clock where prefs.standByWallpaper != Wallpapers.none: "← → change pages. ↑ ↓ change the wallpaper. Move the pointer or press any other key to leave."
        default: "Press ← or → to change pages. Move the pointer or press any other key to leave StandBy."
        }
    }
}

// MARK: - Widgets

private struct StandByWidgetsPage: View {
    @ObservedObject var model: StandByModel
    let size: CGSize

    var body: some View {
        let side = min(size.width * 0.4, size.height * 0.72)
        HStack(spacing: size.width * 0.06) {
            stack(0, side: side)
            stack(1, side: side)
        }
        .frame(width: size.width, height: size.height)
    }

    private func stack(_ i: Int, side: CGFloat) -> some View {
        let kinds = model.stack(i)
        let index = model.stacks[i] % max(kinds.count, 1)
        let kind = kinds[index]
        let scale = side / WidgetFamily.small.size.width
        return HStack(spacing: 18) {
            if i == 0 { dots(kinds.count, index) }
            WidgetContent(kind: kind)
                .padding(WidgetMetrics.margin)
                .frame(width: WidgetFamily.small.size.width, height: WidgetFamily.small.size.height, alignment: .topLeading)
                .containerShape(RoundedRectangle(cornerRadius: WidgetMetrics.radius, style: .continuous))
                .environment(\.widgetStyle, .standBy)
                .environment(\.widgetFamily, .small)
                .allowsHitTesting(false)
                .scaleEffect(scale * 0.86)
                .frame(width: side, height: side)
                .background { GlassCard(side: side) }
                .id(kind)
                .transition(.duo)
            if i == 1 { dots(kinds.count, index) }
        }
    }

    private func dots(_ count: Int, _ index: Int) -> some View {
        VStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { j in
                Capsule().fill(.white.opacity(j == index ? 0.85 : 0.25)).frame(width: 5, height: j == index ? 14 : 5)
            }
        }
        .opacity(count > 1 && model.chromeVisible ? 1 : 0)
        .animation(Motion.duo, value: index)
        .frame(width: 5)
    }
}

/// A widget's card on StandBy: a rounded square of glass (translucent before macOS 26).
private struct GlassCard: View {
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.12, style: .continuous)
        if #available(macOS 26.0, *), !RenderMode.snapshot {
            Color.clear.frame(width: side, height: side).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.black.opacity(0.3))
                .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                .frame(width: side, height: side)
        }
    }
}
