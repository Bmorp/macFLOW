import SwiftUI
import UniformTypeIdentifiers

// MARK: - Timer

enum TimerPresentation {
    static let brand = DS.Palette.orange

    struct Leading: View {
        let ns: Namespace.ID
        @ObservedObject private var timer = FocusTimer.shared
        var body: some View {
            ProgressRing(progress: timer.progress, tint: brand, lineWidth: 2.5)
                .frame(width: 17, height: 17)
                .overlay {
                    Image(systemName: timer.phase == .paused ? "pause.fill" : "timer")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(brand)
                }
        }
    }

    struct Trailing: View {
        let ns: Namespace.ID
        @ObservedObject private var timer = FocusTimer.shared
        var body: some View {
            Text(timer.clock)
                .font(DS.Typeface.compact)
                .foregroundStyle(DS.Ink.primary)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: timer.clock)
        }
    }

    struct Minimal: View {
        let diameter: CGFloat
        @ObservedObject private var timer = FocusTimer.shared
        var body: some View {
            ProgressRing(progress: timer.progress, tint: brand, lineWidth: 2.5)
                .frame(width: diameter - 14, height: diameter - 14)
                .overlay(Image(systemName: "timer").font(.system(size: 8, weight: .bold)).foregroundStyle(brand))
        }
    }

    /// FOCUS · ends 3:15 ········ 24:58 (dial ⏸) ×
    struct Expanded: View {
        var model: IslandModel
        let ns: Namespace.ID
        @ObservedObject private var timer = FocusTimer.shared

        var body: some View {
            let paused = timer.phase == .paused
            Instrument(notch: model.notch, width: model.expandedWidth) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: timer.label, dot: paused ? nil : brand)
                        Text(paused ? "Paused" : "Ends \(Date().addingTimeInterval(timer.remaining).formatted(date: .omitted, time: .shortened))")
                            .font(DS.Kit.meta)
                            .foregroundStyle(DS.Ink.secondary)
                    }
                    .islandReveal(0)
                    Spacer(minLength: 8)
                    Figure(value: timer.clock, size: 40, tint: paused ? DS.Ink.secondary : DS.Ink.primary, countsDown: true)
                        .accessibilityLabel("\(timer.clock) remaining")
                        .islandReveal(1)
                    Button { timer.togglePause() } label: {
                        Dial(fraction: timer.progress, tint: brand, diameter: 40) {
                            Image(systemName: paused ? "play.fill" : "pause.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(DS.Ink.primary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle())
                    .help(paused ? "Resume" : "Pause")
                    .accessibilityLabel(paused ? "Resume" : "Pause")
                    .islandReveal(2)
                    Ghost(symbol: "xmark", label: "Cancel Timer", size: 12, tint: DS.Ink.tertiary, hit: 28) { timer.stop() }
                }
            }
            .contextMenu {
                Button("Add 1 Minute") { timer.add(minutes: 1) }
                Button("Add 5 Minutes") { timer.add(minutes: 5) }
            }
        }
    }
}

// MARK: - Meeting

enum MeetingPresentation {
    static let brand = DS.Palette.green

    static func shortRelative(_ e: CalendarModel.Event) -> String {
        if e.isNow { return "Now" }
        let mins = max(1, Int((e.start.timeIntervalSinceNow / 60).rounded(.up)))
        return "\(mins) min"
    }

    struct Leading: View {
        var body: some View {
            Image(systemName: "video.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(brand)
        }
    }

    struct Trailing: View {
        @ObservedObject private var center = ActivityCenter.shared
        var body: some View {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                Text(center.meeting.map(shortRelative) ?? "")
                    .font(DS.Typeface.compact)
                    .foregroundStyle(DS.Ink.primary)
                    .contentTransition(.numericText())
            }
        }
    }

    struct Minimal: View {
        var body: some View {
            Image(systemName: "video.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(brand)
        }
    }

    /// ZOOM · 2:30–3:00 / Design Review ········ 5 min  [Join]
    struct Expanded: View {
        var model: IslandModel
        var event: CalendarModel.Event? = nil
        @ObservedObject private var center = ActivityCenter.shared

        var body: some View {
            let e = event ?? center.meeting
            VStack(spacing: 0) {
                row(e)
                // As an activity (not the "starting soon" alert), the companion strip: time left, agenda, notes.
                if event == nil, MeetingCompanion.shared.showsStrip { MeetingCompanionStrip(model: model) }
            }
            .frame(width: model.expandedWidth, alignment: .top)
        }

        private func row(_ e: CalendarModel.Event?) -> some View {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                Instrument(notch: model.notch, width: model.expandedWidth) {
                    HStack(spacing: 14) {
                        if let e {
                            VStack(alignment: .leading, spacing: 4) {
                                Eyebrow(text: eyebrow(e), dot: e.isNow ? brand : nil)
                                MarqueeText(text: e.title, font: DS.Kit.titleLarge, color: DS.Ink.primary)
                            }
                            .islandReveal(0)
                            Spacer(minLength: 8)
                            countdown(e).islandReveal(1)
                            Group {
                                if e.meetingURL != nil {
                                    Pill(title: "Join", symbol: "video.fill") {
                                        CalendarModel.shared.open(e)
                                        model.collapse()
                                    }
                                } else {
                                    Ghost(symbol: "arrow.up.forward", label: "Open in Calendar", size: 13, tint: DS.Ink.secondary) {
                                        CalendarModel.shared.open(e)
                                    }
                                }
                            }
                            .islandReveal(2)
                        }
                    }
                }
            }
        }

        @ViewBuilder private func countdown(_ e: CalendarModel.Event) -> some View {
            if e.isNow {
                Figure(value: "Now", size: 28, tint: brand)
            } else {
                let mins = max(1, Int((e.start.timeIntervalSinceNow / 60).rounded(.up)))
                if mins < 60 {
                    Figure(value: "\(mins)", unit: "min", size: 32)
                } else {
                    Figure(value: e.start.formatted(date: .omitted, time: .shortened), size: 24)
                }
            }
        }

        private func eyebrow(_ e: CalendarModel.Event) -> String {
            var parts: [String] = []
            if let host = e.meetingURL?.host?.replacingOccurrences(of: "www.", with: "") {
                parts.append(host.contains("zoom") ? "Zoom" : host.contains("meet.google") ? "Meet" : host.contains("teams") ? "Teams" : host.contains("facetime") ? "FaceTime" : host)
            }
            parts.append(e.isNow ? CalendarModel.relative(e) : CalendarModel.timeRange(e))
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: - Download

enum DownloadPresentation {
    static let brand = DS.Palette.blue

    static func percent(_ a: DownloadsWatcher.Active?) -> String {
        guard let a else { return "" }
        if let p = a.progress { return "\(Int(p * 100))%" }
        return DownloadsWatcher.formatBytes(a.bytes)
    }

    struct Ring: View {
        var progress: Double?
        var size: CGFloat
        var body: some View {
            ProgressRing(progress: progress, tint: brand, lineWidth: 2.5)
                .frame(width: size, height: size)
                .overlay(Image(systemName: "arrow.down").font(.system(size: size * 0.42, weight: .heavy)).foregroundStyle(brand))
        }
    }

    struct Leading: View {
        @ObservedObject private var downloads = DownloadsWatcher.shared
        var body: some View { Ring(progress: downloads.active?.progress, size: 17) }
    }

    struct Trailing: View {
        @ObservedObject private var downloads = DownloadsWatcher.shared
        var body: some View {
            Text(percent(downloads.active))
                .font(DS.Typeface.compact)
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
    }

    struct Minimal: View {
        let diameter: CGFloat
        @ObservedObject private var downloads = DownloadsWatcher.shared
        var body: some View { Ring(progress: downloads.active?.progress, size: diameter - 14) }
    }

    /// DOWNLOADING · 3.4 GB / Xcode_27.xip ···· 62 % 📁, a hairline of progress beneath
    struct Expanded: View {
        var model: IslandModel
        @ObservedObject private var downloads = DownloadsWatcher.shared

        var body: some View {
            let a = downloads.active
            Instrument(notch: model.notch, width: model.expandedWidth, height: ActivityKind.download.rowHeight) {
                VStack(spacing: 6) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(text: eyebrow(a))
                            Text(a?.name ?? "Downloading")
                                .font(DS.Kit.title)
                                .foregroundStyle(DS.Ink.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .islandReveal(0)
                        Spacer(minLength: 8)
                        if let p = a?.progress {
                            Figure(value: "\(Int(p * 100))", unit: "%", size: 30).islandReveal(1)
                        }
                        Ghost(symbol: "folder", label: "Show Downloads", size: 14, tint: DS.Ink.secondary) {
                            if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first { NSWorkspace.shared.open(url) }
                        }
                        .islandReveal(2)
                    }
                    ProgressLine(fraction: a?.progress ?? 0.04, tint: brand)
                }
            }
        }

        private func eyebrow(_ a: DownloadsWatcher.Active?) -> String {
            guard let a else { return "Downloading" }
            if let p = a.progress, p > 0 { return "Downloading · \(DownloadsWatcher.formatBytes(Int64(Double(a.bytes) / p)))" }
            return "Downloading · \(DownloadsWatcher.formatBytes(a.bytes))"
        }
    }
}

// MARK: - Call

enum CallPresentation {
    static let brand = DS.Palette.green

    static func elapsed(_ since: Date?, now: Date = Date()) -> String {
        guard let since else { return "" }
        return max(0, now.timeIntervalSince(since)).clock
    }

    struct Leading: View {
        @ObservedObject private var center = ActivityCenter.shared
        var body: some View {
            Image(systemName: center.call?.camera == true ? "video.fill" : "phone.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(brand)
        }
    }

    struct Trailing: View {
        @ObservedObject private var center = ActivityCenter.shared
        @ObservedObject private var companion = MeetingCompanion.shared
        var body: some View {
            HStack(spacing: 6) {
                // Notes being taken: red, so it's never in doubt.
                LiveDot(color: companion.isRecording ? DS.Palette.red : brand, size: 6)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsed(center.call?.since, now: ctx.date))
                        .font(DS.Typeface.compact)
                        .foregroundStyle(DS.Ink.primary)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    struct Minimal: View {
        let diameter: CGFloat
        var body: some View {
            Image(systemName: "phone.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(brand)
        }
    }

    /// FACETIME · CAMERA ON / On a call ···· waveform  12:39  ↗
    struct Expanded: View {
        var model: IslandModel
        @ObservedObject private var center = ActivityCenter.shared
        @ObservedObject private var audio = AudioActivity.shared
        @Environment(\.islandShowing) private var showing

        @ObservedObject private var companion = MeetingCompanion.shared

        var body: some View {
            VStack(spacing: 0) {
                row
                if companion.showsStrip { MeetingCompanionStrip(model: model) }
            }
            .frame(width: model.expandedWidth, alignment: .top)
        }

        private var row: some View {
            let call = center.call
            return Instrument(notch: model.notch, width: model.expandedWidth) {
                HStack(spacing: 14) {
                    if let icon = call?.app.icon {
                        IconImage(image: icon, size: 30).islandReveal(0)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "\(call?.app.name ?? "Call") · \(call?.camera == true ? "Camera on" : "Mic on")",
                                dot: call?.camera == true ? brand : DS.Palette.orange)
                        Text("On a call").font(DS.Kit.title).foregroundStyle(DS.Ink.primary)
                    }
                    .islandReveal(0)
                    Spacer(minLength: 8)
                    Waveform(tint: DS.Ink.secondary, active: audio.micInUse, bars: 5, height: 18, barWidth: 2.5)
                        .islandReveal(1)
                    TimelineView(PeriodicTimelineSchedule.seconds(showing)) { ctx in
                        Figure(value: elapsed(call?.since, now: ctx.date), size: 30)
                    }
                    .islandReveal(1)
                    Ghost(symbol: "arrow.up.forward", label: "Show \(call?.app.name ?? "Call")", size: 13, tint: DS.Ink.secondary) {
                        call?.app.activate()
                        model.collapse()
                    }
                    .islandReveal(2)
                }
            }
        }
    }
}

// MARK: - Custom (your tools)

enum CustomPresentation {
    struct Leading: View {
        @ObservedObject private var activity = CustomActivity.shared
        var body: some View {
            if let p = activity.current?.progress {
                ProgressRing(progress: p, tint: activity.current?.tint ?? DS.Palette.indigo, lineWidth: 2.5).frame(width: 17, height: 17)
            } else {
                Image(systemName: activity.current?.symbol ?? "hammer.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(activity.current?.tint ?? DS.Palette.indigo)
            }
        }
    }

    struct Trailing: View {
        @ObservedObject private var activity = CustomActivity.shared
        var body: some View {
            Text(activity.current?.progress.map { "\(Int($0 * 100))%" } ?? "")
                .font(DS.Typeface.compact)
                .foregroundStyle(DS.Ink.primary)
                .contentTransition(.numericText())
        }
    }

    struct Minimal: View {
        let diameter: CGFloat
        @ObservedObject private var activity = CustomActivity.shared
        var body: some View {
            ProgressRing(progress: activity.current?.progress, tint: activity.current?.tint ?? DS.Palette.indigo, lineWidth: 2.5)
                .frame(width: diameter - 14, height: diameter - 14)
        }
    }

    /// SOURCE · detail / Title ···· 24 %  (dial) ×
    struct Expanded: View {
        var model: IslandModel
        @ObservedObject private var activity = CustomActivity.shared

        var body: some View {
            let a = activity.current
            let tint = a?.tint ?? DS.Palette.indigo
            Instrument(notch: model.notch, width: model.expandedWidth) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: a?.detail ?? "In progress", dot: tint)
                        Text(a?.title ?? "").font(DS.Kit.title).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    }
                    .islandReveal(0)
                    Spacer(minLength: 8)
                    if let p = a?.progress {
                        Figure(value: "\(Int(p * 100))", unit: "%", size: 30).islandReveal(1)
                        Dial(fraction: p, tint: tint, diameter: 26, lineWidth: 2.5) { EmptyView() }
                    } else {
                        ProgressRing(progress: nil, tint: tint, lineWidth: 2.5).frame(width: 22, height: 22)
                    }
                    Ghost(symbol: "xmark", label: "Dismiss", size: 11, tint: DS.Ink.tertiary, hit: 28) {
                        CustomActivity.shared.handle(URL(string: "atoll://clear")!)
                    }
                    .islandReveal(2)
                }
            }
        }
    }
}

// MARK: - Shelf

enum ShelfPresentation {
    static let brand = DS.Palette.cyan

    struct Leading: View {
        @ObservedObject private var shelf = ShelfModel.shared
        var body: some View {
            ZStack {
                ForEach(Array(shelf.items.prefix(2).enumerated().reversed()), id: \.element.id) { i, item in
                    IconImage(image: shelf.icon(for: item), size: 18)
                        .offset(x: CGFloat(i) * 7 - 3.5, y: CGFloat(i) * -1)
                }
            }
        }
    }

    struct Trailing: View {
        @ObservedObject private var shelf = ShelfModel.shared
        var body: some View {
            Text("\(shelf.items.count)")
                .font(DS.Typeface.compact)
                .foregroundStyle(DS.Ink.primary)
                .contentTransition(.numericText())
        }
    }

    struct Minimal: View {
        @ObservedObject private var shelf = ShelfModel.shared
        var body: some View {
            Text("\(shelf.items.count)").font(DS.Typeface.compact).foregroundStyle(DS.Ink.primary)
        }
    }

    /// File tiles you can drag out, then the actions for the selection.
    struct Expanded: View {
        var model: IslandModel
        @ObservedObject private var shelf = ShelfModel.shared

        var body: some View {
            VStack(spacing: 0) {
                Color.clear.frame(height: model.notch.height)
                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(shelf.items) { item in
                                ShelfTile(item: item, selected: shelf.selection.contains(item.id))
                            }
                        }
                    }
                    .islandReveal(0)
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 44)
                    VStack(spacing: 4) {
                        HStack(spacing: 2) {
                            GlyphButton(symbol: "dot.radiowaves.left.and.right", label: "AirDrop", size: 13) { shelf.airDrop(shelf.targets) }
                            GlyphButton(symbol: "square.and.arrow.up", label: "Share", size: 13) {
                                shelf.share(shelf.targets, in: IslandManager.shared.focusedContentView)
                            }
                        }
                        HStack(spacing: 2) {
                            GlyphButton(symbol: "doc.zipper", label: "Compress", size: 13) { shelf.zip(shelf.targets) { _ in Haptics.confirm() } }
                            GlyphButton(symbol: shelf.selection.isEmpty ? "trash" : "minus.circle", label: shelf.selection.isEmpty ? "Clear Shelf" : "Remove Selected",
                                        size: 13, tint: DS.Palette.secondary) {
                                if shelf.selection.isEmpty { shelf.clear() } else { shelf.targets.forEach(shelf.remove) }
                            }
                        }
                    }
                    .islandReveal(1)
                }
                .padding(.horizontal, IslandModel.expandedFlare + 14)
                .padding(.top, 2)
                .padding(.bottom, 14)
                .frame(height: ActivityKind.shelf.rowHeight)
            }
            .frame(width: model.expandedWidth, alignment: .top)
        }
    }

    struct ShelfTile: View {
        let item: ShelfItem
        let selected: Bool
        @ObservedObject private var shelf = ShelfModel.shared
        @State private var hover = false

        var body: some View {
            VStack(spacing: 3) {
                IconImage(image: shelf.icon(for: item), size: 40)
                    .scaleEffect(hover ? 1.06 : 1)
                Text(item.path.hasSuffix(".app") ? (item.name as NSString).deletingPathExtension : item.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Palette.label.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 58)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.35) : (hover ? DS.Palette.fill : .clear))
            )
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover = h } }
            .gesture(TapGesture(count: 2).onEnded { shelf.open(item) })
            .simultaneousGesture(TapGesture().onEnded {
                let flags = NSEvent.modifierFlags
                shelf.tap(item, extend: flags.contains(.command) || flags.contains(.shift))
            })
            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL) }
            .contextMenu {
                Button("Open") { shelf.open(item) }
                Button("Quick Look") { shelf.quickLook([item]) }
                Button("Show in Finder") { shelf.reveal([item]) }
                Button("Copy") { shelf.copyFiles([item]) }
                Divider()
                Button("Remove from Shelf") { shelf.remove(item) }
            }
            .help(item.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        }
    }
}

// MARK: - Keep Awake

enum AwakePresentation {
    static let brand = DS.Palette.yellow

    static func elapsed(since: Date?) -> String {
        guard let since else { return "On" }
        let m = Int(Date().timeIntervalSince(since) / 60)
        return m < 1 ? "On" : (m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m")
    }

    struct Leading: View {
        var body: some View {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(brand)
        }
    }

    struct Trailing: View {
        @ObservedObject private var awake = KeepAwake.shared
        var body: some View {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(elapsed(since: awake.since)).font(DS.Typeface.compact).foregroundStyle(DS.Ink.primary)
            }
        }
    }

    struct Minimal: View {
        var body: some View {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(brand)
        }
    }

    /// KEEP AWAKE / Your Mac won't sleep ···· 1h 20m  [Turn Off]
    struct Expanded: View {
        var model: IslandModel
        @ObservedObject private var awake = KeepAwake.shared

        var body: some View {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Instrument(notch: model.notch, width: model.expandedWidth) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(text: "Keep Awake", dot: brand)
                            Text("Your Mac won’t go to sleep").font(DS.Kit.title).foregroundStyle(DS.Ink.primary)
                        }
                        .islandReveal(0)
                        Spacer(minLength: 8)
                        let e = AwakePresentation.elapsed(since: awake.since)
                        if e != "On" { Figure(value: e, size: 26).islandReveal(1) }
                        Pill(title: "Turn Off") { awake.disable() }.islandReveal(2)
                    }
                }
            }
        }
    }
}

/// Flow has something waiting: its star on one side, a soft pulse (or how many) on the other. Opening the island
/// shows it at the top of Home.
enum FlowPresentation {
    struct Leading: View {
        var body: some View { FlowGlyph(size: 11) }
    }

    struct Trailing: View {
        @ObservedObject private var inbox = FlowInbox.shared
        var body: some View {
            if inbox.items.count > 1 {
                Text("\(inbox.items.count)").font(DS.Typeface.compact).foregroundStyle(BrainStyle.tint)
            } else {
                LiveDot(color: BrainStyle.tint, size: 5)
            }
        }
    }

    struct Expanded: View {
        var model: IslandModel
        @ObservedObject private var inbox = FlowInbox.shared
        var body: some View {
            VStack(spacing: 0) {
                Color.clear.frame(height: model.notch.height)
                if let item = inbox.top {
                    FlowInboxCard(item: item, count: inbox.items.count) { model.collapse() }
                        .padding(.horizontal, IslandModel.expandedFlare + 14)
                }
                Spacer(minLength: 0)
            }
            .frame(width: model.expandedWidth, alignment: .top)
        }
    }
}
