import AppKit
import SwiftUI
import Combine

/// Creates an island per screen, turns system events into alerts, and owns the keyboard path.
@MainActor
final class IslandManager {
    static let shared = IslandManager()

    private(set) var controllers: [IslandController] = []
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var rebuildWork: DispatchWorkItem?
    private var started = false
    private var lastOwnVolumeChange = Date.distantPast

    var primary: IslandController? { controllers.first }

    func start() {
        guard !started else { return }
        started = true
        _ = ActivityCenter.shared
        rebuild()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controllers.forEach { $0.panel.orderFrontRegardless() } }
        }
        Prefs.shared.$displayMode.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        wireServices()
        wireAlerts()
        installKeyMonitor()
        warmUp()
    }

    /// Whether you're already looking at the session (Claude app in front), so an alert would only interrupt.
    private static func lookingAt(_ s: ClaudeSessions.Session) -> Bool {
        s.viaDesktop && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeSessions.desktopBundleID
    }

    // MARK: Brain

    /// Flow pops up. Long enough to read and answer, held while the pointer rests on it — and if it still goes
    /// unanswered it waits in Flow's inbox, on Home (`FlowInbox`).
    func showBrain(_ alert: IslandAlert) {
        #if DEBUG
        if Self.suppressAlerts { return }
        #endif
        guard let model = primary?.model else { return }
        let duration: TimeInterval = { if case .brainQuestion = alert { return 30 }; return 18 }()
        model.showAlert(alert, duration: duration)
        // Only when it actually popped (an open island keeps it for Home, silently).
        if model.mode == .alert, model.alert?.kind == alert { Haptics.snap() }
    }

    /// Plan your day, in the island.
    func openPlan() {
        guard let model = primary?.model else { return }
        if model.mode != .expanded(.plan) { PlanStore.shared.prepareForEditing() }
        model.openPlan()
    }

    // MARK: First-run tour

    private var tourStep = -1
    private var tourWork: DispatchWorkItem?

    /// Three tips, shown in the island itself — so they're seen even over a full-screen app.
    func startTour() {
        tourStep = -1
        advanceTour()
    }

    func advanceTour() {
        tourWork?.cancel()
        let hot = Prefs.shared.hotKey
        let tips: [(String, String, String)] = [
            ("hand.point.up.left.fill", "Rest the pointer here", "See what’s playing and what’s next"),
            ("magnifyingglass", hot == .disabled ? "Search from the menu bar" : "Press \(hot.label) to search", "Apps, files, answers, clipboard"),
            ("tray.and.arrow.down.fill", "Drag files onto the notch", "Hold them, or AirDrop them"),
        ]
        tourStep += 1
        guard tourStep < tips.count, let model = primary?.model else {
            primary?.model.dismissAlert()
            tourStep = -1
            return
        }
        let t = tips[tourStep]
        model.showAlert(.tip(symbol: t.0, title: t.1, detail: t.2, step: tourStep, total: tips.count), duration: 60)
        let work = DispatchWorkItem { [weak self] in self?.advanceTour() }
        tourWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2, execute: work)
    }

    /// Builds every open presentation once, off screen, shortly after launch — so the first hover
    /// doesn't pay for creating views, loading symbols and laying out text while the shape is moving.
    private func warmUp() {
        let modes: [IslandMode] = [.expanded(.glance)] + ActivityKind.allCases.map { .expanded(.activity($0)) } + [.search]
        for (i, mode) in modes.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + Double(i) * 0.12) { [weak self] in
                guard let model = self?.primary?.model, model.mode == .compact else { return }
                let renderer = ImageRenderer(content: WarmUpHost(model: model, mode: mode))
                renderer.scale = 2
                _ = renderer.cgImage
            }
        }
    }

    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        switch Prefs.shared.displayMode {
        case .notchScreen:
            if let s = screens.first(where: \.hasNotch) ?? screens.first { return [s] }
        case .mainScreen:
            if let s = screens.first { return [s] }
        case .allScreens:
            return screens.sorted { a, _ in a.hasNotch }
        }
        return []
    }

    private func rebuild() {
        controllers.forEach { $0.teardown() }
        controllers = targetScreens().enumerated().map { IslandController(screen: $1, isPrimary: $0 == 0) }
    }

    // MARK: - Commands

    private var focused: IslandController? {
        let p = NSEvent.mouseLocation
        return controllers.first { $0.screen.frame.contains(p) } ?? primary
    }

    var focusedContentView: NSView? {
        (controllers.first { $0.model.mode != .compact } ?? focused)?.panel.contentView
    }

    func keyPanelForQuickLook() -> NotchPanel? {
        (controllers.first { $0.model.mode != .compact } ?? primary)?.panel
    }

    func toggleSearch() {
        guard let c = focused else { return }
        if c.model.mode == .search { c.model.collapse() } else { c.model.openSearch() }
    }

    func openSearch(scope: SearchScope = .all) {
        guard let c = focused else { return }
        c.model.openSearch()
        SearchModel.shared.scope = scope
    }

    func openShelf() {
        focused?.model.expand(.activity(.shelf), sticky: true)
    }

    func openMirror() { focused?.model.openMirror() }

    func collapseAll() { controllers.forEach { $0.model.collapse() } }

    func confirm(_ symbol: String, _ text: String, tint: Color = .white) {
        primary?.model.showAlert(.message(symbol: symbol, text: text, tint: tint), duration: 1.8)
    }

    func noteOwnVolumeChange() { lastOwnVolumeChange = Date() }

    func perform(_ command: SystemCommand) {
        switch command {
        case .lockScreen:
            collapseAll()
            SystemActions.lockScreen()
        case .sleepDisplays:
            collapseAll()
            SystemActions.sleepDisplays()
        case .toggleDarkMode:
            collapseAll()
            SystemActions.toggleDarkMode()
        case .keepAwake:
            collapseAll()
            KeepAwake.shared.toggle()
        case .colorPicker:
            collapseAll()
            SystemActions.pickColor { [weak self] hex in
                Haptics.confirm()
                self?.confirm("eyedropper.halffull", "Copied \(hex)", tint: Color(hex: hex) ?? .white)
            }
        case .screenshot:
            collapseAll()
            SystemActions.screenshot()
        case .mirror:
            focused?.model.collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.openMirror() }
        case .focus25:
            collapseAll()
            FocusTimer.shared.start(minutes: 25, label: "Focus")
        case .focus5:
            collapseAll()
            FocusTimer.shared.start(minutes: 5, label: "Break")
        case .clearClipboard:
            ClipboardHistory.shared.clearUnpinned()
            SearchModel.shared.confirm("Clipboard Cleared")
        case .showShelf:
            collapseAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.openShelf() }
        case .settings:
            collapseAll()
            WindowManager.shared.showSettings()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    // MARK: - Services that follow preferences

    private func wireServices() {
        Prefs.shared.$claude
            .receive(on: RunLoop.main)
            .sink { ClaudeSessions.shared.setEnabled($0) }
            .store(in: &cancellables)
        ClaudeSessions.shared.onFinish = { [weak self] s, took in
            guard Prefs.shared.claudeAlerts, !Self.lookingAt(s) else { return }
            self?.alert(.claudeFinished(id: s.id, name: s.name, duration: took), 5)
            Haptics.confirm()
            if Prefs.shared.sounds { NSSound(named: "Glass")?.play() }
        }
        ClaudeSessions.shared.onNeedsYou = { [weak self] s in
            guard Prefs.shared.claudeAlerts, !Self.lookingAt(s) else { return }
            self?.alert(.claudeNeedsYou(id: s.id, name: s.name, folder: s.folder), 8)
            Haptics.confirm()
            if Prefs.shared.sounds { NSSound(named: "Ping")?.play() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ClaudeAsk.shared.refreshSignIn() }
        Prefs.shared.$downloads
            .receive(on: RunLoop.main)
            .sink { DownloadsWatcher.shared.setEnabled($0) }
            .store(in: &cancellables)
        Prefs.shared.$devices
            .receive(on: RunLoop.main)
            .sink { BluetoothMonitor.shared.setEnabled($0) }
            .store(in: &cancellables)
        Prefs.shared.$weatherEnabled
            .receive(on: RunLoop.main)
            .sink { WeatherService.shared.setEnabled($0) }
            .store(in: &cancellables)
        Publishers.CombineLatest(Prefs.shared.$weatherCity.removeDuplicates(), Prefs.shared.$temperatureUnit.removeDuplicates())
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { _ in if Prefs.shared.weatherEnabled { WeatherService.shared.refresh() } }
            .store(in: &cancellables)
    }

    // MARK: - Alerts

    #if DEBUG
    /// The hover test runs with real services; their alerts would make it nondeterministic.
    static var suppressAlerts = false
    #endif

    private func alert(_ kind: IslandAlert, _ duration: TimeInterval) {
        #if DEBUG
        if Self.suppressAlerts { return }
        #endif
        primary?.model.showAlert(kind, duration: duration)
    }

    private func wireAlerts() {
        CustomActivity.shared.onFinish = { [weak self] item in
            let failed = item.state == .failed
            self?.alert(.message(symbol: failed ? "xmark.octagon.fill" : "checkmark.circle.fill", text: item.title,
                                 tint: failed ? DS.Palette.red : DS.Palette.green), 3.5)
            if !failed { Haptics.confirm() }
        }

        NowPlayingModel.shared.$trackChangeTick
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard Prefs.shared.trackAlerts, NowPlayingModel.shared.isPlaying else { return }
                self?.alert(.trackChanged, 3)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(SystemVolume.shared.$volume, SystemVolume.shared.$muted)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] level, muted in
                guard let self, Prefs.shared.volumeAlerts,
                      Date().timeIntervalSince(self.lastOwnVolumeChange) > 0.6 else { return }
                self.alert(.volume(level: level, muted: muted), 1.5)
            }
            .store(in: &cancellables)

        DisplayControl.shared.$keyTick
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard Prefs.shared.volumeAlerts else { return }
                self?.alert(.brightness(DisplayControl.shared.brightness), 1.5)
            }
            .store(in: &cancellables)

        AudioActivity.shared.$cameraInUse
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard on, Prefs.shared.privacyIndicators else { return }
                self?.alert(.privacy(camera: true, app: nil), 2.5)
            }
            .store(in: &cancellables)
        AudioActivity.shared.$micInUse
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard on, Prefs.shared.privacyIndicators else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                    guard AudioActivity.shared.micInUse else { return }
                    self?.alert(.privacy(camera: false, app: AudioActivity.shared.micApps.first?.name), 2.5)
                }
            }
            .store(in: &cancellables)

        DownloadsWatcher.shared.onFinished = { [weak self] url in
            self?.alert(.downloadFinished(url), 6)
        }
        BluetoothMonitor.shared.onChange = { [weak self] device in
            self?.alert(.device(device), device.hasBattery ? 4 : 2.5)
        }
        BatteryMonitor.shared.onPluggedIn = { [weak self] level in
            guard Prefs.shared.powerAlerts else { return }
            self?.alert(.charging(level), 2.5)
        }
        BatteryMonitor.shared.onLow = { [weak self] level in
            guard Prefs.shared.powerAlerts else { return }
            self?.alert(.lowBattery(level), 4)
        }
        FocusTimer.shared.onStop = { label in
            RoomStore.shared.blockEnded(label)
            // A block just ended: once its own alert has had its moment, maybe a card to recall.
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) { LearnStore.shared.quizIfQuiet() }
        }
        FocusTimer.shared.onFinish = { [weak self] label in
            if Prefs.shared.sounds { NSSound(named: "Glass")?.play() }
            self?.alert(.timerFinished(label), 10)
            PlanStore.shared.markDone(title: label)
        }
        CalendarModel.shared.onMeetingSoon = { [weak self] event, minutes in
            guard Prefs.shared.meetings else { return }
            if Prefs.shared.sounds { NSSound(named: "Tink")?.play() }
            self?.alert(.meetingSoon(event, minutes: minutes), 8)
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let consumed = MainActor.assumeIsolated { self?.consumeKey(e) ?? false }
            return consumed ? nil : e
        }
    }

    /// Returns true when Atoll handled the key, so it never reaches the text field.
    private func consumeKey(_ e: NSEvent) -> Bool {
        guard let c = controllers.first(where: { $0.panel.isKeyWindow }), c.model.mode != .compact else { return false }
        let model = c.model
        let search = SearchModel.shared
        let cmd = e.modifierFlags.contains(.command)

        if cmd, e.charactersIgnoringModifiers == "," {
            perform(.settings)
            return true
        }

        if model.mode == .expanded(.sheet), e.keyCode == 53 {
            model.select(.glance)
            return true
        }
        if model.mode == .expanded(.rewind) {
            switch e.keyCode {
            case 123: RewindModel.shared.step(-1); return true   // left
            case 124: RewindModel.shared.step(1); return true    // right
            case 36, 76: RewindModel.shared.reopen(); return true
            default: break
            }
        }
        if model.mode == .expanded(.plan), e.keyCode == 53 {
            MorningPlanner.shared.later()
            return true
        }
        if model.mode == .expanded(.brain), e.keyCode == 53 {
            model.select(.glance)
            return true
        }

        if model.mode == .search {
            if cmd, let ch = e.charactersIgnoringModifiers, let s = SearchScope.allCases.first(where: { $0.shortcut == ch }) {
                search.cycleScope(s)
                return true
            }
            switch e.keyCode {
            case 53: // esc
                if search.answering { search.closeAnswer() }
                else if !search.query.isEmpty { search.query = "" } else if search.scope != .all { search.scope = .all } else { model.collapse() }
                return true
            case 125: search.move(1); return true   // down
            case 126: search.move(-1); return true  // up
            case 123 where search.query.isEmpty: search.move(-1); return true  // left (icon row)
            case 124 where search.query.isEmpty: search.move(1); return true   // right (icon row)
            case 36, 76: search.activateSelection(alternate: cmd); return true
            case 48 where !search.query.isEmpty && !search.answering: search.askAboutQuery(); return true
            case 51 where !search.fieldFocused: if !search.query.isEmpty { search.query.removeLast() }; return true
            default:
                guard !search.fieldFocused, !cmd, !e.modifierFlags.contains(.control),
                      let text = e.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
                search.query += text
                return true
            }
        }

        if e.keyCode == 53 {
            model.collapse()
            return true
        }
        if e.keyCode == 49, model.focus == .activity(.shelf), !(c.panel.firstResponder is NSText) {
            ShelfModel.shared.quickLook(ShelfModel.shared.targets)
            return true
        }
        return false
    }
}

/// An off-screen copy of one presentation, drawn at its settled state.
private struct WarmUpHost: View {
    let model: IslandModel
    let mode: IslandMode
    @Namespace private var ns

    var body: some View {
        IslandPresentation(model: model, mode: mode, size: model.spec(for: mode).size, alert: nil,
                           primary: model.primary, ns: ns)
            .environment(\.colorScheme, .dark)
    }
}
