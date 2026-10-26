import SwiftUI
import AppKit

extension WorkMode {
    /// One colour per kind of work, used only in the day strip and its legend.
    var color: Color {
        switch self {
        case .coding: Color(red: 0.42, green: 0.55, blue: 1.0)
        case .writing: Color(red: 0.98, green: 0.72, blue: 0.3)
        case .design: Color(red: 0.95, green: 0.45, blue: 0.7)
        case .meeting: Color(red: 0.3, green: 0.82, blue: 0.5)
        case .communicating: Color(red: 0.4, green: 0.8, blue: 0.9)
        case .research: Color(red: 0.65, green: 0.55, blue: 1.0)
        case .planning: Color(red: 1.0, green: 0.55, blue: 0.4)
        case .media: Color(red: 0.6, green: 0.6, blue: 0.65)
        case .reading: Color(red: 0.75, green: 0.68, blue: 0.55)
        case .other: Color(red: 0.5, green: 0.5, blue: 0.55)
        case .idle: Color(red: 0.3, green: 0.3, blue: 0.32)
        }
    }
}

/// Settings › Overview: what Atoll understands about your day, your projects, what's open, and your taste —
/// the Brain's working memory, made visible. Everything here is computed on this Mac.
struct OverviewPane: View {
    @ObservedObject private var model = InsightModel.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var claude = ClaudeSessions.shared
    @StateObject private var brief = BriefModel()

    private var insight: Insight { model.insight }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if prefs.brainLevel == BrainLevel.off.rawValue {
                    offNotice
                } else {
                    DayStrip(insight: insight)
                    briefCard
                    loopsSection
                    projectsSection
                    tasteSection
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.8)
                Text(insight.activeToday > 60 ? "\(BrainEngine.duration(insight.activeToday)) at work today" : "Your day starts here")
                    .font(.system(size: 26, weight: .semibold))
                if insight.activeToday > 60 {
                    let touched = insight.projects.filter { $0.today > 0 }.count
                    Text("\(BrainEngine.duration(insight.deepToday)) of deep work · \(touched) \(touched == 1 ? "project" : "projects") touched")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            BrainStatus(level: BrainLevel(rawValue: prefs.brainLevel) ?? .essentials, computing: model.computing) { model.refresh() }
        }
    }

    private var offNotice: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Flow is off").font(.headline)
                Text("Turn it on in Settings › Flow to see your day, your projects and what you left open. Everything stays on this Mac.")
                    .foregroundStyle(.secondary)
                Button("Open Flow Settings") { SettingsRouter.shared.page = .brain }
            }
        }
    }

    // MARK: Brief

    private var briefCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Brief", symbol: "sparkles")
                    Spacer()
                    if Mind.shared.isAvailable {
                        Button(brief.text.isEmpty ? "Write Today’s Brief" : "Refresh") { brief.write() }
                            .disabled(brief.writing)
                    }
                }
                if !Mind.shared.isAvailable {
                    Text(Mind.shared.unavailableReason).foregroundStyle(.secondary)
                } else if brief.writing && brief.text.isEmpty {
                    HStack(spacing: 8) { ThinkingDots(size: 18); Text("Thinking on this Mac…").foregroundStyle(.secondary) }
                } else if !brief.text.isEmpty {
                    Text(brief.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                } else {
                    Text("A short read of your day so far — what you worked on, what’s left open, what’s next.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Open loops

    @ViewBuilder private var loopsSection: some View {
        let loops = model.loops
        if !loops.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Open Loops", symbol: "circle.dashed")
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(loops.enumerated()), id: \.element.id) { i, loop in
                            if i > 0 { Divider().padding(.leading, 48) }
                            HStack(spacing: 12) {
                                Image(systemName: loop.symbol).frame(width: 24).foregroundStyle(loop.kind == .claude ? ClaudeSessions.tint : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(loop.title).font(.system(size: 13, weight: .medium))
                                    Text(loop.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if loop.action != .none {
                                    Button(loop.kind == .meeting ? "Join" : loop.kind == .claude ? "Open" : "Continue") {
                                        BrainEngine.shared.perform(loop.action)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }

    // MARK: Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Projects", symbol: "folder")
            if insight.projects.isEmpty {
                Card {
                    Text(prefs.brainLevel >= BrainLevel.context.rawValue
                         ? "Projects appear as Flow sees you work on them — from window titles and Claude sessions."
                         : "Turn on Context in Flow so it can tell projects apart, not just apps.")
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(insight.projects.prefix(8)) { p in ProjectCard(project: p, claude: claude.sessions.filter { $0.folder == p.name }) }
                }
            }
        }
    }

    // MARK: Taste

    @ViewBuilder private var tasteSection: some View {
        let t = insight.taste
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Taste", symbol: "music.note")
            Card {
                if t.plays < 3 {
                    Text("As you listen, Flow learns what you play — and what you play for each kind of work.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Most played").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(Array(t.topArtists.prefix(5).enumerated()), id: \.offset) { i, a in
                                HStack(spacing: 8) {
                                    Text("\(i + 1)").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.tertiary).frame(width: 14)
                                    Text(a.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(a.plays)").font(.system(size: 12, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("While you work").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            if t.byMode.isEmpty {
                                Text("Not enough yet.").foregroundStyle(.secondary)
                            }
                            ForEach(t.byMode.sorted { $0.value.count > $1.value.count }.prefix(3), id: \.key) { mode, artists in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: mode.symbol).foregroundStyle(mode.color).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(mode.label).font(.system(size: 12, weight: .medium))
                                        Text(artists.prefix(3).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            ListeningHours(hours: t.hours)
                            Text("\(t.plays) plays this month · skips \(Int(t.skipRate * 100))%\(t.topSource.map { " · mostly \($0)" } ?? "")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

private struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct SectionLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

private struct BrainStatus: View {
    let level: BrainLevel
    let computing: Bool
    let refresh: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(level == .off ? Color.secondary : Color.green).frame(width: 7, height: 7)
            Text(level == .off ? "Not observing" : "Observing · \(level.title)").font(.system(size: 12, weight: .medium))
            Text("·").foregroundStyle(.tertiary)
            Text(Mind.shared.isAvailable ? "On-device model ready" : "Rules only").font(.system(size: 12)).foregroundStyle(.secondary)
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").rotationEffect(.degrees(computing ? 180 : 0))
                    .animation(computing ? .linear(duration: 0.6).repeatForever(autoreverses: false) : .default, value: computing)
            }
            .buttonStyle(.borderless)
            .help("Recompute")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

/// Today, hour by hour: one segment per hour, coloured by its main kind of work, as tall as it was busy.
private struct DayStrip: View {
    let insight: Insight

    var body: some View {
        let start = 6, end = 24
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(start..<end, id: \.self) { h in
                    let slot = insight.hours[h]
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(slot.map { $0.mode.color } ?? Color.primary.opacity(0.07))
                            .frame(height: slot.map { 8 + 34 * $0.fraction } ?? 4)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .help(slot.map { "\(h):00 · \($0.mode.label) · \(Int($0.fraction * 60)) min" } ?? "\(h):00")
                }
            }
            HStack {
                ForEach([6, 9, 12, 15, 18, 21], id: \.self) { h in
                    Text(h == 12 ? "noon" : "\(h > 12 ? h - 12 : h)\(h >= 12 ? "pm" : "am")")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    if h != 21 { Spacer() }
                }
            }
            if !insight.modes.isEmpty {
                HStack(spacing: 14) {
                    ForEach(insight.modes.prefix(5), id: \.mode) { m in
                        HStack(spacing: 5) {
                            Circle().fill(m.mode.color).frame(width: 7, height: 7)
                            Text(m.mode.label).font(.system(size: 12))
                            Text(BrainEngine.duration(m.seconds)).font(.system(size: 12, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct ProjectCard: View {
    let project: Insight.Project
    let claude: [ClaudeSessions.Session]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: project.mode.symbol).foregroundStyle(project.mode.color)
                    Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if let s = claude.first(where: { $0.state != .idle }) {
                        HStack(spacing: 4) {
                            ClaudeGlyph(size: 11, spinning: false)
                            Text(s.state == .waiting ? "Needs you" : "Working").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(s.state == .waiting ? ClaudeSessions.tint : .secondary)
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    stat(BrainEngine.duration(project.today), "today")
                    stat(BrainEngine.duration(project.week), "this week")
                    stat("\(project.activeDays)", project.activeDays == 1 ? "day" : "days")
                }
                if let doc = project.documents.first {
                    Text(doc).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    ForEach(project.apps.prefix(4), id: \.self) { bundle in
                        if let icon = IconCache.app(bundleID: bundle) {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                    }
                    Text(project.today > 0 ? "Active today" : "Last \(InsightModel.ago(project.lastSeen))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Open") { BrainEngine.shared.perform(.openApps(project.apps)) }
                        .controlSize(.small)
                        .disabled(project.apps.isEmpty)
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct ListeningHours: View {
    let hours: [Int]
    var body: some View {
        let peak = max(1, hours.max() ?? 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { h in
                Capsule().fill(Color.primary.opacity(hours[h] == 0 ? 0.08 : 0.25 + 0.6 * Double(hours[h]) / Double(peak)))
                    .frame(width: 4, height: 3 + 18 * CGFloat(hours[h]) / CGFloat(peak))
            }
        }
        .frame(height: 22, alignment: .bottom)
        .help("When you listen, midnight to midnight")
    }
}

/// Today's brief, written by Apple's on-device model from the Brain's digest.
@MainActor
final class BriefModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var writing = false
    private var task: Task<Void, Never>?

    func write() {
        task?.cancel()
        text = ""
        writing = true
        let context = BrainEngine.shared.digest()
        task = Task { @MainActor in
            defer { writing = false }
            do {
                let prompt = "Write my brief for today in three or four short sentences: what I've worked on and for how long, what's still open, and the one thing to focus on next. Plain prose, no lists."
                for try await partial in Mind.shared.answer(prompt, context: context) { text = partial }
            } catch {
                text = error.localizedDescription
            }
        }
    }
}
