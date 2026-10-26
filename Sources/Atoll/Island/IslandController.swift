import AppKit
import SwiftUI

/// Owns one panel on one screen and turns pointer, drag and trackpad input into island behaviour.
/// The panel is click-through everywhere except exactly where the island currently is.
@MainActor
final class IslandController {
    let screen: NSScreen
    let model: IslandModel
    let panel: NotchPanel

    #if DEBUG
    /// The hover test drives the pointer here; nil in normal use.
    static var pointerOverride: NSPoint?
    static var pointer: NSPoint { pointerOverride ?? NSEvent.mouseLocation }
    #else
    static var pointer: NSPoint { NSEvent.mouseLocation }
    #endif

    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var dragStartedInside = false
    /// Press and hold the notch to talk: the pending hold, where it started, and whether it became one.
    private var holdWork: DispatchWorkItem?
    private var holdStart: NSPoint?
    private var holding = false
    private var holdingAlert = false

    /// Pointer speed (pt/s), for telling a resting pointer from one passing through to the menu bar.
    private var lastPoint = NSPoint.zero
    private var lastPointTime = CACurrentMediaTime()
    private var speed: CGFloat = 0
    /// After the island closes under a resting pointer, it waits for the pointer to leave before hover can reopen it.
    private var hoverNeedsExit = false
    private var lastMode: IslandMode = .compact

    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0
    private var scrollConsumed = false
    private var rewindTravel: CGFloat = 0

    init(screen: NSScreen, isPrimary: Bool) {
        self.screen = screen
        let geo = NotchGeometry.detect(for: screen)
        model = IslandModel(geometry: geo, isPrimary: isPrimary)
        let canvas = IslandModel.maxCanvas(for: geo)
        panel = NotchPanel(size: canvas)

        let hosting = IslandHostingView(rootView: IslandView(model: model))
        hosting.sizingOptions = []
        let container = TrackingContainerView(frame: NSRect(origin: .zero, size: canvas))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.onMouse = { [weak self] in self?.evaluateMouse() }
        panel.contentView = container
        model.panel = panel

        position()
        panel.orderFrontRegardless()
        installMonitors()
        MenuTracking.start()
        observeMode()
    }

    /// Re-checks the pointer after every change of state (the model reports the change before it lands,
    /// so the check runs on the next turn of the run loop, like the old Combine subscription did).
    private func observeMode() {
        withObservationTracking { _ = model.mode } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.evaluateMouse()
                self.updatePolling()
                // While the player is on show, keep it in step with the app (seeking there sends no notification).
                if self.model.isPrimary {
                    let mode = self.model.mode
                    NowPlayingModel.shared.keepSynced(mode == .expanded(.glance) || mode == .expanded(.activity(.nowPlaying)))
                }
                self.observeMode()
            }
        }
    }

    func teardown() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        panel.orderOut(nil)
        panel.close()
    }

    private func position() {
        let f = screen.frame
        let size = panel.frame.size
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: - Zones

    private func rect(for size: CGSize, offsetX: CGFloat = 0) -> NSRect {
        let f = screen.frame
        return NSRect(x: f.midX + offsetX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    /// Where the pointer counts as "on the island" right now, with a little forgiveness.
    private var islandZone: NSRect {
        let spec = model.spec
        // The shoulders are part of the silhouette but not something to aim at.
        let body = CGSize(width: spec.size.width - spec.shoulder, height: spec.size.height)
        switch model.mode {
        case .compact: return rect(for: body).insetBy(dx: -10, dy: -8)
        case .alert: return rect(for: body).insetBy(dx: -10, dy: -10)
        case .drop: return rect(for: body).insetBy(dx: -28, dy: -28)
        default: return rect(for: body).insetBy(dx: -18, dy: -20)
        }
    }

    /// Where a press-and-hold talks to Flow: the closed island, or the notch itself when it's open
    /// (the empty band between the tab switcher and the buttons).
    private var holdZone: NSRect {
        guard Prefs.shared.holdToTalk, model.isPrimary else { return .zero }
        switch model.mode {
        case .compact, .alert: return islandZone
        case .expanded: return rect(for: CGSize(width: model.notch.width, height: model.notch.height))
        default: return .zero
        }
    }

    private func scheduleHold(at p: NSPoint) {
        holdWork?.cancel()
        holdStart = p
        let work = DispatchWorkItem { [weak self] in
            guard let self, NSEvent.pressedMouseButtons & 1 != 0, self.holdStart != nil else { return }
            self.holdWork = nil
            self.holding = true
            self.cancelExpand()
            VoiceInput.shared.begin(on: self.model)
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private var bubbleZone: NSRect? {
        guard model.showsBubble else { return nil }
        let d = model.bubbleDiameter
        return rect(for: CGSize(width: d, height: d), offsetX: model.bubbleOffset).insetBy(dx: -6, dy: -6)
    }

    /// Generous target for files being dragged toward the notch.
    private var dropApproachZone: NSRect {
        rect(for: model.compactSize).insetBy(dx: -60, dy: -36)
    }

    private func setInteractive(_ on: Bool) {
        if panel.ignoresMouseEvents == on { panel.ignoresMouseEvents = !on }
    }

    // MARK: - Pointer

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e, local: false) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask.union(.scrollWheel), handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e, local: true) }
            return e
        }) { monitors.append(l) }
    }

    /// The band under the bezel where the pointer could reach the island, its bubble or a drop target.
    private var proximityZone: NSRect {
        let f = screen.frame
        return NSRect(x: f.midX - 480, y: f.maxY - 220, width: 960, height: 220)
    }

    private func handle(_ e: NSEvent, local: Bool) {
        switch e.type {
        case .scrollWheel:
            if e.window === panel { handleScroll(e) }
            return
        case .mouseMoved:
            // The global monitor sees every pointer move on the Mac. Resting, closed, nothing pending and the
            // pointer nowhere near: nothing can change, so skip the hit-testing entirely.
            if model.mode == .compact, !model.hovering, expandWork == nil, pollTimer == nil,
               panel.ignoresMouseEvents, !proximityZone.contains(NSEvent.mouseLocation) { return }
        case .leftMouseUp:
            holdWork?.cancel()
            holdWork = nil
            holdStart = nil
            if holding {
                holding = false
                VoiceInput.shared.finish()
            }
        case .leftMouseDragged:
            if let start = holdStart, hypot(Self.pointer.x - start.x, Self.pointer.y - start.y) > 6 {
                holdWork?.cancel()
                holdWork = nil
                holdStart = nil
            }
        case .leftMouseDown, .rightMouseDown:
            dragBaseline = NSPasteboard(name: .drag).changeCount
            let p = Self.pointer
            let inside = islandZone.contains(p) || (bubbleZone?.contains(p) ?? false)
            dragStartedInside = local && inside
            if e.type == .leftMouseDown, local, holdZone.contains(p) { scheduleHold(at: p) }
            if !local, !inside, model.mode != .compact, model.mode != .alert {
                // Clicking away from the planner is "Later": it leaves Flow's card on Home.
                if model.mode == .expanded(.plan) { MorningPlanner.shared.later() } else { model.collapse() }
            }
            updatePolling()
        default:
            break
        }
        evaluateMouse()
    }

    func evaluateMouse() {
        let p = Self.pointer
        let now = CACurrentMediaTime()
        let dt = now - lastPointTime
        if dt > 0.004 {
            let d = hypot(p.x - lastPoint.x, p.y - lastPoint.y)
            // Smoothed, and decaying when the pointer stops (no events arrive for a still mouse).
            speed = dt > 0.15 ? CGFloat(d / dt) * 0.3 : speed * 0.5 + CGFloat(d / dt) * 0.5
            lastPoint = p
            lastPointTime = now
        }
        if lastMode != .compact, model.mode == .compact, islandZone.contains(p) { hoverNeedsExit = true }
        lastMode = model.mode
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        let dragPB = NSPasteboard(name: .drag)
        let fileDrag = buttonDown && !dragStartedInside && dragPB.changeCount != dragBaseline
            && (dragPB.types?.contains(.fileURL) ?? false)

        let inIsland = islandZone.contains(p)
        let inBubble = bubbleZone?.contains(p) ?? false
        setInteractive(inIsland || inBubble)

        let approaching = (model.mode == .compact || model.mode == .alert) ? dropApproachZone.contains(p) : inIsland
        if fileDrag, model.mode != .drop, approaching {
            cancelExpand()
            model.openDrop()
            setInteractive(true)
            return
        }

        switch model.mode {
        case .compact:
            if buttonDown { return }
            if hoverNeedsExit {
                if inIsland { return }
                hoverNeedsExit = false
            }
            if inIsland {
                model.setHovering(true)
                // Hover opens Home — the hub. Live activities are a tab away, so none of them takes the island over.
                if Prefs.shared.expandOnHover { scheduleExpand(.glance) }
            } else if inBubble, let s = model.secondary {
                model.setHovering(false)
                if Prefs.shared.expandOnHover { scheduleExpand(.activity(s)) }
            } else {
                cancelExpand()
                model.setHovering(false)
            }
        case .alert:
            if inIsland, !holdingAlert {
                holdingAlert = true
                model.holdAlert()
            } else if !inIsland, holdingAlert {
                holdingAlert = false
                model.releaseAlert()
            }
        case .expanded:
            if inIsland || MenuTracking.active {
                // A menu opened from the island (an output device, say) lives outside it: stay open under it.
                cancelCollapse()
            } else if dragStartedInside && buttonDown {
                cancelCollapse()   // dragging a shelf item out — stay open until it lands
            } else if !model.sticky {
                scheduleCollapse(after: 0.3)
            }
        case .drop:
            if inIsland {
                cancelCollapse()
            } else {
                scheduleCollapse(after: fileDrag ? 0.5 : 0.25)
            }
        case .search, .mirror:
            break
        }
        if model.mode != .alert { holdingAlert = false }
    }

    private func scheduleExpand(_ focus: IslandFocus?) {
        guard expandWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.expandWork = nil
            let p = Self.pointer
            guard self.model.mode == .compact, NSEvent.pressedMouseButtons & 1 == 0,
                  self.islandZone.contains(p) || (self.bubbleZone?.contains(p) ?? false) else { return }
            // Still moving fast — passing through on the way to the menu bar, not resting on the island. Look again shortly.
            if self.speed > 420, CACurrentMediaTime() - self.lastPointTime < 0.12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in self?.scheduleExpand(focus) }
                return
            }
            self.model.expand(focus)
            Haptics.snap()
        }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, Prefs.shared.hoverDelay), execute: work)
    }

    private func cancelExpand() {
        expandWork?.cancel()
        expandWork = nil
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        guard collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWork = nil
            if !self.islandZone.contains(Self.pointer) { self.model.collapse() }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    /// Light polling only while something is happening (open, hovering, or a drag in flight);
    /// drag sessions from other apps don't always reach event monitors.
    private func updatePolling() {
        let needed = model.mode != .compact || model.hovering || NSEvent.pressedMouseButtons != 0
        if needed, pollTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.evaluateMouse()
                    if NSEvent.pressedMouseButtons & 1 == 0 { self.dragStartedInside = false }
                    self.updatePolling()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t
        } else if !needed, let t = pollTimer {
            t.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - Trackpad

    /// Swipe down on the notch to open. While open: swipe sideways between live activities,
    /// swipe up to close — or, over Now Playing, scroll to change the volume.
    private func handleScroll(_ e: NSEvent) {
        guard Prefs.shared.gestures, e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return }
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
            scrollX = 0
            scrollY = 0
            rewindTravel = 0
            scrollConsumed = false
        }
        let natural = e.isDirectionInvertedFromDevice
        let dx = natural ? e.scrollingDeltaX : -e.scrollingDeltaX   // + = fingers move right
        let dy = natural ? e.scrollingDeltaY : -e.scrollingDeltaY   // + = fingers move down
        scrollX += dx
        scrollY += dy
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            scrollConsumed = false
            return
        }

        switch model.mode {
        case .compact:
            guard !scrollConsumed, scrollY > 16 else { return }
            scrollConsumed = true
            cancelExpand()
            model.expand(sticky: true)
            Haptics.snap()
        case .expanded(.controls):
            break
        case .expanded(.glance) where scrollY > 44 && abs(scrollY) > abs(scrollX) * 1.6 && !scrollConsumed:
            // Pull Home down: the sheet.
            scrollConsumed = true
            model.open(.sheet)
            Haptics.snap()
        case .expanded(.sheet) where scrollY < -36 && abs(scrollY) > abs(scrollX) * 1.6 && !scrollConsumed:
            // Push it back up: Home.
            scrollConsumed = true
            model.select(.glance)
        case .expanded(.rewind) where abs(scrollX) >= abs(scrollY):
            // Two fingers sideways scrub through the day: a moment per 12 points of travel.
            rewindTravel += dx
            while abs(rewindTravel) >= 12 {
                RewindModel.shared.step(rewindTravel > 0 ? -1 : 1)
                rewindTravel -= rewindTravel > 0 ? 12 : -12
            }
        case .expanded(.activity(.nowPlaying)) where abs(scrollY) > abs(scrollX):
            adjustVolume(by: -dy)
        case .expanded:
            guard !scrollConsumed else { return }
            if abs(scrollX) > 46, abs(scrollX) > abs(scrollY) * 1.6 {
                scrollConsumed = true
                model.cycleFocus(scrollX < 0 ? 1 : -1)
            } else if scrollY < -28, abs(scrollY) > abs(scrollX) * 1.6 {
                scrollConsumed = true
                model.collapse()
            }
        default:
            break
        }
    }

    private func adjustVolume(by fingerTravel: CGFloat) {
        let volume = SystemVolume.shared
        guard volume.available else { return }
        let old = volume.muted ? 0 : volume.volume
        let new = min(1, max(0, old + Double(fingerTravel) * 0.0045))
        guard abs(new - old) > 0.0005 else { return }
        if (new == 0 || new == 1) && old != new { Haptics.snap() }
        IslandManager.shared.noteOwnVolumeChange()
        volume.set(new)
        model.flashInlineVolume()
    }
}

/// Whether an NSMenu (from the island or anywhere in Atoll) is open right now.
@MainActor
enum MenuTracking {
    private(set) static var active = false
    private static var observers: [Any] = []

    static func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { active = true }
        })
        observers.append(nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { active = false }
        })
    }
}
