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
}

extension IslandModel {
    /// Opens the workspace on a section (by default, the one that fits the island's primary activity).
    func openWorkspace(_ section: WorkspaceSection? = nil) {
        WorkspaceModel.shared.section = section ?? .fitting(primary)
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
        .animation(Access.reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9), value: ws.section)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(WorkspaceSection.allCases) { s in
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
                .keyboardShortcut(KeyEquivalent(Character("\((WorkspaceSection.allCases.firstIndex(of: s) ?? 0) + 1)")), modifiers: .command)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 148)
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
    @ObservedObject private var calendar = CalendarModel.shared
    @ObservedObject private var store = TaskStore.shared
    @ObservedObject private var stats = SystemStats.shared
    @ObservedObject private var battery = BatteryMonitor.shared
    @ObservedObject private var dev = DevStatus.shared

    var body: some View {
        let next = calendar.events.first { $0.start > Date() || $0.isNow }
        let open = store.list(.today).filter(\.isOpen).count
        Grid(horizontalSpacing: FlowTone.Space.s, verticalSpacing: FlowTone.Space.s) {
            GridRow {
                ToneTile {
                    VStack(alignment: .leading, spacing: 6) {
                        ToneHeader(symbol: "dot.radiowaves.left.and.right", title: "Live", trailing: "\(center.live.count)")
                        if center.live.isEmpty {
                            Text("Nothing running").font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary)
                        } else {
                            ForEach(center.live.prefix(3), id: \.self) { k in
                                Label(k.rawValue.capitalized, systemImage: k.tabSymbol).font(FlowTone.body).foregroundStyle(FlowTone.ink)
                            }
                        }
                    }
                }
                ToneTile {
                    VStack(alignment: .leading, spacing: 6) {
                        ToneHeader(symbol: "calendar", title: "Next")
                        if let next {
                            Text(next.title).font(FlowTone.heading).foregroundStyle(FlowTone.ink).lineLimit(2)
                            Text(next.isNow ? "Now" : next.start.formatted(date: .omitted, time: .shortened))
                                .font(FlowTone.mono).foregroundStyle(FlowTone.accent)
                        } else {
                            Text("Nothing else today").font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary)
                        }
                    }
                }
                ToneTile {
                    VStack(alignment: .leading, spacing: 6) {
                        ToneHeader(symbol: "checklist", title: "Today")
                        LiveFigure(value: "\(open)", unit: open == 1 ? "task open" : "tasks open", size: 28)
                        Text("\(store.doneToday) done").font(FlowTone.mono).foregroundStyle(FlowTone.inkTertiary)
                    }
                }
                .onTapGesture { model.select(.tasks) }
            }
            GridRow {
                ToneTile {
                    VStack(alignment: .leading, spacing: 8) {
                        ToneHeader(symbol: "cpu", title: "Mac")
                        HStack(spacing: FlowTone.Space.m) {
                            mini("CPU", stats.cpu, FlowTone.accent)
                            mini("Memory", stats.memory, stats.pressure == .normal ? FlowTone.good : FlowTone.caution)
                            if battery.hasBattery { mini("Battery", Double(battery.level) / 100, battery.level <= 20 ? FlowTone.bad : FlowTone.good) }
                        }
                    }
                }
                .gridCellColumns(2)
                ToneTile {
                    VStack(alignment: .leading, spacing: 6) {
                        ToneHeader(symbol: "chevron.left.forwardslash.chevron.right", title: "Developer")
                        Text(dev.repos.isEmpty ? "No repositories seen yet" : "\(dev.repos.count) repos · \(dev.repos.reduce(0) { $0 + $1.changes }) changes")
                            .font(FlowTone.body).foregroundStyle(FlowTone.ink)
                        Text(dev.servers.isEmpty ? "No local servers" : "\(dev.servers.count) server\(dev.servers.count == 1 ? "" : "s") running")
                            .font(FlowTone.mono).foregroundStyle(FlowTone.inkTertiary)
                    }
                }
                .onTapGesture { WorkspaceModel.shared.section = .developer }
            }
        }
        .onAppear { SystemStats.shared.start(); DevStatus.shared.refresh() }
        .onDisappear { SystemStats.shared.stop() }
    }

    private func mini(_ label: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            ArcGauge(value: value, tint: tint, lineWidth: 4) {
                Text("\(Int((value * 100).rounded()))").font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(FlowTone.ink)
            }
            .frame(width: 40, height: 40)
            Text(label).font(FlowTone.label).foregroundStyle(FlowTone.inkSecondary)
        }
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
                    ToneHeader(symbol: "arrow.triangle.branch", title: "Repositories", trailing: dev.loading ? "Reading…" : nil)
                    if dev.repos.isEmpty {
                        Text("Repositories show up here once a Claude session works in one.")
                            .font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: FlowTone.Space.s) {
                            ForEach(dev.repos) { r in repo(r) }
                        }
                        .scrollTicks(pitch: 50)
                    }
                }
            }
            VStack(spacing: FlowTone.Space.s) {
                ToneTile {
                    VStack(alignment: .leading, spacing: 6) {
                        ToneHeader(symbol: "server.rack", title: "Local servers", trailing: "\(dev.servers.count)")
                        if dev.servers.isEmpty {
                            Text("Nothing listening on a development port").font(FlowTone.body).foregroundStyle(FlowTone.inkTertiary)
                        }
                        ForEach(dev.servers.prefix(4)) { s in
                            HStack(spacing: FlowTone.Space.s) {
                                Circle().fill(FlowTone.good).frame(width: 6, height: 6)
                                Text(verbatim: ":\(s.port)").font(FlowTone.mono).foregroundStyle(FlowTone.ink)
                                Text(s.process).font(FlowTone.label).foregroundStyle(FlowTone.inkSecondary).lineLimit(1)
                                Spacer(minLength: 0)
                                if let url = s.url {
                                    Button("Open") { NSWorkspace.shared.open(url) }
                                        .buttonStyle(.plain).font(FlowTone.label).foregroundStyle(FlowTone.accent)
                                }
                            }
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
                TintPill(title: "Search Apps and Files", symbol: "magnifyingglass", tint: FlowTone.accent) { model.openSearch() }
            }
            Spacer(minLength: 0)
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
        VStack(alignment: .leading, spacing: FlowTone.Space.s) {
            ToneTile {
                VStack(alignment: .leading, spacing: 10) {
                    toggle("Haptic feedback", "Ticks under your fingers as you scroll and move things", $prefs.haptics)
                    toggle("Clipboard history", "Keep what you copy, on this Mac only", $prefs.clipboardEnabled)
                    toggle("Images in clipboard history", "Screenshots and copied pictures too", $prefs.clipboardImages)
                    toggle("Claude sessions", "Show Claude Code working and waiting", $prefs.claude)
                    toggle("Flow suggestions", "Let Flow offer the next step", $prefs.brainSuggestions)
                    toggle("Weather", "Beside the notch on Home", $prefs.weatherEnabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            TintPill(title: "All Settings…", symbol: "gearshape", tint: FlowTone.accent) { WindowManager.shared.showSettings() }
            Spacer(minLength: 0)
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
