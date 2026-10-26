import SwiftUI
import AppKit
import ScreenCaptureKit

/// Settings › Brain: how much Atoll observes, what it has learned, and full control over both.
struct BrainPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var facts: [BrainStore.Fact] = []
    @State private var sessions: [BrainStore.Episode] = []
    @State private var counts = (events: 0, episodes: 0, facts: 0)
    @State private var confirmErase = false
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var axAllowed = InputControl.isTrusted
    @State private var shortcuts: [String] = []
    @ObservedObject private var rooms = RoomStore.shared
    @ObservedObject private var learned = PatternsModel.shared
    @ObservedObject private var news = NewsStore.shared
    @ObservedObject private var learnStore = LearnStore.shared
    @State private var newFeed = ""
    @State private var memories = 0

    private let store = BrainStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(BrainLevel.allCases) { level in
                    LevelRow(level: level, selected: prefs.brainLevel == level.rawValue, permission: permission(for: level)) {
                        choose(level)
                    }
                }
            } header: {
                Text("How Much Mac Flow Observes")
            } footer: {
                Text(Mind.shared.isAvailable
                     ? "Everything stays on this Mac. Flow thinks with Apple’s on-device model; nothing is sent anywhere."
                     : Mind.shared.unavailableReason)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Suggestions") {
                Toggle("Suggest and Ask When It Helps", isOn: $prefs.brainSuggestions)
                LabeledContent("Pause") {
                    if let until = prefs.brainPausedUntil, until > Date() {
                        HStack {
                            Text("Paused until \(until.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                            Button("Resume") { prefs.brainPausedUntil = nil }
                        }
                    } else {
                        Menu("Pause Observing") {
                            Button("For 1 Hour") { prefs.brainPausedUntil = Date().addingTimeInterval(3600) }
                            Button("Until Tomorrow") { prefs.brainPausedUntil = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400)) }
                        }
                        .fixedSize()
                    }
                }
            }

            Section {
                if learned.patterns.isReady {
                    FocusRhythm(patterns: learned.patterns)
                        .padding(.vertical, 4)
                    ForEach(learned.patterns.insights + Habits.shared.sentences, id: \.self) { line in
                        Label(line, systemImage: "sparkle").labelStyle(.titleAndIcon)
                    }
                } else {
                    Text("Flow is still learning your rhythm — give it a few days of work.").foregroundStyle(.secondary)
                }
                LabeledContent("Memories") {
                    HStack {
                        Text(memories == 0 ? "None yet" : "\(memories)").foregroundStyle(.secondary)
                        Button("Relearn") { learned.refresh(); MemoryKeeper.shared.collect() }
                    }
                }
            } header: {
                Text("What Flow Has Learned")
            } footer: {
                Text("From the last four weeks of your sessions, on this Mac. Flow puts your most important priority into your sharpest hours, nudges you to protect them, and remembers your days by meaning so you can ask “when did I last work on…?”")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Show the Brief in the Sheet", isOn: $prefs.newsEnabled)
                if prefs.newsEnabled {
                    ForEach(news.feeds) { feed in
                        Toggle(isOn: Binding(get: { feed.on }, set: { news.setFeed(feed, on: $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(feed.name)
                                Text(feed.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu { Button("Remove", role: .destructive) { news.removeFeed(feed) } }
                    }
                    HStack {
                        TextField("Add a feed (RSS or Atom address)", text: $newFeed)
                        Button("Add") { if news.addFeed(newFeed) { newFeed = "" } }.disabled(newFeed.isEmpty)
                    }
                }
            } header: {
                Text("The Brief")
            } footer: {
                Text("Headlines from these sources, ranked on this Mac by what you work on and read. Mac Flow fetches the feeds directly — no account, no cookies, nothing about you is sent.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Quiz Me at Quiet Moments", isOn: $prefs.learnQuizzes)
                LabeledContent("Cards") { Text("\(learnStore.cards.count) · \(learnStore.due.count) due").foregroundStyle(.secondary) }
            } header: {
                Text("Learn")
            } footer: {
                Text("Save a page you’re reading (from Now, the sheet or Flow) or a passage you copy (Flow Lens), and Flow writes a few cards from it — only from what you saved — then brings one back after a break or a focus block, spaced so it sticks.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Plan Your Day Each Morning", isOn: $prefs.planMorning)
                LabeledContent("Workday") {
                    HStack(spacing: 6) {
                        Picker("Starts", selection: $prefs.planStartHour) {
                            ForEach(5..<13, id: \.self) { Text(Self.hour($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("to").foregroundStyle(.secondary)
                        Picker("Ends", selection: $prefs.planEndHour) {
                            ForEach(14..<24, id: \.self) { Text(Self.hour($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                LabeledContent("Today") {
                    Button("Plan Today…") { IslandManager.shared.openPlan() }
                }
            } header: {
                Text("Plan Your Day")
            } footer: {
                Text("The first time you open your Mac each morning, Flow asks for your top priorities and meetings, fits them into your day, and nudges you as each one comes up.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Hide Other Apps When Setting a Room", isOn: $prefs.roomHidesOthers)
                Toggle("Dim Around Your Window During Focus", isOn: $prefs.dimFocus)
                Picker("Turn On Focus With", selection: $prefs.focusShortcutOn) {
                    Text("Nothing").tag("")
                    ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                }
                Picker("Turn Off Focus With", selection: $prefs.focusShortcutOff) {
                    Text("Nothing").tag("")
                    ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Saved Rooms") {
                    Text(rooms.rooms.isEmpty ? "None yet" : "\(rooms.rooms.count)").foregroundStyle(.secondary)
                }
            } header: {
                Text("Rooms")
            } footer: {
                Text("When a focus block starts, “Set the Room” reopens the documents you had open for it, hides the rest, plays your music and starts a timer. macOS doesn’t let apps turn on Focus, so pick a Shortcut that does (make one with the Set Focus action). Documents are remembered at the Context level, with Accessibility.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Press and Hold the Notch to Talk", isOn: $prefs.holdToTalk)
                Toggle("Flow Lens: Next Steps for What You Copy", isOn: $prefs.flowLens)
                Toggle("Offer to Take Meeting Notes", isOn: $prefs.meetingNotes)
                LabeledContent("Notes Folder") {
                    Button("Show in Finder") {
                        let dir = Storage.directory.appendingPathComponent("Meetings", isDirectory: true)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
            } header: {
                Text("Voice and Meetings")
            } footer: {
                Text("Speech is turned into text on this Mac — audio is never saved or sent. Meeting notes start only when you press Take Notes in a call (a red dot shows while they’re on); you from the microphone, the others from your Mac’s audio. Recording people may need their consent where you are — tell them.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker("Keep Memory For", selection: $prefs.brainRetentionDays) {
                    Text("1 Week").tag(7)
                    Text("1 Month").tag(30)
                    Text("3 Months").tag(90)
                    Text("1 Year").tag(365)
                }
                LabeledContent("Never Observe") {
                    Menu("Add App…") {
                        ForEach(runningApps, id: \.0) { bundle, name in
                            Button(name) { if !prefs.brainExcluded.contains(bundle) { prefs.brainExcluded.append(bundle) } }
                        }
                    }
                    .fixedSize()
                }
                ForEach(prefs.brainExcluded, id: \.self) { bundle in
                    HStack {
                        Text(BrainEngine.appName(bundle) ?? bundle)
                        Spacer()
                        Button { prefs.brainExcluded.removeAll { $0 == bundle } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Password managers and private browser windows are never recorded. \(counts.events) observations, \(counts.episodes) work sessions and \(counts.facts) learned facts stored.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("What Flow Knows") {
                let told = facts.filter { $0.source == "answered" && !$0.key.hasPrefix("ask:") }
                if told.isEmpty && sessions.isEmpty {
                    Text("Nothing yet. Flow learns as you work, and asks when it isn’t sure.").foregroundStyle(.secondary)
                }
                ForEach(told) { f in
                    HStack {
                        Image(systemName: "person.fill.questionmark").foregroundStyle(BrainStyle.tint)
                        Text(BrainEngine.factText(f))
                        Spacer()
                        Button { store.deleteFact(f.key); reload() } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .help("Forget")
                    }
                }
                ForEach(sessions.prefix(8)) { ep in
                    HStack {
                        Image(systemName: (WorkMode(rawValue: ep.mode) ?? .other).symbol).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ep.summary).lineLimit(1)
                            Text("\(ep.start.formatted(date: .abbreviated, time: .shortened)) · \(BrainEngine.duration(ep.end.timeIntervalSince(ep.start)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.deleteEpisode(ep.id); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { reload() } } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Forget this session")
                    }
                }
                if Mind.shared.isAvailable {
                    Button("Ask Flow About Your Day…") { BrainEngine.shared.askBrain("What have I been working on today, and what should I focus on next?") }
                }
            }

            Section {
                Button("Erase Everything Flow Has Learned…", role: .destructive) { confirmErase = true }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reload()
            FocusShortcuts.list { shortcuts = $0 }
            DispatchQueue.global(qos: .utility).async {
                let n = Memory.shared.count
                DispatchQueue.main.async { memories = n }
            }
        }
        .confirmationDialog("Erase everything Flow has learned?", isPresented: $confirmErase) {
            Button("Erase Everything", role: .destructive) { store.eraseEverything(); reload() }
        } message: {
            Text("This deletes every observation, work session and answer. It can’t be undone.")
        }
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.1 < $1.1 }
    }

    private func reload() {
        facts = store.facts()
        sessions = store.episodes(since: Date().addingTimeInterval(-3 * 86_400), limit: 20)
        counts = store.counts()
        screenAllowed = CGPreflightScreenCaptureAccess()
        axAllowed = InputControl.isTrusted
    }

    private func permission(for level: BrainLevel) -> (granted: Bool, name: String)? {
        switch level {
        case .context: (axAllowed, "Accessibility")
        case .everything: (screenAllowed && axAllowed, "Screen Recording")
        default: nil
        }
    }

    static func hour(_ h: Int) -> String {
        let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    private func choose(_ level: BrainLevel) {
        prefs.brainLevel = level.rawValue
        if level.rawValue >= BrainLevel.context.rawValue, !InputControl.isTrusted { InputControl.requestTrust() }
        if level == .everything, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reload() }
    }
}

private struct LevelRow: View {
    let level: BrainLevel
    let selected: Bool
    let permission: (granted: Bool, name: String)?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? BrainStyle.tint : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(level.title).font(.system(size: 13, weight: .semibold))
                        if let p = permission {
                            Text(p.granted ? "\(p.name) allowed" : "Needs \(p.name)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(p.granted ? .green : .orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill((p.granted ? Color.green : .orange).opacity(0.14)))
                        }
                    }
                    Text(level.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
