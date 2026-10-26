import SwiftUI

/// Plan your day, in the island: the morning's first moment on the Mac. Three priorities and any meetings on the
/// left; on the right the day itself, re-flowing as you type — each priority finds its own free slot around your
/// meetings. "Start My Day" hands the plan to Flow, which nudges you through it.
struct PlanView: View {
    var model: IslandModel
    @ObservedObject private var store = PlanStore.shared
    @ObservedObject private var calendar = CalendarModel.shared
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.islandShowing) private var showing
    @FocusState private var field: Field?
    @State private var meetingDraft = ""
    @State private var meetingMiss = false
    /// The morning choreography: sections settle in one after another as the island opens.
    @State private var arrived: Bool

    enum Field: Hashable { case priority(Int), meeting }

    static let height: CGFloat = 276
    private var inset: CGFloat { IslandModel.expandedFlare + DS.Island.rowLeading + 4 }

    static let morning = Color(red: 1.0, green: 0.66, blue: 0.38)

    init(model: IslandModel) {
        self.model = model
        // A copy drawn while the island closes is already settled.
        _arrived = State(initialValue: RenderMode.snapshot || model.mode != .expanded(.plan))
    }

    var body: some View {
        let size = model.expandedSize(.plan)
        let day = store.preview
        VStack(spacing: 0) {
            header
                .frame(height: model.notch.height)
                .padding(.horizontal, inset)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    intro.arrive(arrived, 0)
                    priorities.padding(.top, 14).arrive(arrived, 1)
                    meetingField.padding(.top, 10).arrive(arrived, 2)
                }
                .frame(width: 262, alignment: .leading)
                DayColumn(items: day, unplaced: store.unplaced.count, onRemove: { store.removeMeeting($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .arrive(arrived, 1)
            }
            .padding(.horizontal, inset)
            .padding(.top, 6)
            .frame(height: 214, alignment: .top)
            Spacer(minLength: 0)
            footer(day)
                .padding(.horizontal, inset)
                .padding(.bottom, 16)
                .arrive(arrived, 3)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(alignment: .top) {
            ZStack {
                // Morning light from the top left, Flow's violet answering from the bottom right.
                ContentLight(color: Self.morning, origin: UnitPoint(x: 0.1, y: -0.05), strength: 1.1)
                ContentLight(color: BrainStyle.tint, origin: UnitPoint(x: 0.95, y: 1.15), strength: 0.55)
            }
        }
        .onChange(of: showing, initial: true) { _, on in
            if on { opened() } else { closed() }
        }
    }

    // MARK: Choreography

    private func opened() {
        guard model.mode == .expanded(.plan), !RenderMode.snapshot else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { arrived = false }
        DispatchQueue.main.async { arrived = true }
        // The keyboard comes once the sections have settled in (taking focus wakes the input system: a ~70 ms stall that
        // stuttered the arrival when it landed mid-animation).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            guard model.mode == .expanded(.plan) else { return }
            model.panel?.makeKey()
            // Into the first empty priority; if Flow drafted all three, nowhere — they're there to review, not retype.
            field = store.priorities.firstIndex { $0.title.isEmpty }.map { .priority($0) }
        }
    }

    private func closed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { if !showing { field = nil } }
    }

    // MARK: Header (beside the notch)

    // The tab switcher sits at the leading side of the notch; the way out at the trailing side.
    private var header: some View {
        HStack(spacing: 10) {
            Spacer(minLength: model.notch.width + 24)
            GlyphButton(symbol: "xmark", label: "Later", size: 11, tint: DS.Ink.secondary, hit: 26) { MorningPlanner.shared.later() }
        }
    }

    // MARK: Left: what matters

    private var intro: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "sun.horizon.fill").symbolRenderingMode(.multicolor).font(.system(size: 11))
                Text(greeting.uppercased())
                    .foregroundStyle(Self.morning)
                Text(PlanClock.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
                    .foregroundStyle(DS.Ink.tertiary)
                if prefs.weatherEnabled, let w = weather.snapshot {
                    HStack(spacing: 3) {
                        Image(systemName: WeatherService.symbol(w.code, day: w.isDay)).symbolRenderingMode(.multicolor)
                        Text("\(Int(w.temp.rounded()))°").foregroundStyle(DS.Ink.tertiary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Int(w.temp.rounded())) degrees, \(WeatherService.describe(w.code))")
                }
            }
            .font(DS.Kit.eyebrow)
            .tracking(DS.Kit.eyebrowTracking)
            .lineLimit(1)
            Text(dayOver ? "Your workday’s done" : store.plan.started ? "Let’s rework today" : "What would make today a win?")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: PlanClock.now)
        return h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }

    private static let prompts = ["What matters most", "Next priority", "If there’s time"]

    private var priorities: some View {
        VStack(spacing: 6) {
            ForEach(Array(store.priorities.indices.prefix(3)), id: \.self) { i in
                PriorityRow(index: i, priority: $store.priorities[i], focused: field == .priority(i)) {
                    TextField("", text: $store.priorities[i].title,
                              prompt: Text(Self.prompts[min(i, 2)]).foregroundColor(DS.Ink.tertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.Ink.primary)
                        .focused($field, equals: .priority(i))
                        .onSubmit { field = i < 2 ? .priority(i + 1) : .meeting }
                }
            }
        }
        .animation(Motion.morph, value: store.priorities.map { $0.title.isEmpty })
    }

    private var meetingField: some View {
        let parsed = PlanScheduler.parseMeeting(meetingDraft)
        return HStack(spacing: 9) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DayColumn.color(.meeting))
                .frame(width: 20)
            TextField("", text: $meetingDraft, prompt: Text("Add a meeting, like “Sam at 4pm”").foregroundColor(DS.Ink.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.Ink.primary)
                .focused($field, equals: .meeting)
                .onSubmit(addMeeting)
                .onChange(of: meetingDraft) { _, _ in if meetingMiss { meetingMiss = false } }
            if let p = parsed {
                // What it understood, before you press Return.
                Text("\(p.start.formatted(date: .omitted, time: .shortened)) · \(DayColumn.length(p.minutes))")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DayColumn.color(.meeting))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(DayColumn.color(.meeting).opacity(0.16)))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if meetingMiss {
                Text("Add a time, like 3pm").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(DS.Palette.orange)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: parsed == nil)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(field == .meeting ? 0.09 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(meetingMiss ? DS.Palette.orange.opacity(0.6) : Color.white.opacity(field == .meeting ? 0.18 : 0.05), lineWidth: 0.5))
        .modifier(Shake(amount: meetingMiss ? 1 : 0))
        .animation(.spring(response: 0.3, dampingFraction: 0.4), value: meetingMiss)
    }

    private func addMeeting() {
        guard !meetingDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if store.addMeeting(meetingDraft) != nil {
            meetingDraft = ""
            Haptics.snap()
        } else {
            meetingMiss = true
        }
    }

    // MARK: Footer: Flow's read on the day, and go

    private func footer(_ day: [PlanItem]) -> some View {
        HStack(spacing: 10) {
            FlowGlyph(size: 12)
            Text(tip(day))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Ink.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: tip(day))
            Spacer(minLength: 8)
            if !store.plan.started {
                QuietButton(title: "Skip Today") { MorningPlanner.shared.skip() }
            }
            Pill(title: store.plan.started ? "Update Plan" : "Start My Day", symbol: store.plan.started ? "arrow.triangle.2.circlepath" : "sunrise.fill") {
                field = nil
                MorningPlanner.shared.startDay()
            }
        }
        .frame(height: 32)
    }

    /// Past the end of the workday (Settings › Flow › Plan Your Day).
    private var dayOver: Bool { Calendar.current.component(.hour, from: PlanClock.now) >= prefs.planEndHour }

    private func tip(_ day: [PlanItem]) -> String {
        let now = PlanClock.now
        let meetings = day.filter { ($0.kind == .meeting || $0.kind == .calendar) && $0.end > now }.count
        let typed = store.priorities.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        let m = meetings == 1 ? "1 meeting" : "\(meetings) meetings"
        if dayOver { return "I’ll ask again tomorrow morning." }
        if !store.plan.started, store.hasDrafts {
            let fromYesterday = store.priorities.contains { $0.isDraft && ($0.source ?? "").contains("yesterday") }
            return fromYesterday ? "Drafted from yesterday — change anything" : "Drafted from your week — change anything"
        }
        if let miss = store.unplaced.first {
            let end = Calendar.current.date(bySettingHour: prefs.planEndHour, minute: 0, second: 0, of: now) ?? now
            return "“\(miss.title)” won’t fit before \(end.formatted(date: .omitted, time: .shortened)) — shorten something?"
        }
        if typed.isEmpty {
            return meetings == 0 ? "Start with the one thing that matters most." : "\(m) today. What matters around them?"
        }
        if let w = PatternsModel.shared.bestWindow(on: now), let first = typed.first,
           let placed = day.first(where: { $0.id == first.id }), w.contains(placed.start) {
            return "Your sharpest hours are \(Patterns.hours(PatternsModel.shared.patterns.bestStart ?? 9, PatternsModel.shared.patterns.bestEnd ?? 11)) — “\(first.title)” goes there"
        }
        if meetings >= 4 { return "A meeting-heavy day — your focus fits between them." }
        let focus = DayColumn.length(typed.reduce(0) { $0 + $1.minutes })
        return meetings > 0 ? "\(focus) of focus around \(m)" : "\(focus) of focus · I’ll nudge you before each"
    }
}

// MARK: - A priority

private struct PriorityRow<Field: View>: View {
    let index: Int
    @Binding var priority: Priority
    let focused: Bool
    @ViewBuilder var field: Field

    var body: some View {
        let filled = !priority.title.trimmingCharacters(in: .whitespaces).isEmpty
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(filled ? BrainStyle.tint : .clear)
                Circle().strokeBorder(filled ? .clear : Color.white.opacity(0.22), lineWidth: 1)
                Text("\(index + 1)")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(filled ? .white : DS.Ink.tertiary)
            }
            .frame(width: 20, height: 20)
            .scaleEffect(filled ? 1 : 0.92)
            field
            if priority.isDraft, let source = priority.source {
                // Flow drafted this one: its mark, and where it came from on hover.
                FlowGlyph(size: 9)
                    .help("Drafted by Flow · \(source)")
                    .accessibilityLabel("Drafted by Flow, \(source)")
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            Button(action: cycle) {
                HStack(spacing: 3) {
                    Text(DayColumn.length(priority.minutes)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(filled ? DS.Ink.primary : DS.Ink.tertiary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(filled ? 0.1 : 0.05)))
                .contentShape(Capsule())
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .help("How long — click to change (⌥-click to shorten)")
            .accessibilityLabel("Length, \(DayColumn.length(priority.minutes))")
            .accessibilityHint("Changes how long this takes")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(focused ? 0.09 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(focused ? 0.18 : 0.05), lineWidth: 0.5))
    }

    private func cycle() {
        let back = NSEvent.modifierFlags.contains(.option)
        let lengths = PlanLengths.all
        let i = lengths.firstIndex(of: priority.minutes) ?? 3
        let next = back ? (i - 1 + lengths.count) % lengths.count : (i + 1) % lengths.count
        withAnimation(Motion.morph) { priority.minutes = lengths[next] }
        Haptics.snap()
    }
}

private enum PlanLengths {
    static let all = [15, 30, 45, 60, 90, 120, 180]
}

// MARK: - The day

/// The day at a glance — a strip from morning to evening with now marked — and below it, the schedule.
private struct DayColumn: View {
    let items: [PlanItem]
    let unplaced: Int
    let onRemove: (UUID) -> Void
    @ObservedObject private var prefs = Prefs.shared

    static func color(_ kind: PlanItem.Kind) -> Color {
        switch kind {
        case .focus: BrainStyle.tint
        case .meeting: Color(red: 0.36, green: 0.84, blue: 0.72)
        case .calendar: DS.Palette.green
        case .rest: PlanView.morning
        }
    }

    static func length(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("YOUR DAY").font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(DS.Ink.tertiary)
                Spacer()
                Text(free).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(DS.Ink.tertiary)
            }
            DayStrip(items: items, startHour: prefs.planStartHour, endHour: prefs.planEndHour)
                .frame(height: 26)
            if items.isEmpty {
                Text("A clear day. Add what matters on the left — it’ll find its place here.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(items) { item in
                                AgendaRow(item: item, onRemove: item.kind == .meeting ? { onRemove(item.id) } : nil)
                                    .id(item.id)
                                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                            }
                        }
                        .padding(.bottom, 14)
                        .animation(Motion.morph, value: items.map { "\($0.id)\($0.start.timeIntervalSince1970)" })
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // The list runs on under the footer: fade it rather than cut it.
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .onAppear {
                        // Start at what's next, not at what's already over.
                        if let next = items.first(where: { $0.end > PlanClock.now }), next.id != items.first?.id { proxy.scrollTo(next.id, anchor: .top) }
                    }
                }
            }
        }
    }

    /// What's left of the working day once meetings and blocks are in.
    private var free: String {
        let cal = Calendar.current
        let now = PlanClock.now
        guard let end = cal.date(bySettingHour: prefs.planEndHour, minute: 0, second: 0, of: now) else { return "" }
        let start = max(now, cal.date(bySettingHour: prefs.planStartHour, minute: 0, second: 0, of: now) ?? now)
        guard end > start else { return "Day’s done" }
        let window = DateInterval(start: start, end: end)
        let busy = items.compactMap { $0.interval.intersection(with: window)?.duration }.reduce(0, +)
        let left = Int(max(0, window.duration - busy) / 60)
        return "\(Self.length(left / 15 * 15)) free"
    }
}

private struct DayStrip: View {
    let items: [PlanItem]
    let startHour: Int
    let endHour: Int
    @Environment(\.islandShowing) private var showing

    var body: some View {
        TimelineView(showing ? .periodic(from: .now, by: 60) : .periodic(from: .distantFuture, by: 3600)) { _ in
            let now = PlanClock.now
            GeometryReader { geo in
                let cal = Calendar.current
                let first = min(startHour, items.map { cal.component(.hour, from: $0.start) }.min() ?? startHour)
                let last = max(endHour, items.map { cal.component(.hour, from: $0.end) + 1 }.max() ?? endHour)
                let day0 = cal.date(bySettingHour: first, minute: 0, second: 0, of: now) ?? now
                let span = TimeInterval(max(1, last - first) * 3600)
                let w = geo.size.width
                let x: (Date) -> CGFloat = { d in CGFloat(min(1, max(0, d.timeIntervalSince(day0) / span))) * w }
                ZStack(alignment: .topLeading) {
                    Capsule().fill(Color.white.opacity(0.07)).frame(height: 10)
                    ForEach(items) { item in
                        let x0 = x(item.start), x1 = x(item.end)
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(DayColumn.color(item.kind).opacity(item.end < now ? 0.35 : 0.9))
                            .frame(width: max(3, x1 - x0 - 1.5), height: 10)
                            .offset(x: x0)
                    }
                    // The past, dimmed; now, a bright tick.
                    let nx = x(now)
                    if nx > 0, nx < w {
                        Rectangle().fill(Color.black.opacity(0.35)).frame(width: nx, height: 10).clipShape(Capsule())
                        Capsule().fill(Color.white).frame(width: 2, height: 16).offset(x: nx - 1, y: -3)
                            .shadow(color: .white.opacity(0.6), radius: 3)
                    }
                    // Hour marks every three hours.
                    ForEach(Array(stride(from: first + (3 - first % 3) % 3, through: last, by: 3)), id: \.self) { h in
                        let d = cal.date(bySettingHour: min(h, 23), minute: 0, second: 0, of: now) ?? now
                        Text("\(h % 12 == 0 ? 12 : h % 12)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(DS.Ink.tertiary)
                            .fixedSize()
                            .position(x: min(max(x(d), 8), w - 8), y: 21)
                    }
                }
                .animation(Motion.morph, value: items.map { "\($0.id)\($0.start.timeIntervalSince1970)\($0.minutes)" })
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your day: \(items.count) blocks")
    }
}

private struct AgendaRow: View {
    let item: PlanItem
    let onRemove: (() -> Void)?
    @State private var hover = false

    var body: some View {
        let past = item.end < PlanClock.now
        HStack(spacing: 9) {
            Text(item.start.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(DS.Ink.tertiary)
                .frame(width: 34, alignment: .trailing)
            Capsule().fill(DayColumn.color(item.kind)).frame(width: 3, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Ink.primary).lineLimit(1)
                Text("\(DayColumn.length(item.minutes)) · \(label)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DS.Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(DS.Palette.green)
            } else if let onRemove, hover {
                Ghost(symbol: "minus.circle.fill", label: "Remove \(item.title)", size: 12, tint: DS.Ink.tertiary, hit: 22, action: onRemove)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hover ? 0.05 : 0)))
        .opacity(past && !item.done ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch item.kind {
        case .focus: "Focus"
        case .meeting: "Meeting"
        case .calendar: "Calendar"
        case .rest: "Break"
        }
    }
}

// MARK: - Small pieces

/// A text button for the quieter choice beside a primary one.
struct QuietButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(hover ? DS.Ink.primary : DS.Ink.secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// A short horizontal shake: "that didn't work".
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(amount * .pi * 4) * (1 - amount * 0.5), y: 0))
    }
}

private struct Arrive: ViewModifier {
    let on: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on || Access.reduceMotion ? 0 : 10)
            .animation(Access.reduceMotion ? .easeOut(duration: 0.2)
                       : .spring(response: 0.5, dampingFraction: 0.84).delay(0.1 + Double(index) * 0.06), value: on)
    }
}

private extension View {
    func arrive(_ on: Bool, _ index: Int) -> some View { modifier(Arrive(on: on, index: index)) }
}
