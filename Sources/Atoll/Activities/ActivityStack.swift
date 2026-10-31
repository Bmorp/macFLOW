import SwiftUI

/// The activity stack along the foot of Home: everything running that the hero above isn't already showing (a
/// download, a call, a build, the shelf, keep-awake), then work that finished and hasn't been seen (dismissible),
/// then your Claude sessions. One compact chip each: identity, the live value, a ring when there's progress.
/// Click a running one to open its page; click a finished one to act on it.
struct ActivityStack: View {
    var model: IslandModel
    let onLeave: () -> Void
    @ObservedObject private var center = ActivityCenter.shared
    @ObservedObject private var log = NoticeLog.shared
    @ObservedObject private var claude = ClaudeSessions.shared

    /// Activities the stack shows; timers, meetings and music are the hero's, Claude has its own chips.
    static let kinds: Set<ActivityKind> = [.download, .call, .custom, .shelf, .awake]

    @MainActor static var isEmpty: Bool {
        !HomeView.showsClaude && !ActivityCenter.shared.live.contains(where: kinds.contains) && NoticeLog.shared.completions().isEmpty
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(center.live.filter(Self.kinds.contains), id: \.self) { kind in
                        if let s = kind.snapshot(now: ctx.date) { LiveChip(snapshot: s) { model.select(.activity(kind)) } }
                    }
                    ForEach(log.completions(now: ctx.date).prefix(3)) { n in DoneChip(notice: n, onLeave: onLeave) }
                    if HomeView.showsClaude {
                        if center.live.contains(where: Self.kinds.contains) || !log.completions(now: ctx.date).isEmpty {
                            Rectangle().fill(DS.Ink.hairline).frame(width: 1, height: 18)
                        }
                        ClaudeStrip(onOpen: onLeave).fixedSize()
                    }
                }
                .padding(.vertical, 2)
            }
            .claimsHorizontalScroll("home.stack")
        }
    }
}

/// A running activity: its symbol (in a progress ring when it has one), title and live value.
private struct LiveChip: View {
    let snapshot: ActivitySnapshot
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                ZStack {
                    if let p = snapshot.progress {
                        ArcGauge(value: p, tint: snapshot.tint, lineWidth: 2, sweep: 1)
                    }
                    Image(systemName: snapshot.symbol).font(.system(size: snapshot.progress == nil ? 11 : 8, weight: .bold))
                        .foregroundStyle(snapshot.tint)
                }
                .frame(width: 18, height: 18)
                Text(snapshot.title).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Palette.label).lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                if !snapshot.value.isEmpty {
                    Text(snapshot.value).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(snapshot.tint)
                        .contentTransition(.numericText())
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(hover ? DS.Ink.wellHover : DS.Ink.well))
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .onHover { hover = $0 }
        .contextMenu {
            if let p = snapshot.primary { Button(p.title) { p.run() } }
            ForEach(snapshot.secondary) { a in Button(a.title) { a.run() } }
        }
        .help(snapshot.detail)
        .accessibilityLabel("\(snapshot.title), \(snapshot.value)")
        .accessibilityAction(named: "Open") { open() }
    }
}

/// Finished work that hasn't been seen: a check, what it was, and a way to act on it or let it go.
private struct DoneChip: View {
    let notice: Notice
    let onLeave: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: notice.symbol == "xmark.octagon.fill" ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notice.symbol == "xmark.octagon.fill" ? DS.Palette.red : DS.Palette.green)
            Text(notice.title).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Palette.label).lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            if hover {
                Button { withAnimation(Motion.Token.content.animation) { NoticeLog.shared.dismiss(notice.id) } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Ink.secondary)
                        .frame(width: 16, height: 16).background(Circle().fill(DS.Ink.wellHover))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(hover ? DS.Ink.wellHover : DS.Ink.well))
        .contentShape(Capsule())
        .onTapGesture {
            if let action = notice.action { action(); onLeave() }
            NoticeLog.shared.dismiss(notice.id)
        }
        .onHover { h in withAnimation(Motion.Token.hover.animation) { hover = h } }
        .help("\(notice.detail)\(notice.actionTitle.map { " · click to \($0.lowercased())" } ?? "")")
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Dismiss") { NoticeLog.shared.dismiss(notice.id) }
    }
}
