import SwiftUI
import AppKit
import ServiceManagement
import AVFoundation

/// Atoll's control panel: a sidebar of places, with an Overview of what the Brain understands at the top.
enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, general, permissions, brain, activities, search, widgets, standby, dock, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .general: "General"
        case .permissions: "Permissions"
        case .brain: "Flow"
        case .activities: "Live Activities"
        case .search: "Search"
        case .widgets: "Widgets"
        case .standby: "StandBy"
        case .dock: "Dock"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .general: "gearshape"
        case .permissions: "hand.raised"
        case .brain: "sparkles"
        case .activities: "capsule.inset.filled"
        case .search: "magnifyingglass"
        case .widgets: "rectangle.3.group"
        case .standby: "clock"
        case .dock: "dock.rectangle"
        case .about: "info.circle"
        }
    }

    static let sections: [(String?, [SettingsPage])] = [
        (nil, [.overview]),
        ("Mac Flow", [.general, .permissions, .brain, .activities, .search]),
        ("Extras", [.widgets, .standby, .dock]),
        (nil, [.about]),
    ]
}

@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var page: SettingsPage = .overview
}

private struct SettingsRoot: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { router.page }, set: { if let p = $0 { router.page = p } })) {
                ForEach(Array(SettingsPage.sections.enumerated()), id: \.offset) { _, section in
                    if let title = section.0 {
                        Section(title) { rows(section.1) }
                    } else {
                        Section { rows(section.1) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            detail
                .navigationTitle(router.page.title)
        }
        .frame(minWidth: 820, minHeight: 600)
    }

    private func rows(_ pages: [SettingsPage]) -> some View {
        ForEach(pages) { p in
            Group {
                if p == .brain {
                    // Flow's own symbol: the star from the Mac Flow mark.
                    Label { Text(p.title) } icon: { FlowStar().fill(BrainStyle.tint).frame(width: 15, height: 9) }
                } else {
                    Label(p.title, systemImage: p.symbol)
                }
            }
            .tag(p)
        }
    }

    @ViewBuilder private var detail: some View {
        switch router.page {
        case .overview: OverviewPane()
        case .general: GeneralPane()
        case .permissions: PermissionsPane()
        case .brain: BrainPane()
        case .activities: ActivitiesPane()
        case .search: SearchPane()
        case .widgets: WidgetsPane()
        case .standby: StandByPane()
        case .dock: DockPane()
        case .about: AboutPane()
        }
    }
}

@MainActor
enum SettingsWindow {
    static func make() -> NSWindow {
        let host = NSHostingController(rootView: SettingsRoot())
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "Mac Flow"
        window.setContentSize(NSSize(width: 980, height: 720))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AtollSettings")
        window.center()
        return window
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { loginEnabled }, set: setLogin))
                if let loginNote {
                    Text(loginNote).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show in Menu Bar", isOn: $prefs.showMenuBarIcon)
            }
            Section {
                Toggle("Open When Pointer Rests on Notch", isOn: $prefs.expandOnHover)
                if prefs.expandOnHover {
                    LabeledContent("Delay") {
                        Slider(value: $prefs.hoverDelay, in: 0...0.6) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("Short").font(.caption)
                        } maximumValueLabel: {
                            Text("Long").font(.caption)
                        }
                        .frame(width: 220)
                    }
                }
                Toggle("Trackpad Gestures", isOn: $prefs.gestures)
                Toggle("Haptic Feedback", isOn: $prefs.haptics)
            } header: {
                Text("Island")
            } footer: {
                Text("Swipe down on the notch to open it, sideways to move between activities, and up to close. Over Now Playing, scroll to change the volume.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Keyboard") {
                Picker("Search Shortcut", selection: $prefs.hotKey) {
                    ForEach(HotKeyChoice.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Display") {
                Picker("Show On", selection: $prefs.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(on ? Bundle.main.bundlePath : nil, forKey: "loginItemPath")
            loginNote = nil
        } catch {
            loginNote = "Move Mac Flow to the Applications folder, then try again."
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginNote = "Allow Mac Flow in System Settings › General › Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

// MARK: - Live Activities

/// Claude: live sessions in the island, alerts, and answers from the notch.
private struct ClaudeSection: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var claude = ClaudeSessions.shared
    @ObservedObject private var ask = ClaudeAsk.shared

    var body: some View {
        Section {
            Toggle(isOn: $prefs.claude) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Sessions")
                    Text(claude.sessions.isEmpty ? "Shows when Claude is working, done, or needs you."
                         : "\(claude.sessions.count) session\(claude.sessions.count == 1 ? "" : "s") open · \(claude.working.count) working")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Alert When Claude Finishes or Needs You", isOn: $prefs.claudeAlerts)
                .disabled(!prefs.claude)
            LabeledContent {
                if ask.signedIn == true {
                    Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if ask.isInstalled {
                    Button("Sign In…") { ask.signIn() }
                } else {
                    Text("Claude Code not found").foregroundStyle(.secondary)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask Claude from the Notch")
                    Text("Type a question in search. Answers stream into the island.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("Mac Flow reads only the status files Claude keeps for open sessions — their names, folders and whether they’re working. Your conversations are never read. Answers use Claude Code with every tool turned off, signed in to your own account.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { ask.refreshSignIn() }
    }
}

private struct ActivitiesPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var calendar = CalendarModel.shared
    @ObservedObject private var weather = WeatherService.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            Form {
                ClaudeSection()
                Section {
                    Toggle("Now Playing", isOn: $prefs.nowPlaying)
                    Toggle("Calls", isOn: $prefs.calls)
                        .help("Shows when an app like FaceTime, Zoom or Teams is using your microphone or camera.")
                    Toggle(isOn: $prefs.meetings) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Upcoming Meetings")
                            permission(calendar.access == .granted, denied: calendar.access == .denied, name: "Calendar") { calendar.requestAccess() }
                        }
                    }
                    Toggle(isOn: $prefs.downloads) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloads")
                            Text("Asks for access to your Downloads folder.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Files on Shelf", isOn: $prefs.shelfInNotch)
                } header: {
                    Text("Activities")
                } footer: {
                    Text("Timers and Keep Awake always appear while they’re running.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("Alerts") {
                    Toggle("Volume", isOn: $prefs.volumeAlerts)
                    Toggle("Charging and Low Battery", isOn: $prefs.powerAlerts)
                    Toggle("Song Changes", isOn: $prefs.trackAlerts)
                    Toggle("Camera and Microphone", isOn: $prefs.privacyIndicators)
                    Toggle(isOn: $prefs.devices) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AirPods and Bluetooth Devices")
                            Text("Asks for Bluetooth access.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Play Sounds", isOn: $prefs.sounds)
                }
                Section {
                    Toggle("Weather", isOn: $prefs.weatherEnabled)
                    if prefs.weatherEnabled {
                        TextField("Location", text: $prefs.weatherCity, prompt: Text("Current Location"))
                        Picker("Temperature", selection: $prefs.temperatureUnit) {
                            ForEach(TemperatureUnit.allCases) { Text($0.label).tag($0) }
                        }
                        if case .failed(let message) = weather.status {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Glance")
                } footer: {
                    Text("Forecasts from Open-Meteo. Only the location is sent.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func permission(_ granted: Bool, denied: Bool, name: String, request: @escaping () -> Void) -> some View {
        if granted {
            Label("\(name) connected", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            Button(denied ? "Allow \(name) Access in System Settings…" : "Connect \(name)…", action: request)
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}

// MARK: - Search

private struct SearchPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var history = ClipboardHistory.shared
    @ObservedObject private var shelf = ShelfModel.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            Form {
                Section {
                    Toggle("Files", isOn: $prefs.fileSearch)
                    Toggle("Currency Conversion", isOn: $prefs.onlineCurrency)
                } header: {
                    Text("Search")
                } footer: {
                    Text("Try “26.2 mi in km”, “$40 to €”, “time in Tokyo”, “remind me to call Sam at 5pm”, or “timer 10”. Currency uses European Central Bank rates.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    Toggle("Keep Clipboard History", isOn: $prefs.clipboardEnabled)
                    Toggle("Include Images", isOn: $prefs.clipboardImages)
                        .disabled(!prefs.clipboardEnabled)
                    Toggle(isOn: Binding(get: { prefs.pasteOnReturn }, set: { on in
                        prefs.pasteOnReturn = on
                        if on && !InputControl.isTrusted { InputControl.requestTrust() }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Return Pastes into the Front App")
                            if prefs.pasteOnReturn && !InputControl.isTrusted {
                                Button("Allow Accessibility Access…") { InputControl.openAccessibilitySettings() }
                                    .buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                    .disabled(!prefs.clipboardEnabled)
                    LabeledContent("Saved Items", value: "\(history.items.count)")
                    Button("Clear History…", role: .destructive) { history.clearUnpinned() }
                        .disabled(history.items.isEmpty)
                } header: {
                    Text("Clipboard")
                } footer: {
                    Text("Passwords and other items marked private by password managers are never saved. History stays on this Mac.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    LabeledContent("Files on Shelf", value: "\(shelf.items.count)")
                    Button("Empty Shelf") { shelf.clear() }
                        .disabled(shelf.items.isEmpty)
                } header: {
                    Text("Shelf")
                } footer: {
                    Text("The shelf keeps references to files. Nothing is moved or copied.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            FlowLogo(markHeight: 38)
                .padding(.bottom, 8)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Your Mac’s notch, alive — with Flow, an assistant that lives on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
