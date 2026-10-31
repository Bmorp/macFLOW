import SwiftUI

/// The Smart Workspace: the island at its largest, for a minute of real work — what's happening, the Mac's health,
/// devices, the clipboard, your repositories and servers, Flow, and settings. Seven sections in a slim sidebar; it
/// opens on the one that fits where you came from (Claude → Developer, music → Devices).
enum WorkspaceSection: String, CaseIterable, Identifiable {
    case overview, system, devices, clipboard, developer, intelligence, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .system: "System"
        case .devices: "Devices"
        case .clipboard: "Clipboard"
        case .developer: "Developer"
        case .intelligence: "Flow"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .system: "cpu"
        case .devices: "airpods"
        case .clipboard: "doc.on.clipboard"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .intelligence: "sparkle"
        case .settings: "gearshape"
        }
    }

    /// Where a live activity leads when the workspace opens from it.
    static func fitting(_ kind: ActivityKind?) -> WorkspaceSection {
        switch kind {
        case .claude, .custom: .developer
        case .nowPlaying, .call: .devices
        case .shelf: .clipboard
        default: .overview
        }
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    static let shared = WorkspaceModel()
    @Published var section: WorkspaceSection = .overview

    /// The sections on show: Overview and Settings always, the rest unless hidden in Settings.
    var visible: [WorkspaceSection] {
        let hidden = Set(Prefs.shared.hiddenWorkspaceSections)
        return WorkspaceSection.allCases.filter { $0 == .overview || $0 == .settings || !hidden.contains($0.rawValue) }
    }

    func step(_ delta: Int) {
        let all = visible
        guard let i = all.firstIndex(of: section) else { return }
        section = all[min(all.count - 1, max(0, i + delta))]
    }
}

extension IslandModel {
    /// Opens the workspace on a section (by default, the one that fits the island's primary activity).
    func openWorkspace(_ section: WorkspaceSection? = nil) {
        let ws = WorkspaceModel.shared
        if let section {
            ws.section = section
        } else {
            switch Prefs.shared.workspaceOpensOn {
            case 1: break                                 // where you left it
            case 2: ws.section = .overview
            default: ws.section = .fitting(primary)
            }
        }
        if !ws.visible.contains(ws.section) { ws.section = .overview }
        open(.workspace)
    }
}

struct WorkspacePlace: View {
    static let height: CGFloat = 404
    static let width: CGFloat = 760
    var model: IslandModel
    @ObservedObject private var ws = WorkspaceModel.shared
    @Environment(\.islandShowing) private var showing

    private var inset: CGFloat { IslandModel.expandedFlare + FlowTone.Space.m + 2 }

    var body: some View {
        let size = model.expandedSize(.workspace)
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: model.notch.width + 24)
                GlyphButton(symbol: "xmark", label: "Close", size: 11, tint: FlowTone.inkSecondary, hit: 26) { model.collapse() }
            }
            .frame(height: model.notch.height)
            .padding(.horizontal, inset)
            HStack(alignment: .top, spacing: FlowTone.Space.m) {
                sidebar
                Rectangle().fill(FlowTone.hairline).frame(width: 0.5).padding(.vertical, FlowTone.Space.hair)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(ws.section)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }
            .padding(.horizontal, inset)
            .padding(.top, FlowTone.Space.s)
            .padding(.bottom, FlowTone.Space.m)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(Access.reduceMotion ? nil : Motion.Token.content.animation, value: ws.section)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ws.visible) { s in
                let on = ws.section == s
                Button { ws.section = s } label: {
                    HStack(spacing: FlowTone.Space.s) {
                        Image(systemName: s.symbol).font(.system(size: 12, weight: .semibold)).frame(width: 18)
                        Text(s.title).font(FlowTone.title)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(on ? FlowTone.ink : FlowTone.inkSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: FlowTone.Radius.control, style: .continuous).fill(on ? FlowTone.raised : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .accessibilityAddTraits(on ? .isSelected : [])
                .keyboardShortcut(KeyEquivalent(Character("\(((ws.visible.firstIndex(of: s) ?? 0) + 1) % 10)")), modifiers: .command)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 148)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace sections")
    }

    @ViewBuilder private var content: some View {
        switch ws.section {
        case .overview: OverviewSection(model: model)
        case .system: SystemSection()
        case .devices: DevicesSection()
        case .clipboard: ClipboardSection()
        case .developer: DeveloperSection()
        case .intelligence: IntelligenceSection(model: model)
        case .settings: SettingsSection()
        }
    }
}

// MARK: - Overview

private struct OverviewSection: View {
    var model: IslandModel
    @ObservedObject private var center = ActivityCenter.shared
    @ObservedObject private var log = NoticeLog.shared
    @ObservedObject private var calendar = CalendarModel.shared
    @ObservedObject private var store = TaskStore.shared
    @ObservedObject private var stats = SystemStats.shared
    @ObservedObject private var battery = BatteryMonitor.shared

    var body: some View {
        HStack(alignment: .top, spacing: FlowTone.Space.s) {
            VStack(spacing: FlowTone.Space.s) {
                activities
                notifications
            }
            VStack(spacing: FlowTone.Space.s) {
                next
                today
                mac
            }
            .frame(width: 210)
        }
        .onAppear { SystemStats.shared.start() }
        .onDisappear { SystemStats.shared.stop() }
    }

    // The activity stack in full: each live activity with its value, progress and actions.
    private var activities: some View {
        ToneTile {
            VStack(alignment: .leading, spacing: FlowTone.Space.s) {
                ToneHeader(symbol: "dot.radiowaves.left.and.right", title: "Activities", trailing: center.live.isEmpty ? nil : "\(center.live.count) live")
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let snaps = center.live.compactMap { $0.snapshot(now: ctx.date) }
                    if snaps.isEmpty {
                        Text("Nothing running. Timers, downloads, calls, music and builds show up here.")
                            .font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 2) {
                        ForEach(snaps.prefix(4)) { s in activityRow(s) }
                    }
                }
            }
        }
    }

    private func activityRow(_ s: ActivitySnapshot) -> some View {
        HStack(spacing: FlowTone.Space.s) {
            ZStack {
                if let p = s.progress { ArcGauge(value: p, tint: s.tint, lineWidth: 2.5, sweep: 1) }
                Image(systemName: s.symbol).font(.system(size: s.progress == nil ? 12 : 9, weight: .bold)).foregroundStyle(s.tint)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(FlowTone.title).foregroundStyle(FlowTone.ink).lineLimit(1)
                Text(s.detail).font(.system(size: 11)).foregroundStyle(FlowTone.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: FlowTone.Space.s)
            if !s.value.isEmpty { Text(s.value).font(FlowTone.mono).foregroundStyle(s.tint).contentTransition(.numericText()) }
            if let p = s.primary {
                Button { p.run() } label: {
                    Image(systemName: p.symbol ?? "arrow.up.forward").font(.system(size: 11, weight: .bold)).foregroundStyle(FlowTone.ink)
                        .frame(width: 26, height: 26).background(Circle().fill(FlowTone.raised))
                }
                .buttonStyle(PressStyle(scale: 0.92))
                .help(p.title)
                .accessibilityLabel(p.title)
            }
        }
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture { model.select(.activity(s.kind)) }
        .contextMenu { ForEach(s.secondary) { a in Button(a.title) { a.run() } } }
    }

    // What the island told you, grouped by where it came from; what waited while you focused is marked.
    private var notifications: some View {
        ToneTile {
            VStack(alignment: .leading, spacing: FlowTone.Space.s) {
                HStack {
                    ToneHeader(symbol: "bell", title: "Notifications",
                               trailing: log.heldCount > 0 ? "\(log.heldCount) while you focused" : nil, tint: log.heldCount > 0 ? FlowTone.accent : FlowTone.inkSecondary)
                    if !log.grouped.isEmpty {
                        Button("Clear") { withAnimation(Motion.Token.content.animation) { log.clearAll() } }
                            .buttonStyle(.plain).font(FlowTone.label).foregroundStyle(FlowTone.inkSecondary)
                    }
                }
                if log.grouped.isEmpty {
                    Text("Nothing yet. Finished downloads, Claude, meetings and devices are kept here, so nothing is lost while the island is busy or you're focusing.")
                        .font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: FlowTone.Space.s) {
                        ForEach(log.grouped, id: \.group) { g in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.group.uppercased()).font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(FlowTone.inkTertiary)
                                ForEach(g.notices.prefix(3)) { n in noticeRow(n) }
                                if g.notices.count > 3 {
                                    Text("\(g.notices.count - 3) more").font(FlowTone.mono).foregroundStyle(FlowTone.inkTertiary)
                                }
                            }
                        }
                    }
                    .scrollTicks(pitch: 30)
                }
            }
        }
    }

    private func noticeRow(_ n: Notice) -> some View {
        HStack(spacing: FlowTone.Space.s) {
            Image(systemName: n.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(n.tint).frame(width: 16)
            Text(n.title).font(n.importance == .important ? FlowTone.title : FlowTone.body).foregroundStyle(FlowTone.ink).lineLimit(1)
            Text(n.detail).font(.system(size: 11)).foregroundStyle(FlowTone.inkTertiary).lineLimit(1)
            if n.held { Circle().fill(FlowTone.accent).frame(width: 5, height: 5).help("Waited while you were focusing") }
            Spacer(minLength: FlowTone.Space.s)
            Text(n.date.formatted(date: .omitted, time: .shortened)).font(FlowTone.mono).foregroundStyle(FlowTone.inkTertiary)
            if let title = n.actionTitle, let action = n.action {
                Button(title) { action() }.buttonStyle(.plain).font(FlowTone.label).foregroundStyle(FlowTone.accent)
            }
            Button { withAnimation(Motion.Token.content.animation) { log.dismiss(n.id) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(FlowTone.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .frame(height: 26)
    }

    private var next: some View {
        let next = calendar.events.first { $0.start > Date() || $0.isNow }
        return ToneTile {
            VStack(alignment: .leading, spacing: 6) {
                ToneHeader(symbol: "calendar", title: "Next")
                if let next {
                    Text(next.title).font(FlowTone.title).foregroundStyle(FlowTone.ink).lineLimit(2)
                    Text(next.isNow ? "Now" : next.start.formatted(date: .omitted, time: .shortened)).font(FlowTone.mono).foregroundStyle(FlowTone.accent)
                } else {
                    Text("Nothing else today").font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var today: some View {
        let open = store.list(.today).filter(\.isOpen).count
        return ToneTile {
            VStack(alignment: .leading, spacing: 4) {
                ToneHeader(symbol: "checklist", title: "Today", trailing: "\(store.doneToday) done")
                LiveFigure(value: "\(open)", unit: open == 1 ? "task open" : "tasks open", size: 24)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onTapGesture { model.select(.tasks) }
    }

    private var mac: some View {
        ToneTile {
            VStack(alignment: .leading, spacing: 8) {
                ToneHeader(symbol: "cpu", title: "Mac")
                HStack(spacing: FlowTone.Space.s) {
                    mini("CPU", stats.cpu, FlowTone.accent)
                    mini("Mem", stats.memory, stats.pressure == .normal ? FlowTone.good : FlowTone.caution)
                    if battery.hasBattery { mini("Batt", Double(battery.level) / 100, battery.level <= 20 ? FlowTone.bad : FlowTone.good) }
                }
            }
        }
        .onTapGesture { WorkspaceModel.shared.section = .system }
    }

    private func mini(_ label: String, _ value: Double, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            ArcGauge(value: value, tint: tint, lineWidth: 3.5) {
                Text("\(Int((value * 100).rounded()))").font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(FlowTone.ink)
            }
            .frame(width: 38, height: 38)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(FlowTone.inkTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Mem": "Memory", "Batt": "Battery"][label] ?? label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

// MARK: - System

private struct SystemSection: View {
    @ObservedObject private var stats = SystemStats.shared
    @ObservedObject private var battery = BatteryMonitor.shared

    var body: some View {
        Grid(horizontalSpacing: FlowTone.Space.s, verticalSpacing: FlowTone.Space.s) {
            GridRow {
                ToneTile {
                    VStack(alignment: .leading, spacing: 8) {
                        ToneHeader(symbol: "cpu", title: "CPU", trailing: "\(ProcessInfo.processInfo.activeProcessorCount) cores")
                        LiveFigure(value: "\(Int((stats.cpu * 100).rounded()))", unit: "%", size: 30)
                        BarSpark(values: padded(stats.cpuHistory), tint: FlowTone.accent, highlight: stats.cpuHistory.isEmpty ? nil : SystemStats.historyLength - 1, maxBar: 3)
                            .frame(height: 30)
                    }
                }
                ToneTile {
                    VStack(alignment: .leading, spacing: 8) {
                        ToneHeader(symbol: "memorychip", title: "Memory", trailing: pressureWord, tint: pressureTint)
                        LiveFigure(value: String(format: "%.1f", Double(stats.memoryTotal) * stats.memory / 1_073_741_824),
                                   unit: "of \(Int(Double(stats.memoryTotal) / 1_073_741_824)) GB", size: 30)
                        LiveTrack(fraction: stats.memory, tint: pressureTint)
                    }
                }
                ToneTile {
                    VStack(alignment: .leading, spacing: 8) {
                        ToneHeader(symbol: battery.isCharging ? "bolt.fill" : "battery.75", title: "Battery",
                                   trailing: battery.hasBattery ? batteryNote : nil, tint: battery.isCharging ? FlowTone.good : FlowTone.inkSecondary)
                        if battery.hasBattery {
                            HStack(spacing: FlowTone.Space.m) {
                                LiveFigure(value: "\(battery.level)", unit: "%", size: 30)
                                Spacer(minLength: 0)
                                ArcGauge(value: Double(battery.level) / 100, tint: battery.level <= 20 ? FlowTone.bad : FlowTone.good, lineWidth: 5)
                                    .frame(width: 44, height: 44)
                            }
                        } else {
                            Text("This Mac has no battery").font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary)
                        }
                    }
                }
            }
            GridRow {
                ToneTile {
                    VStack(alignment: .leading, spacing: 8) {
                        ToneHeader(symbol: "internaldrive", title: "Storage")
                        LiveFigure(value: "\(stats.diskFree / 1_000_000_000)", unit: "GB free", size: 30)
                        LiveTrack(fraction: stats.disk, tint: stats.disk > 0.9 ? FlowTone.caution : FlowTone.accent,
                                  trailing: stats.diskTotal > 0 ? "\(stats.diskTotal / 1_000_000_000) GB" : nil)
                    }
                }
                ToneTile {
                    VStack(alignment: .leading, spacing: 8) {
                        ToneHeader(symbol: "network", title: "Network")
                        HStack(alignment: .firstTextBaseline, spacing: FlowTone.Space.m) {
                            Label(SystemStats.rate(stats.netIn), systemImage: "arrow.down").font(FlowTone.mono).foregroundStyle(FlowTone.ink)
                            Label(SystemStats.rate(stats.netOut), systemImage: "arrow.up").font(FlowTone.mono).foregroundStyle(FlowTone.inkSecondary)
                        }
                        .padding(.top, 6)
                        BarSpark(values: normalised(padded(stats.netHistory)), tint: FlowTone.accent, maxBar: 3)
                            .frame(height: 30)
                    }
                }
                ToneTile {
                    VStack(alignment: .leading, spacing: 8) {
                        ToneHeader(symbol: "thermometer.medium", title: "Thermal")
                        Text(thermalWord).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(thermalTint)
                        Text("As macOS reports it. Mac Flow eases its own effects when warm.")
                            .font(.system(size: 11)).foregroundStyle(FlowTone.inkTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { SystemStats.shared.start() }
        .onDisappear { SystemStats.shared.stop() }
    }

    private func padded(_ v: [Double]) -> [Double] { Array(repeating: 0, count: max(0, SystemStats.historyLength - v.count)) + v }
    private func normalised(_ v: [Double]) -> [Double] { let top = max(v.max() ?? 0, 1); return v.map { $0 / top } }

    private var pressureWord: String { switch stats.pressure { case .normal: "Normal"; case .warning: "Elevated"; case .critical: "Critical" } }
    private var pressureTint: Color { switch stats.pressure { case .normal: FlowTone.good; case .warning: FlowTone.caution; case .critical: FlowTone.bad } }
    private var thermalWord: String {
        switch stats.thermal { case .nominal: "Cool"; case .fair: "Warm"; case .serious: "Hot"; case .critical: "Critical"; @unknown default: "—" }
    }
    private var thermalTint: Color {
        switch stats.thermal { case .nominal: FlowTone.good; case .fair: FlowTone.caution; default: FlowTone.bad }
    }
    private var batteryNote: String {
        if battery.isCharging { return "Charging" }
        if let m = battery.minutesRemaining, m > 0 { return "\(m / 60)h \(m % 60)m left" }
        return battery.onAC ? "On power" : "On battery"
    }
}

// MARK: - Devices

private struct DevicesSection: View {
    @ObservedObject private var audio = AudioDevices.shared
    @State private var bluetooth: [BluetoothMonitor.Device] = []

    var body: some View {
        HStack(alignment: .top, spacing: FlowTone.Space.s) {
            ToneTile {
                VStack(alignment: .leading, spacing: FlowTone.Space.s) {
                    ToneHeader(symbol: "speaker.wave.2", title: "Output")
                    ForEach(audio.outputs) { d in
                        row(d.name, d.symbol, on: d.id == audio.output) { audio.useOutput(d) }
                    }
                    ToneHeader(symbol: "mic", title: "Input", trailing: audio.inputMuted ? "Muted" : nil).padding(.top, FlowTone.Space.s)
                    ForEach(audio.inputs) { d in
                        row(d.name, "mic", on: d.id == audio.input) { audio.useInput(d) }
                    }
                }
            }
            ToneTile {
                VStack(alignment: .leading, spacing: FlowTone.Space.s) {
                    ToneHeader(symbol: "dot.radiowaves.right", title: "Bluetooth")
                    if bluetooth.isEmpty {
                        Text("No Bluetooth devices connected").font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary)
                        TintPill(title: "Bluetooth Settings…", symbol: "dot.radiowaves.right", tint: FlowTone.accent) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
                        }
                    }
                    ForEach(bluetooth, id: \.name) { d in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(d.name, systemImage: d.symbol).font(FlowTone.title).foregroundStyle(FlowTone.ink)
                            HStack(spacing: FlowTone.Space.m) {
                                if let l = d.left { level(l, "L") }
                                if let r = d.right { level(r, "R") }
                                if let c = d.caseLevel { level(c, "Case") }
                                if d.left == nil, d.right == nil, let s = d.single { level(s, "") }
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
            }
        }
        .onAppear { audio.reload(); bluetooth = RenderMode.snapshot ? [] : BluetoothMonitor.connectedDevices() }
    }

    private func row(_ name: String, _ symbol: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: FlowTone.Space.s) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 18).foregroundStyle(on ? FlowTone.accent : FlowTone.inkSecondary)
                Text(name).font(FlowTone.body).foregroundStyle(FlowTone.ink).lineLimit(1)
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(FlowTone.accent) }
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func level(_ v: Int, _ label: String) -> some View {
        VStack(spacing: 3) {
            ArcGauge(value: Double(v) / 100, tint: v <= 15 ? FlowTone.bad : v <= 30 ? FlowTone.caution : FlowTone.good, lineWidth: 3.5) {
                Text("\(v)").font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(FlowTone.ink)
            }
            .frame(width: 38, height: 38)
            if !label.isEmpty { Text(label.uppercased()).font(DS.Kit.eyebrow).foregroundStyle(FlowTone.inkTertiary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["L": "Left", "R": "Right", "Case": "Case", "": "Battery"][label] ?? label)
        .accessibilityValue("\(v) percent")
    }
}

// MARK: - Clipboard

private struct ClipboardSection: View {
    @ObservedObject private var history = ClipboardHistory.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var query = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable { case all = "All", pinned = "Pinned", text = "Text", links = "Links", images = "Images", files = "Files" }

    private var items: [ClipItem] {
        history.items.filter { item in
            let kind: Bool = switch filter {
            case .all: true
            case .pinned: item.pinned
            case .text: item.kind == .text && item.flavor != .link
            case .links: item.flavor == .link
            case .images: item.kind == .image
            case .files: item.kind == .files
            }
            return kind && (query.isEmpty || item.text.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        if !prefs.clipboardEnabled {
            ToneTile {
                VStack(alignment: .leading, spacing: FlowTone.Space.s) {
                    ToneHeader(symbol: "doc.on.clipboard", title: "Clipboard history is off")
                    Text("When it's on, Mac Flow keeps what you copy on this Mac only, so you can find and paste it again. Passwords and other concealed items are never kept.")
                        .font(FlowTone.body).foregroundStyle(FlowTone.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    TintPill(title: "Keep Clipboard History", tint: FlowTone.accent, prominent: true) { prefs.clipboardEnabled = true }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: FlowTone.Space.s) {
                HStack(spacing: FlowTone.Space.s) {
                    Circle().fill(FlowTone.good).frame(width: 6, height: 6)
                    Text("Keeping what you copy, on this Mac only · \(history.items.count) items")
                        .font(.system(size: 11)).foregroundStyle(FlowTone.inkTertiary)
                    Spacer(minLength: 0)
                    Button("Clear Unpinned") { history.clearUnpinned() }
                        .buttonStyle(.plain).font(FlowTone.label).foregroundStyle(FlowTone.inkSecondary)
                    Button("Pause") { prefs.clipboardEnabled = false }
                        .buttonStyle(.plain).font(FlowTone.label).foregroundStyle(FlowTone.accent)
                }
                HStack(spacing: FlowTone.Space.s) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(FlowTone.inkTertiary)
                        TextField("", text: $query, prompt: Text("Search what you copied").foregroundColor(FlowTone.inkTertiary))
                            .textFieldStyle(.plain).font(FlowTone.body).foregroundStyle(FlowTone.ink)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: FlowTone.Radius.control, style: .continuous).fill(FlowTone.elevated))
                    ForEach(Filter.allCases, id: \.self) { f in
                        Button { filter = f } label: {
                            Text(f.rawValue).font(FlowTone.label)
                                .foregroundStyle(filter == f ? FlowTone.ink : FlowTone.inkSecondary)
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(Capsule().fill(filter == f ? FlowTone.raised : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in ClipRow(item: item) }
                    }
                    .scrollTicks(pitch: 38)
                }
                .overlay {
                    if items.isEmpty {
                        Text(query.isEmpty ? "Nothing here yet" : "No matches").font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary)
                    }
                }
            }
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    @State private var hover = false

    var body: some View {
        HStack(spacing: FlowTone.Space.s) {
            Group {
                if item.kind == .image, let img = ClipboardHistory.shared.image(for: item) {
                    Image(nsImage: img).resizable().scaledToFill().frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: FlowTone.Radius.chip, style: .continuous))
                } else {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(FlowTone.inkSecondary)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: FlowTone.Radius.chip, style: .continuous).fill(FlowTone.raised))
                }
            }
            Text(item.kind == .image ? "Image" : item.text.replacingOccurrences(of: "\n", with: " "))
                .font(item.flavor == .code ? FlowTone.mono : FlowTone.body)
                .foregroundStyle(FlowTone.ink).lineLimit(1)
            Spacer(minLength: FlowTone.Space.s)
            Text(item.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                .font(FlowTone.mono).foregroundStyle(FlowTone.inkTertiary).lineLimit(1)
            if hover || item.pinned {
                GlyphButton(symbol: item.pinned ? "pin.fill" : "pin", label: item.pinned ? "Unpin" : "Pin", size: 11,
                            tint: item.pinned ? FlowTone.accent : FlowTone.inkSecondary, hit: 24) { ClipboardHistory.shared.togglePin(item) }
            }
            if hover {
                GlyphButton(symbol: "trash", label: "Delete", size: 11, tint: FlowTone.inkSecondary, hit: 24) { ClipboardHistory.shared.delete(item) }
            }
        }
        .padding(.horizontal, FlowTone.Space.s)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: FlowTone.Radius.control, style: .continuous).fill(hover ? FlowTone.elevated : .clear))
        .contentShape(Rectangle())
        .onTapGesture { _ = ClipboardHistory.shared.use(item, paste: false); HapticEngine.shared.play(.copied) }
        .onHover { hover = $0 }
        .help("Click to copy")
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Copy") { _ = ClipboardHistory.shared.use(item, paste: false) }
        .accessibilityAction(named: item.pinned ? "Unpin" : "Pin") { ClipboardHistory.shared.togglePin(item) }
        .accessibilityAction(named: "Delete") { ClipboardHistory.shared.delete(item) }
    }

    private var symbol: String {
        switch item.flavor {
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .color: "paintpalette"
        case .email: "envelope"
        case .number: "number"
        case .files: "doc"
        default: "text.alignleft"
        }
    }
}

// MARK: - Developer

private struct DeveloperSection: View {
    @ObservedObject private var dev = DevStatus.shared
    @ObservedObject private var claude = ClaudeSessions.shared

    var body: some View {
        HStack(alignment: .top, spacing: FlowTone.Space.s) {
            ToneTile {
                VStack(alignment: .leading, spacing: FlowTone.Space.s) {
                    HStack {
                        ToneHeader(symbol: "arrow.triangle.branch", title: "Repositories", trailing: dev.loading ? "Reading…" : nil)
                        GlyphButton(symbol: "plus", label: "Watch a Repository", size: 11, tint: FlowTone.inkSecondary, hit: 22) { dev.chooseRepository() }
                    }
                    if dev.repos.isEmpty {
                        Text("Choose a project folder, or start a Claude session in one: its branch, changes and last commit show here.")
                            .font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary).fixedSize(horizontal: false, vertical: true)
                        TintPill(title: "Add Repository…", symbol: "folder.badge.plus", tint: FlowTone.accent) { dev.chooseRepository() }
                    }
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: FlowTone.Space.s) {
                            ForEach(dev.repos) { r in repo(r) }
                            if dev.github == .ready, !dev.runs.isEmpty {
                                Text("CI AND DEPLOYMENTS").font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking)
                                    .foregroundStyle(FlowTone.inkTertiary).padding(.top, FlowTone.Space.s)
                                ForEach(dev.runs.prefix(5)) { r in runRow(r) }
                            }
                        }
                        .scrollTicks(pitch: 50)
                    }
                }
            }
            VStack(spacing: FlowTone.Space.s) {
                ToneTile {
                    VStack(alignment: .leading, spacing: 6) {
                        ToneHeader(symbol: "server.rack", title: "Running locally", trailing: "\(dev.servers.count + dev.containers.count)")
                        if dev.servers.isEmpty && dev.containers.isEmpty {
                            Text("Nothing listening on a development port").font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary)
                        }
                        ForEach(dev.servers.prefix(4)) { s in ServerRow(server: s) }
                        ForEach(dev.containers.prefix(3)) { c in
                            HStack(spacing: FlowTone.Space.s) {
                                Image(systemName: "shippingbox.fill").font(.system(size: 10)).foregroundStyle(FlowTone.accent)
                                Text(c.name).font(FlowTone.mono).foregroundStyle(FlowTone.ink).lineLimit(1)
                                Text(c.image).font(FlowTone.label).foregroundStyle(FlowTone.inkTertiary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .help(c.status + (c.ports.isEmpty ? "" : " · " + c.ports))
                        }
                        if dev.docker == .notRunning {
                            Text("Docker is installed but isn't running").font(.system(size: 11)).foregroundStyle(FlowTone.inkTertiary)
                        }
                    }
                }
                ToneTile {
                    VStack(alignment: .leading, spacing: 6) {
                        ToneHeader(symbol: "arrow.triangle.pull", title: "Reviews waiting")
                        switch dev.github {
                        case .unknown:
                            Text("Checking GitHub…").font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary)
                        case .notInstalled:
                            Text("Install the GitHub CLI (gh) to see pull requests waiting on you.").font(FlowTone.body)
                                .foregroundStyle(FlowTone.inkTertiary).fixedSize(horizontal: false, vertical: true)
                        case .signedOut:
                            Text("Run “gh auth login” in Terminal to connect GitHub.").font(FlowTone.body)
                                .foregroundStyle(FlowTone.inkTertiary).fixedSize(horizontal: false, vertical: true)
                        case .ready:
                            if dev.reviews.isEmpty {
                                Text("No reviews waiting on you").font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary)
                            }
                            ForEach(dev.reviews.prefix(3)) { pr in
                                Button { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(pr.title).font(FlowTone.body).foregroundStyle(FlowTone.ink).lineLimit(1)
                                        Text(verbatim: "\(pr.repo) #\(pr.number)").font(FlowTone.mono).foregroundStyle(FlowTone.inkTertiary).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                ToneTile {
                    VStack(alignment: .leading, spacing: 6) {
                        ToneHeader(symbol: "asterisk", title: "Claude", trailing: "\(claude.sessions.count)", tint: ClaudeSessions.tint)
                        if claude.sessions.isEmpty {
                            Text("No Claude sessions").font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary)
                        }
                        ForEach(claude.sessions.prefix(3)) { s in
                            HStack(spacing: FlowTone.Space.s) {
                                Circle().fill(s.state == .waiting ? ClaudeSessions.tint : s.state == .working ? FlowTone.good : FlowTone.inkTertiary)
                                    .frame(width: 6, height: 6)
                                Text(s.name).font(FlowTone.body).foregroundStyle(FlowTone.ink).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(s.state == .waiting ? "Needs you" : s.state == .working ? "Working" : "Idle")
                                    .font(FlowTone.mono).foregroundStyle(FlowTone.inkTertiary)
                            }
                        }
                    }
                }
            }
            .frame(width: 270)
        }
        .task {
            while !Task.isCancelled {
                DevStatus.shared.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func runRow(_ r: DevStatus.Run) -> some View {
        Button { if let u = URL(string: r.url) { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: FlowTone.Space.s) {
                Image(systemName: r.running ? "circle.dotted" : r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(r.running ? FlowTone.caution : r.passed ? FlowTone.good : FlowTone.bad)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.workflow).font(FlowTone.title).foregroundStyle(FlowTone.ink).lineLimit(1)
                    Text("\(r.repo.split(separator: "/").last.map(String.init) ?? r.repo) · \(r.branch)\(r.title.isEmpty ? "" : " · " + r.title)")
                        .font(.system(size: 11)).foregroundStyle(FlowTone.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(r.running ? "Running" : (r.updated.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) } ?? ""))
                    .font(FlowTone.mono).foregroundStyle(r.running ? FlowTone.caution : FlowTone.inkTertiary)
            }
        }
        .buttonStyle(.plain)
        .help("Open on GitHub")
    }

    private func repo(_ r: DevStatus.Repo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: FlowTone.Space.s) {
                Text(r.name).font(FlowTone.title).foregroundStyle(FlowTone.ink).lineLimit(1)
                Text(r.branch).font(FlowTone.mono).foregroundStyle(FlowTone.accent)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Capsule().fill(FlowTone.accent.opacity(0.14)))
                Spacer(minLength: 0)
                if r.ahead > 0 { Text("↑\(r.ahead)").font(FlowTone.mono).foregroundStyle(FlowTone.good) }
                if r.behind > 0 { Text("↓\(r.behind)").font(FlowTone.mono).foregroundStyle(FlowTone.caution) }
                Text(r.changes == 0 ? "clean" : "\(r.changes) changed").font(FlowTone.mono)
                    .foregroundStyle(r.changes == 0 ? FlowTone.inkTertiary : FlowTone.caution)
            }
            Text("\(r.lastCommit) · \(r.lastWhen)").font(.system(size: 11)).foregroundStyle(FlowTone.inkTertiary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: r.path)) }
        .help("Open in Finder")
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
            Button("Stop Watching") { DevStatus.shared.forget(r.path) }
        }
    }
}

private struct ServerRow: View {
    let server: DevStatus.Server
    @State private var hover = false

    var body: some View {
        HStack(spacing: FlowTone.Space.s) {
            Circle().fill(FlowTone.good).frame(width: 6, height: 6)
            Text(verbatim: ":\(server.port)").font(FlowTone.mono).foregroundStyle(FlowTone.ink)
            Text(server.process).font(FlowTone.label).foregroundStyle(FlowTone.inkSecondary).lineLimit(1)
            Spacer(minLength: 0)
            if hover {
                Button("Stop") { DevStatus.shared.stop(server) }
                    .buttonStyle(.plain).font(FlowTone.label).foregroundStyle(FlowTone.bad)
                    .help("Stop \(server.process) (asks first)")
            }
            if let url = server.url {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.plain).font(FlowTone.label).foregroundStyle(FlowTone.accent)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Intelligence

private struct IntelligenceSection: View {
    var model: IslandModel
    @State private var command = ""

    private let examples = ["Summarise my active work", "Show my running servers", "Find my latest downloaded PDF",
                            "Switch to focus mode", "What did I get done today?", "Show my connected devices"]

    var body: some View {
        VStack(alignment: .leading, spacing: FlowTone.Space.m) {
            HStack(spacing: FlowTone.Space.s) {
                FlowGlyph(size: 13)
                TextField("", text: $command, prompt: Text("Ask Flow, or tell it what to do").foregroundColor(FlowTone.inkTertiary))
                    .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(FlowTone.ink)
                    .onSubmit { send(command) }
                    .disabled(!Mind.shared.isAvailable)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: FlowTone.Radius.panel, style: .continuous).fill(FlowTone.elevated))
            .overlay(RoundedRectangle(cornerRadius: FlowTone.Radius.panel, style: .continuous).strokeBorder(FlowTone.hairline, lineWidth: 0.5))
            if Mind.shared.isAvailable {
                Text("TRY").font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(FlowTone.inkTertiary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: FlowTone.Space.s)], alignment: .leading, spacing: FlowTone.Space.s) {
                    ForEach(examples, id: \.self) { e in
                        Button { send(e) } label: {
                            Text(e).font(FlowTone.body).foregroundStyle(FlowTone.ink).lineLimit(1)
                                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: FlowTone.Radius.control, style: .continuous).fill(FlowTone.elevated))
                        }
                        .buttonStyle(PressStyle(scale: 0.98))
                    }
                }
                Text("Flow runs on this Mac. It reads what you allow in Settings › Flow, asks before anything that changes your files, and never runs commands it writes itself.")
                    .font(.system(size: 11)).foregroundStyle(FlowTone.inkTertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                ToneTile {
                    VStack(alignment: .leading, spacing: 6) {
                        ToneHeader(symbol: "sparkle", title: "Flow isn't available on this Mac yet")
                        Text(Mind.shared.unavailableReason).font(FlowTone.body).foregroundStyle(FlowTone.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: FlowTone.Space.s) {
                TintPill(title: "Today, Inbox and Brief", symbol: "rectangle.portrait.bottomhalf.inset.filled", tint: FlowTone.accent) { model.open(.sheet) }
                TintPill(title: "Search", symbol: "magnifyingglass", tint: FlowTone.accent) { model.openSearch() }
                Text("⌘K").font(FlowTone.mono).foregroundStyle(FlowTone.inkTertiary)
            }
        }
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        command = ""
        BrainAgent.shared.send(t)
        model.openBrain()
    }
}

// MARK: - Settings

private struct SettingsSection: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: FlowTone.Space.s) {
                group("General") {
                    toggle("Haptic feedback", "Ticks under your fingers as you scroll and move things", $prefs.haptics)
                    toggle("Reduce motion", "Springs become short fades", $prefs.motionReduced)
                }
                group("Notch") {
                    toggle("Open on hover", "Rest the pointer on the notch to open Home", $prefs.expandOnHover)
                    toggle("Pull down for the Workspace", "Off: Today, Inbox and Brief instead", $prefs.pullOpensWorkspace)
                }
                group("Notifications") {
                    toggle("Hold during focus and calls", "Only what's important interrupts", $prefs.quietDuringFocus)
                }
                group("Privacy") {
                    toggle("Clipboard history", "Keep what you copy, on this Mac only", $prefs.clipboardEnabled)
                    toggle("Flow suggestions", "Let Flow offer the next step", $prefs.brainSuggestions)
                }
                HStack(spacing: FlowTone.Space.s) {
                    TintPill(title: "All Settings…", symbol: "gearshape", tint: FlowTone.accent) { WindowManager.shared.showSettings() }
                    TintPill(title: "Privacy & Data…", symbol: "lock.shield", tint: FlowTone.accent) { WindowManager.shared.showSettings(page: .privacy) }
                }
            }
            .scrollTicks(pitch: 44)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        let rows = content()
        return VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking).foregroundStyle(FlowTone.inkTertiary)
            ToneTile(padding: 12) { VStack(alignment: .leading, spacing: 10) { rows } }
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggle(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: FlowTone.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(FlowTone.title).foregroundStyle(FlowTone.ink)
                Text(detail).font(.system(size: 11)).foregroundStyle(FlowTone.inkTertiary)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(FlowTone.accent)
        }
    }
}
