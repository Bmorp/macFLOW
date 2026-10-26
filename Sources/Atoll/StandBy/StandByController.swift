import AppKit
import SwiftUI
import Combine
import IOKit.pwr_mgt
import Carbon.HIToolbox

/// Full-screen ambient window. Takes keys without activating anything behind it.
private final class StandByPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func flagsChanged(with event: NSEvent) { onKey?(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKey?(event)
        return true
    }
}

/// StandBy for Mac: after a few idle minutes on power — or on request — the display becomes a calm
/// clock, two smart stacks of widgets, or what's playing. Any key or pointer movement fades back.
@MainActor
final class StandByController {
    static let shared = StandByController()

    private(set) var isShowing = false
    private var panel: StandByPanel?
    private var model: StandByModel?
    private var idleTimer: Timer?
    private var minuteTimer: Timer?
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    /// Live only while StandBy is up.
    private var showing = Set<AnyCancellable>()
    private var assertion = IOPMAssertionID(0)
    private var hasAssertion = false
    private var enteredAt = Date()
    private var entryMouse = NSPoint.zero
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0
    private var scrollConsumed = false
    private var previousApp: NSRunningApplication?
    private var cursorHidden = false

    static let hotKeyID: UInt32 = 2

    func start() {
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t

        // Unplugging ends StandBy when it only runs on power — as on iPhone.
        BatteryMonitor.shared.$onAC
            .removeDuplicates()
            .sink { [weak self] onAC in
                guard let self, self.isShowing, !onAC, Prefs.shared.standByChargingOnly else { return }
                self.exit()
            }
            .store(in: &cancellables)

        HotKeyCenter.shared.add(id: Self.hotKeyID, keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | cmdKey)) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
    }

    func toggle() { isShowing ? exit() : enter(manual: true) }

    // MARK: Idle

    private func checkIdle() {
        let prefs = Prefs.shared
        guard prefs.standByEnabled, !isShowing else { return }
        guard !prefs.standByChargingOnly || BatteryMonitor.shared.onAC else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard idle >= prefs.standByDelay else { return }
        guard !Self.screenIsLocked, !Self.somethingElseKeepsDisplayAwake else { return }
        enter(manual: false)
    }

    private static var screenIsLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Video, presentations and calls hold display assertions — StandBy stays out of their way.
    private static var somethingElseKeepsDisplayAwake: Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let dict = status?.takeRetainedValue() as? [String: Int] else { return false }
        let count = dict[kIOPMAssertPreventUserIdleDisplaySleep as String] ?? 0
        return count > (KeepAwake.shared.isOn ? 1 : 0)
    }

    // MARK: Enter / exit

    func enter(manual: Bool) {
        guard !isShowing else { return }
        let screen = NSScreen.screens.first(where: \.hasNotch) ?? NSScreen.main ?? NSScreen.screens[0]
        isShowing = true
        IslandManager.shared.collapseAll()

        let model = StandByModel()
        StandByStage.epoch = CACurrentMediaTime()
        model.prepare(screen: screen.frame.size, scale: screen.backingScaleFactor)
        model.tickMinute()
        model.showHint = manual
        let np = NowPlayingModel.shared
        if Prefs.shared.standByMusicFirst, np.isLive { model.page = .nowPlaying }
        self.model = model
        follow(np, model: model)

        let panel = StandByPanel(frame: screen.frame)
        panel.contentView = NSHostingView(rootView: StandByView(model: model))
        panel.onKey = { [weak self] e in self?.handleKey(e) }
        panel.alphaValue = 0
        self.panel = panel

        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Access.reduceMotion ? 0.2 : 0.9
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
        model.flashChrome()
        if manual {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak model] in
                withAnimation(Motion.duo) { model?.showHint = false }
            }
        }

        enteredAt = Date()
        entryMouse = NSEvent.mouseLocation
        scrollX = 0
        scrollY = 0
        installMonitors()

        let mt = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model?.tickMinute()
                // After an hour, let the display sleep as the system normally would.
                if Date().timeIntervalSince(self.enteredAt) > 3600 { self.holdDisplayAwake(false) }
            }
        }
        RunLoop.main.add(mt, forMode: .common)
        minuteTimer = mt

        if BatteryMonitor.shared.onAC { holdDisplayAwake(true) }
    }

    func exit() {
        guard isShowing, let panel else { return }
        isShowing = false
        removeMonitors()
        showing.removeAll()
        LyricsModel.shared.follow(false)
        NowPlayingModel.shared.keepSynced(false, for: "standby")
        minuteTimer?.invalidate()
        minuteTimer = nil
        holdDisplayAwake(false)
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Access.reduceMotion ? 0.15 : 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.close()
                if self?.panel === panel { self?.panel = nil; self?.model = nil }
            }
        })
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    /// The player, while StandBy is up: kept in step (lyrics need the position to a fraction of a second), Now Playing
    /// turned to when a song starts, and left when the player goes away.
    private func follow(_ np: NowPlayingModel, model: StandByModel) {
        np.keepSynced(true, for: "standby")
        np.refresh()
        LyricsModel.shared.follow(true)
        np.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { [weak model] playing in
                MainActor.assumeIsolated {
                    guard let model, playing, Prefs.shared.standByMusicFirst, model.page == .clock else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model.go(to: .nowPlaying) }
                }
            }
            .store(in: &showing)
        np.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak model] _ in
                MainActor.assumeIsolated {
                    guard let model, model.page == .nowPlaying, NowPlayingModel.shared.mode == .idle else { return }
                    withAnimation(.spring(response: 0.9, dampingFraction: 0.9)) { model.page = .clock }
                }
            }
            .store(in: &showing)
    }

    private func holdDisplayAwake(_ on: Bool) {
        if on, !hasAssertion {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Mac Flow StandBy" as CFString, &id) == kIOReturnSuccess {
                assertion = id
                hasAssertion = true
            }
        } else if !on, hasAssertion {
            IOPMAssertionRelease(assertion)
            hasAssertion = false
        }
    }

    // MARK: Input

    private func installMonitors() {
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moved.union(clicks), handler: { [weak self] e in
            MainActor.assumeIsolated { self?.pointer(e) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moved.union(clicks).union(.scrollWheel), handler: { [weak self] e in
            MainActor.assumeIsolated {
                if e.type == .scrollWheel { self?.scroll(e) } else { self?.pointer(e) }
            }
            return nil
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func pointer(_ e: NSEvent) {
        // A moment of grace after entering, and a little tolerance for a nudged desk.
        guard Date().timeIntervalSince(enteredAt) > 0.8 else {
            entryMouse = NSEvent.mouseLocation
            return
        }
        if e.type == .leftMouseDown || e.type == .rightMouseDown || e.type == .otherMouseDown {
            exit()
            return
        }
        let p = NSEvent.mouseLocation
        if hypot(p.x - entryMouse.x, p.y - entryMouse.y) > 24 { exit() }
    }

    /// Two-finger swipes turn pages (sideways) and cycle stacks (up and down) — one step per gesture.
    private func scroll(_ e: NSEvent) {
        guard let model else { return }
        if e.phase == .began || e.phase == .mayBegin {
            scrollX = 0; scrollY = 0; scrollConsumed = false
        }
        if !e.hasPreciseScrollingDeltas { scrollConsumed = false }
        guard !scrollConsumed else { return }
        scrollX += e.scrollingDeltaX
        scrollY += e.scrollingDeltaY
        let threshold: CGFloat = e.hasPreciseScrollingDeltas ? 60 : 3
        if abs(scrollX) > threshold, abs(scrollX) > abs(scrollY) {
            model.turn(scrollX < 0 ? 1 : -1)
            scrollConsumed = true
        } else if abs(scrollY) > threshold {
            if model.page == .clock {
                model.cycleWallpaper(by: scrollY < 0 ? 1 : -1)
            } else {
                let side = NSEvent.mouseLocation.x < (panel?.frame.midX ?? 0) ? 0 : 1
                model.cycle(stack: side, by: scrollY < 0 ? 1 : -1)
            }
            scrollConsumed = true
        }
        if scrollConsumed || e.phase == .ended || e.phase == .cancelled { scrollX = 0; scrollY = 0 }
    }

    private func handleKey(_ e: NSEvent) {
        guard let model else { return }
        if e.type == .flagsChanged {
            if Date().timeIntervalSince(enteredAt) > 0.8 { exit() }
            return
        }
        switch Int(e.keyCode) {
        case kVK_LeftArrow: model.turn(-1)
        case kVK_RightArrow: model.turn(1)
        case kVK_UpArrow where model.page == .clock: model.cycleWallpaper(by: -1)
        case kVK_DownArrow where model.page == .clock: model.cycleWallpaper(by: 1)
        case kVK_UpArrow: model.cycle(stack: 0, by: -1); model.cycle(stack: 1, by: -1)
        case kVK_DownArrow: model.cycle(stack: 0, by: 1); model.cycle(stack: 1, by: 1)
        case kVK_Space where model.page == .nowPlaying: NowPlayingModel.shared.playPause()
        case kVK_ANSI_L where model.page == .nowPlaying: Prefs.shared.standByLyrics.toggle()
        default: exit()
        }
    }

    #if DEBUG
    var debugWindowNumber: Int? { panel?.windowNumber }
    func debugShow(page: StandByModel.Page, night: Bool = false) {
        enter(manual: false)
        removeMonitors()
        model?.page = page
        model?.night = night
        model?.drift = .zero
        model?.chromeVisible = true
    }

    func debugPage(_ page: StandByModel.Page) {
        withAnimation(Motion.duo) { model?.page = page }
    }

    func debugNight(_ on: Bool) { model?.night = on }
    #endif
}
