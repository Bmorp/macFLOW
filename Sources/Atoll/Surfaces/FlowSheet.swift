import SwiftUI

/// Pull the notch down: the island opens into a sheet — your day on the left (the ring, what it says, what's next),
/// what's playing on the right (big artwork, its light filling the sheet), and a line to Flow underneath. Two fingers
/// down on Home (or a click on its grabber) to open; two fingers up, Esc or a click away to put it back.
struct FlowSheet: View {
    var model: IslandModel
    @ObservedObject private var art = DayArtModel.shared
    @ObservedObject private var media = NowPlayingModel.shared
    @ObservedObject private var plan = PlanStore.shared
    @ObservedObject private var calendar = CalendarModel.shared
    @ObservedObject private var agent = BrainAgent.shared
    @ObservedObject private var learned = PatternsModel.shared
    @ObservedObject private var news = NewsStore.shared
    @ObservedObject private var learn = LearnStore.shared
    @State private var page: Page
    /// Which page the sheet opens on (debug renders set it).
    nonisolated(unsafe) static var startPage: Page = .today

    enum Page: String, CaseIterable { case today = "Today", brief = "Brief", learn = "Learn" }
    @Environment(\.islandShowing) private var showing
    @FocusState private var asking: Bool
    @State private var draft = ""
    @State private var drawn: Double

    static let width: CGFloat = 700
    static let height: CGFloat = 360
    private var inset: CGFloat { IslandModel.expandedFlare + DS.Island.rowLeading + 4 }

    init(model: IslandModel) {
        self.model = model
        _drawn = State(initialValue: RenderMode.snapshot || model.mode != .expanded(.sheet) ? 1 : 0)
        _page = State(initialValue: Self.startPage)
    }

    var body: some View {
        let size = model.expandedSize(.sheet)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer(minLength: model.notch.width + 24)
                pagePicker
                GlyphButton(symbol: "chevron.up", label: "Put Away", size: 11, tint: DS.Ink.secondary, hit: 26) { model.select(.glance) }
            }
            .frame(height: model.notch.height)
            .padding(.horizontal, inset)

            HStack(alignment: .top, spacing: 18) {
                Group {
                    switch page {
                    case .today: today
                    case .brief: brief
                    case .learn: learning
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .transition(.opacity)
                Rectangle().fill(DS.Ink.hairline).frame(width: 1).padding(.vertical, 6)
                playing.frame(width: 250, alignment: .topLeading)
            }
            .padding(.horizontal, inset)
            .padding(.top, 8)
            .frame(height: 268, alignment: .top)

            Spacer(minLength: 0)
            flowLine
                .padding(.horizontal, inset)
                .padding(.bottom, 18)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(alignment: .top) {
            ArtField(clearTop: model.notch.height / max(1, size.height), strength: 0.9, ambient: true)
        }
        .onChange(of: showing, initial: true) { _, on in
            guard on, model.mode == .expanded(.sheet), !RenderMode.snapshot else { if !on { asking = false }; return }
            art.load()
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { drawn = 0 }
            withAnimation(Access.reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 1.1, dampingFraction: 0.9).delay(0.1)) { drawn = 1 }
        }
    }

    // MARK: Pages

    private var pagePicker: some View {
        HStack(spacing: 2) {
            ForEach(Page.allCases, id: \.self) { p in
                Button {
                    withAnimation(Motion.morph) { page = p }
                    if p == .brief { news.refresh() }
                } label: {
                    Text(p.rawValue)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(page == p ? Color.black : DS.Ink.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(page == p ? Color.white : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == p ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    // MARK: Brief

    @ViewBuilder private var brief: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BRIEF").font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(DS.Ink.tertiary)
                Spacer()
                Text(news.fetching ? "Updating…" : news.fetchedAt == .distantPast ? "" : "Ranked for you · \(news.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(DS.Kit.caption).foregroundStyle(DS.Ink.tertiary)
            }
            if !Prefs.shared.newsEnabled {
                Text("The Brief is off. Turn it on in Settings › Flow, and choose your sources.").font(DS.Kit.caption).foregroundStyle(DS.Ink.tertiary)
            } else if news.items.isEmpty {
                Text(news.fetching ? "Getting the latest from your sources…" : "Nothing yet — your sources are in Settings › Flow.")
                    .font(DS.Kit.caption).foregroundStyle(DS.Ink.tertiary)
            } else {
                ForEach(news.brief.prefix(4)) { item in
                    Button { NSWorkspace.shared.open(item.link) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                if item.forYou { FlowGlyph(size: 8) }
                                Text("\(item.source.uppercased()) · \(Self.ago(item.date))")
                                    .font(.system(size: 9.5, weight: .semibold)).tracking(0.5)
                                    .foregroundStyle(item.forYou ? BrainStyle.tint : DS.Ink.tertiary)
                            }
                            Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                                .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                    .help(item.summary.isEmpty ? item.title : String(item.summary.prefix(240)))
                }
            }
        }
    }

    static func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        return m < 60 ? "\(max(1, m))m" : m < 1440 ? "\(m / 60)h" : "\(m / 1440)d"
    }

    // MARK: Learn

    @ViewBuilder private var learning: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LEARN").font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(DS.Ink.tertiary)
                Spacer()
                Text("\(learn.cards.count) card\(learn.cards.count == 1 ? "" : "s") · \(learn.due.count) to recall")
                    .font(DS.Kit.caption).foregroundStyle(DS.Ink.tertiary)
            }
            if let card = learn.due.first {
                StudyCardView(model: model, card: card, inSheet: true)
                    .padding(14)
                    .background(FlowCardBackground(corner: 16))
            } else if learn.cards.isEmpty {
                Text("Save a page you’re reading, or a passage you copy, and Flow turns it into cards — then brings them back at quiet moments so they stick.")
                    .font(DS.Kit.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                let next = learn.cards.map(\.due).min() ?? Date()
                Text("All caught up. Next card \(next.formatted(.relative(presentation: .named))).")
                    .font(DS.Kit.caption).foregroundStyle(DS.Ink.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(learn.sources.prefix(3), id: \.self) { s in
                        Label(s, systemImage: "rectangle.stack").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                    }
                }
            }
            if BrowserReader.browser(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) != nil
                || NSWorkspace.shared.runningApplications.contains(where: { BrowserReader.browser(for: $0.bundleIdentifier) != nil }) {
                FlowOptionButton(title: learn.making ? "Making cards…" : "Save the Page I’m Reading") { PageActions.perform(.learn) }
            }
        }
    }

    // MARK: Today

    private var today: some View {
        let s = art.story
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                DayRing(story: s, progress: drawn).frame(width: 132, height: 132)
                VStack(alignment: .leading, spacing: 5) {
                    Text(s.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(DS.Ink.tertiary)
                    Text(s.headline).font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text("\(DayArtView.length(s.focus)) focus · \(s.meetings.count) meetings · \(s.songs.count) songs")
                        .font(DS.Kit.caption).foregroundStyle(DS.Ink.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("NEXT").font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(DS.Ink.tertiary)
                let upcoming = Self.upcoming(plan: plan.plan, events: calendar.events)
                if upcoming.isEmpty {
                    let hour = Calendar.current.component(.hour, from: Date())
                    if hour >= Prefs.shared.planEndHour || hour < 5 {
                        Text("That’s the day. Tomorrow’s plan comes with the morning.").font(DS.Kit.caption).foregroundStyle(DS.Ink.tertiary)
                    } else if plan.plan.started {
                        Text("Nothing else planned today.").font(DS.Kit.caption).foregroundStyle(DS.Ink.tertiary)
                    } else {
                        HStack(spacing: 10) {
                            Text("No plan yet.").font(DS.Kit.caption).foregroundStyle(DS.Ink.tertiary)
                            FlowOptionButton(title: "Plan the Day") { IslandManager.shared.openPlan() }
                        }
                    }
                } else {
                    ForEach(upcoming, id: \.title) { item in
                        HStack(spacing: 8) {
                            Text(item.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(DS.Ink.tertiary)
                                .frame(width: 58, alignment: .leading)
                            Capsule().fill(item.tint).frame(width: 3, height: 14)
                            Text(item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Ink.primary).lineLimit(1)
                        }
                    }
                }
            }
            // How you work, as Flow has learned it.
            if learned.patterns.isReady {
                VStack(alignment: .leading, spacing: 6) {
                    Text("YOUR RHYTHM").font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(DS.Ink.tertiary)
                    FocusRhythm(patterns: learned.patterns, height: 30)
                    if let line = learned.patterns.insights.first {
                        Text(line).font(DS.Kit.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    struct Upcoming { let start: Date; let title: String; let tint: Color }

    /// The next three things: planned blocks and calendar events, in order.
    static func upcoming(plan: DayPlan, events: [CalendarModel.Event]) -> [Upcoming] {
        let now = Date()
        var out = plan.items.filter { $0.end > now && !$0.done && $0.kind != .calendar }
            .map { Upcoming(start: $0.start, title: $0.title, tint: $0.kind == .rest ? PlanView.morning : BrainStyle.tint) }
        out += events.filter { !$0.isAllDay && $0.end > now && Calendar.current.isDateInToday($0.start) }
            .map { Upcoming(start: $0.start, title: $0.title, tint: $0.color) }
        return Array(out.sorted { $0.start < $1.start }.prefix(3))
    }

    // MARK: Playing

    @ViewBuilder private var playing: some View {
        if media.mode == .idle {
            VStack(alignment: .leading, spacing: 8) {
                Text("NOTHING PLAYING").font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(DS.Ink.tertiary)
                Text("Pick up where you left off").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                HStack(spacing: 6) {
                    ForEach(MediaSource.allCases.filter(\.isInstalled), id: \.self) { source in
                        FlowOptionButton(title: source.name) { media.open(source) }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Button { media.openCurrentApp() } label: {
                    ImmersiveArtwork(size: 132).tilt(8, corner: 132 * 0.24, size: CGSize(width: 132, height: 132))
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .accessibilityLabel("Open player")
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: media.mode == .app ? (media.otherApp?.name ?? "Audio") : media.title, font: DS.Kit.title, color: DS.Ink.primary)
                    Text(media.mode == .app ? "Playing audio" : media.artist).font(DS.Kit.meta).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                }
                HStack(spacing: 2) {
                    let on = media.mode == .app || media.isPlaying
                    Ghost(symbol: "backward.fill", label: "Previous", size: 14, hit: 32) { media.previous() }
                    Ghost(symbol: on ? "pause.fill" : "play.fill", label: on ? "Pause" : "Play", size: 20, weight: .bold, hit: 36) { media.playPause() }
                    Ghost(symbol: "forward.fill", label: "Next", size: 14, hit: 32) { media.next() }
                }
                .padding(.leading, -8)
                .disabled(!media.canControl)
            }
        }
    }

    // MARK: Flow

    private var flowLine: some View {
        HStack(spacing: 10) {
            FlowGlyph(size: 13)
            TextField("", text: $draft, prompt: Text(lastLine ?? "Ask Flow, or tell it what to do").foregroundColor(DS.Ink.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(DS.Ink.primary)
                .focused($asking)
                .onSubmit(send)
            if !draft.isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 24, height: 24).background(Circle().fill(Color.white))
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 21, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).strokeBorder(Color.white.opacity(asking ? 0.2 : 0.07), lineWidth: 0.5))
        .onTapGesture {
            model.panel?.makeKey()
            asking = true
        }
    }

    /// Flow's last word, as the field's placeholder — so the sheet shows where the conversation got to.
    private var lastLine: String? {
        guard let m = agent.messages.last(where: { $0.role == .atoll && !$0.text.isEmpty }) else { return nil }
        let one = m.text.replacingOccurrences(of: "\n", with: " ")
        return one.count > 70 ? String(one.prefix(68)) + "…" : one
    }

    private func send() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        draft = ""
        model.openBrain()
        BrainAgent.shared.send(q)
    }
}
