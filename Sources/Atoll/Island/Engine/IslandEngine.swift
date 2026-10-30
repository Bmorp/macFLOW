import AppKit
import SwiftUI
import QuartzCore

/// Island Engine 2.0: the island's motion runs in the render server, not on the main thread.
///
/// The silhouette, rim and content light are Core Animation layers the engine owns; the SwiftUI content lives in
/// two hosts (compact and open) inside a container masked by the same silhouette. When the island changes state,
/// the engine reads the model once, solves every channel of the move with one spring (`SpringSolver`), bakes the
/// samples into keyframe animations and adds them all in one transaction. From then on the main thread does
/// nothing: a stall after the commit can't hitch the shape, and one before it only delays the start.
///
/// AppKit owns the hosts' layers, so the engine never sets their model transform: it only adds animations whose
/// final value is identity, which is also the right value at rest (hit-testing, carets and VoiceOver stay exact).
@MainActor
final class IslandEngine {
    let model: IslandModel
    private unowned let container: NSView

    private let back = EngineLayerView(frame: .zero)
    private let front = EngineLayerView(frame: .zero)
    private let lightView = EngineLayerView(frame: .zero)
    private let bridgeView = EngineLayerView(frame: .zero)
    private let bridge = LiquidBridge()
    private let clip = ContentClipView(frame: .zero)
    let compactHost: IslandHostView<CompactRoot>
    let openHost: IslandHostView<OpenRoot>
    let bubbleHost: IslandHostView<BubbleRoot>

    private let fill = SilhouetteLayers(color: NSColor.black.cgColor)
    private let clipShape = SilhouetteLayers(color: NSColor.black.cgColor)
    private let rimHolder = CALayer()
    private let rim = CALayer()
    private let rimMask = CALayer()
    private let rimFade = CAGradientLayer()
    private let rimSolid = CALayer()
    private let radial = CALayer()
    private let rising = CALayer()

    /// The move in progress, if any. Its exact state at any moment comes from the solver.
    private struct Flight {
        let from: IslandFrame
        let velocity: IslandFrame
        let to: IslandFrame
        let curve: MotionCurve
        var begin: CFTimeInterval
        let duration: Double

        func state(at time: CFTimeInterval) -> (IslandFrame, IslandFrame) {
            let t = max(0, time - begin)
            guard t < duration else { return (to, .zero) }
            var x = to, v = IslandFrame.zero
            for i in 0..<IslandFrame.channels {
                let r = curve.evaluate(from: from[i], to: to[i], v0: velocity[i], at: t)
                x[i] = r.value
                v[i] = r.velocity
            }
            return (x, v)
        }
    }
    private var flight: Flight?
    /// Where the island rests (or is heading).
    private var target = IslandFrame.zero
    /// What each host's content is laid out for — the size its zoom is measured against.
    private var openTarget = CGSize(width: 1, height: 1)
    private var compactTarget = CGSize(width: 1, height: 1)
    private var openVisible = false
    /// Whether the open host's content is an open state (not a wide alert): closing from one holds it until landing.
    private var heldIsOpen = false
    private var lastKey = ""

    /// A drag that has the island by the hand: the shape is set per event from here, not baked.
    private struct Interaction {
        let from: IslandFrame
        let to: IslandFrame
        let fromMode: IslandMode
        let preview: IslandMode?
        var progress = 0.0
        var slide = 0.0
    }
    private var interaction: Interaction?
    /// How fast each channel was moving when the finger lifted: the spring that follows starts from it.
    private var launchVelocity = IslandFrame.zero
    /// The spring a released drag settles with when the model asks for none (a drag that was let go).
    private var followUpToken: SpringToken?
    /// A drag already showed the next place, so it doesn't slide in again when the drag completes.
    private var suppressSlide = false
    /// Runs once when the next move arrives (or at once if nothing moves): a haptic that belongs to the landing.
    var onLanding: (() -> Void)?
    private var lightColor: CGColor?
    private var rimAlpha: CGFloat = -1
    private var dirty = true
    private var observer: CFRunLoopObserver?

    private var notchHeight: CGFloat { model.notch.height }
    private var centerX: CGFloat { container.bounds.midX }

    init(model: IslandModel, container: NSView) {
        self.model = model
        self.container = container
        compactHost = IslandHostView(rootView: CompactRoot(model: model))
        openHost = IslandHostView(rootView: OpenRoot(model: model))
        bubbleHost = IslandHostView(rootView: BubbleRoot(model: model, drawsBridge: false))
        model.engineDriven = true
        build()
        observe()
        installRunLoopObserver()
        sync()
    }

    func teardown() {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
    }

    // MARK: - Views and layers

    private func build() {
        let b = container.bounds
        for h in [bubbleHost, compactHost, openHost] as [NSView] {
            h.frame = b
            h.autoresizingMask = [.width, .height]
        }
        compactHost.sizingOptions = []
        openHost.sizingOptions = []
        bubbleHost.sizingOptions = []
        for v in [back, front, clip, bridgeView] as [NSView] { v.frame = b }
        lightView.frame = b
        // The bridge sits under the bubble's icon (which SwiftUI draws) and under the island.
        container.addSubview(bridgeView)
        bridgeView.root.addSublayer(bridge.layer)
        container.addSubview(bubbleHost)
        container.addSubview(back)
        container.addSubview(clip)
        clip.addSubview(lightView)
        clip.addSubview(compactHost)
        clip.addSubview(openHost)
        container.addSubview(front)

        back.root.addSublayer(fill.root)
        clip.mask.addSublayer(clipShape.root)

        // Content light: pre-tinted glow images the GPU only scales (no gradients redrawn per frame).
        for l in [radial, rising] {
            l.delegate = NoActions.shared
            l.contentsGravity = .resize
            lightView.root.addSublayer(l)
        }
        lightView.root.opacity = 0

        // The rim: a hairline along the sides and bottom, faded toward the top so the island melts into the bezel.
        for l in [rimHolder, rim, rimMask, rimFade, rimSolid] as [CALayer] { l.delegate = NoActions.shared }
        rim.borderWidth = 1
        rim.cornerCurve = .continuous
        rim.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        rimFade.colors = [NSColor.clear.cgColor, NSColor.white.cgColor]
        rimFade.startPoint = CGPoint(x: 0.5, y: 0)
        rimFade.endPoint = CGPoint(x: 0.5, y: 1)
        rimSolid.backgroundColor = NSColor.white.cgColor
        rimMask.isGeometryFlipped = true
        rimMask.addSublayer(rimFade)
        rimMask.addSublayer(rimSolid)
        rimHolder.mask = rimMask
        rimHolder.addSublayer(rim)
        front.root.addSublayer(rimHolder)

        compactHost.accepts = { [weak self] p in
            guard let self else { return false }
            return self.model.isCompact && self.islandRect.contains(p)
        }
        openHost.accepts = { [weak self] p in
            guard let self else { return false }
            return !self.model.isCompact && self.islandRect.contains(p)
        }
        bubbleHost.accepts = { [weak self] p in
            guard let self, self.model.showsBubble else { return false }
            let d = self.model.bubbleDiameter
            let b = self.container.bounds
            return NSRect(x: b.midX + self.model.bubbleOffset - d / 2 - 6, y: b.maxY - d - 6, width: d + 12, height: d + 12).contains(p)
        }
        layoutStatic()
    }

    /// The island's resting rect in the hosts' superview (bottom-up) coordinates.
    private var islandRect: NSRect {
        let s = model.spec.size
        let b = container.bounds
        return NSRect(x: b.midX - s.width / 2, y: b.maxY - s.height, width: s.width, height: s.height)
    }

    /// Container-sized layers: set once (and again if the panel ever changes size).
    private func layoutStatic() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = container.bounds
        fill.root.frame = CGRect(origin: .zero, size: b.size)
        clipShape.root.frame = CGRect(origin: .zero, size: b.size)
        rimHolder.frame = CGRect(origin: .zero, size: b.size)
        rimMask.frame = rimHolder.bounds
        CATransaction.commit()
    }

    // MARK: - Watching the model

    /// Marks the engine dirty when anything that shapes the island changes; the sync runs before this run-loop
    /// turn's commit (`installRunLoopObserver`), in the same transaction as SwiftUI's update of the content.
    private func observe() {
        withObservationTracking {
            _ = model.spec
            _ = model.mode
            _ = model.isOpen
            _ = model.rimStrength
            _ = model.presentationKey
            _ = model.compactSize
            _ = model.previewMode
            _ = model.showsBubble
            _ = model.splitProgress
            _ = model.bubbleOffset
            _ = model.bubbleDiameter
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.dirty else { return }
                self.dirty = true
                // A change made inside a display cycle (after this turn's observer ran) still needs a turn.
                DispatchQueue.main.async { [weak self] in self?.syncIfDirty() }
            }
        }
    }

    private func installRunLoopObserver() {
        // Order 0: before AppKit's display cycle and Core Animation's commit, so the animations added here commit
        // with the content SwiftUI lays out in the same turn.
        let o = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncIfDirty() }
        }
        if let o { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes) }
        observer = o
    }

    func syncIfDirty() {
        guard dirty else { return }
        sync()
    }

    // MARK: - Sync

    private var reduceMotion: Bool { Access.reduceMotion }

    /// Reads the model and moves the island to match it.
    func sync() {
        dirty = false
        observe()
        #if DEBUG || ATOLL_PROBE
        IslandTrace.syncs += 1
        #endif
        if let i = interaction {
            // Something else moved the island under the finger (an alert, a hover): the drag is over.
            if model.mode == i.fromMode { syncInteractive(i); return }
            interaction = nil
            model.setPreview(nil)
            launchVelocity = .zero
        }
        let spec = model.spec
        let mode = model.mode
        let key = model.presentationKey
        let shownOpen = mode != .compact
        let token = model.takePendingMotion() ?? followUpToken
        followUpToken = nil
        let landing = onLanding
        onLanding = nil
        let now = CACurrentMediaTime()

        var to = IslandFrame(width: Double(spec.size.width), height: Double(spec.size.height), shoulder: Double(spec.shoulder),
                             corner: Double(spec.corner), slide: 0, rim: model.rimStrength, light: model.isOpen ? 1 : 0)
        if !to.width.isFinite || !to.height.isFinite { to = target }

        // Content: what each host lays out, and so what its zoom is measured against.
        let wasOpenVisible = openVisible
        let previousHeldOpen = heldIsOpen
        if shownOpen {
            openTarget = spec.size
            heldIsOpen = model.isOpen
        }
        compactTarget = model.compactSize
        openVisible = shownOpen
        updateLight()
        updateRimColor()
        syncBridge(now: now)

        var (start, velocity) = flight?.state(at: now) ?? (target, launchVelocity)
        launchVelocity = .zero
        // Moving between open places: the new one slides in from the side you're heading (DESIGN.md › 5.2).
        if key != lastKey, shownOpen, wasOpenVisible, model.switchDirection != 0, !reduceMotion, !suppressSlide {
            start.slide = 34 * Double(model.switchDirection)
            velocity.slide = 0
        }
        suppressSlide = false
        lastKey = key
        let first = target == .zero
        target = to

        // Closing from an open state: the open content shrinks with the shape and hands over as it lands.
        let holdOpen = wasOpenVisible && !shownOpen && previousHeldOpen && !reduceMotion

        let curve = token.map { MotionCurve($0, reduceMotion: reduceMotion) } ?? flight?.curve
        guard !first, let curve, start != to || velocity != .zero else {
            jump(to)
            landing?()
            return
        }
        bake(from: start, velocity: velocity, to: to, curve: curve, now: now, holdOpen: holdOpen || holdingOpen(at: now), landing: landing)
    }

    private var bridgeWasVisible = false

    /// The liquid neck to the bubble: it springs out once the island has closed over (as `LiquidSplit` did), follows
    /// the activity count when it changes, and is gone the moment the island opens.
    private func syncBridge(now: CFTimeInterval) {
        let visible = model.showsBubble
        let target = visible ? Double(model.splitProgress) : 0
        let params = LiquidBridge.Params(centerX: centerX, islandWidth: model.compactSize.width, height: model.notch.height,
                                         diameter: model.bubbleDiameter, restOffset: model.bubbleOffset,
                                         softness: reduceMotion ? 0.5 : 13)
        var token: SpringToken?
        var delay = 0.0
        if visible {
            token = Motion.Token.split
            if !bridgeWasVisible { delay = IslandView.bubbleReturn }
        }
        bridgeWasVisible = visible
        bridge.update(params, target: target, visible: visible, token: token, delay: delay, reduceMotion: reduceMotion,
                      now: now, frameRate: frameRate)
    }

    /// Whether a close's hand-over is still pending (a retarget while closing keeps it).
    private var swapAt: CFTimeInterval = 0
    private func holdingOpen(at now: CFTimeInterval) -> Bool { !openVisible && swapAt > now }

    /// Puts everything at rest at `f`, with no animation.
    private func jump(_ f: IslandFrame) {
        flight = nil
        swapAt = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.stop()
        clipShape.stop()
        for l in [rim, rimFade, rimSolid, radial, rising, lightView.root] as [CALayer] { l.removeAllAnimations() }
        for h in [compactHost, openHost] as [NSView] {
            h.layer?.removeAnimation(forKey: "island.transform")
            h.layer?.removeAnimation(forKey: "island.swap")
        }
        applyStatic(f)
        CATransaction.commit()
        setVisibility()
    }

    /// Sets every engine-owned layer to `f` (inside the caller's transaction, actions off).
    private func applyStatic(_ f: IslandFrame) {
        let g = IslandOutlineGeometry(f, centerX: centerX)
        fill.apply(g)
        clipShape.apply(g)
        applyRim(rimValues(f, g))
        let lights = IslandGeometry.light(f, centerX: centerX)
        radial.frame = lights.radial
        rising.frame = lights.rising
        lightView.root.opacity = Float(min(1, max(0, f.light)))
    }

    private func setVisibility() {
        // Hidden, not gone: at 0 a layer's pixels are thrown away, and showing it again redraws everything.
        compactHost.alphaValue = openVisible ? 0.001 : 1
        openHost.alphaValue = openVisible ? 1 : 0.001
    }

    // MARK: - Baking

    static let sampleRate = 240.0

    private var frameRate: CAFrameRateRange {
        let p = ProcessInfo.processInfo
        if p.isLowPowerModeEnabled || p.thermalState.rawValue >= ProcessInfo.ThermalState.fair.rawValue {
            return CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
        return CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    }

    private func bake(from x0: IslandFrame, velocity v0: IslandFrame, to: IslandFrame, curve: MotionCurve, now: CFTimeInterval, holdOpen: Bool, landing: (() -> Void)? = nil) {
        let state = IslandTrace.signposter.beginInterval("bake")
        defer { IslandTrace.signposter.endInterval("bake", state) }
        #if DEBUG || ATOLL_PROBE
        IslandTrace.bakes += 1
        #endif
        var duration = 0.0
        for i in 0..<IslandFrame.channels {
            duration = max(duration, curve.duration(from: x0[i], to: to[i], v0: v0[i], epsilon: IslandFrame.epsilon[i]))
        }
        guard duration > 0 else { jump(to); landing?(); return }
        let n = max(2, Int((duration * Self.sampleRate).rounded(.up)) + 1)
        let total = Double(n - 1) / Self.sampleRate
        let f = Flight(from: x0, velocity: v0, to: to, curve: curve, begin: now, duration: total)
        var frames: [IslandFrame] = (0..<n).map { f.state(at: now + Double($0) / Self.sampleRate).0 }
        frames[n - 1] = to
        flight = f

        // The hand-over from the open host to the compact one: the first moment the shape is within 10 pt of its
        // closed height (≈ Motion.closeSwap from a resting Home), from the solver, so it's frame-exact.
        var swap = 0.0
        if holdOpen {
            let landing = Double(compactTarget.height) + 10
            swap = Double(frames.firstIndex { $0.height <= landing } ?? n - 1) / Self.sampleRate
            if swap == 0, frames[0].height > landing { swap = Motion.closeSwap }
        }

        // The landing: the first moment the shape is within a point of where it's going.
        if let landing {
            let arrived = frames.firstIndex { abs($0.width - to.width) <= 1 && abs($0.height - to.height) <= 1 } ?? n - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(arrived) / Self.sampleRate) { landing() }
        }

        let cx = centerX
        let outlines = frames.map { IslandOutlineGeometry($0, centerX: cx) }
        let bake = Bake(duration: total, frameRate: frameRate)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.animate(outlines, bake: bake)
        clipShape.animate(outlines, bake: bake)

        // Rim.
        let rims = zip(frames, outlines).map { rimValues($0.0, $0.1) }
        applyRim(rims[n - 1])
        bake.add(rim, "bounds", rims.map { NSValue(rect: CGRect(origin: .zero, size: $0.rect.size)) })
        bake.add(rim, "position", rims.map { NSValue(point: CGPoint(x: $0.rect.midX, y: $0.rect.midY)) })
        bake.add(rim, "cornerRadius", rims.map { $0.radius as NSNumber })
        if rims.contains(where: { $0.opacity != rims[n - 1].opacity }) {
            bake.add(rim, "opacity", rims.map { $0.opacity as NSNumber })
        } else { rim.removeAnimation(forKey: "opacity") }
        if rims.contains(where: { $0.fade != rims[n - 1].fade }) {
            bake.add(rimFade, "bounds", rims.map { NSValue(rect: CGRect(x: 0, y: 0, width: $0.fadeWidth, height: $0.fade.1 - $0.fade.0)) })
            bake.add(rimFade, "position", rims.map { NSValue(point: CGPoint(x: $0.fadeWidth / 2, y: ($0.fade.0 + $0.fade.1) / 2)) })
            bake.add(rimSolid, "position", rims.map { NSValue(point: CGPoint(x: $0.fadeWidth / 2, y: $0.fade.1 + $0.solidHeight / 2)) })
        } else {
            for l in [rimFade, rimSolid] { l.removeAnimation(forKey: "bounds"); l.removeAnimation(forKey: "position") }
        }

        // Content light.
        let lights = frames.map { IslandGeometry.light($0, centerX: cx) }
        radial.frame = lights[n - 1].radial
        rising.frame = lights[n - 1].rising
        bake.add(radial, "bounds", lights.map { NSValue(rect: CGRect(origin: .zero, size: $0.radial.size)) })
        bake.add(radial, "position", lights.map { NSValue(point: CGPoint(x: $0.radial.midX, y: $0.radial.midY)) })
        bake.add(rising, "bounds", lights.map { NSValue(rect: CGRect(origin: .zero, size: $0.rising.size)) })
        bake.add(rising, "position", lights.map { NSValue(point: CGPoint(x: $0.rising.midX, y: $0.rising.midY)) })
        let lightLevels = frames.map { min(1, max(0, $0.light)) }
        lightView.root.opacity = Float(lightLevels[n - 1])
        if lightLevels.contains(where: { $0 != lightLevels[n - 1] }) {
            bake.add(lightView.root, "opacity", lightLevels.map { $0 as NSNumber })
        } else { lightView.root.removeAnimation(forKey: "opacity") }

        // Content: each host scaled with the shape about the top centre (and the open one slid between places).
        bakeTransform(compactHost, frames: frames, target: compactTarget, slides: false, bake: bake)
        bakeTransform(openHost, frames: frames, target: openTarget, slides: true, bake: bake)

        // Which host shows: the model says where it ends; a hold keeps the open one up until the hand-over.
        setVisibility()
        swapAt = holdOpen ? now + swap : 0
        if holdOpen {
            bake.hold(openHost.layer!, "opacity", value: Float(1), until: swap, key: "island.swap")
            bake.hold(compactHost.layer!, "opacity", value: Float(0.001), until: swap, key: "island.swap")
        } else {
            openHost.layer?.removeAnimation(forKey: "island.swap")
            compactHost.layer?.removeAnimation(forKey: "island.swap")
        }
        CATransaction.commit()
        IslandTrace.signposter.emitEvent("island move", "\(n) samples, \(Int(total * 1000)) ms")
        readBackBeginTime()
    }

    /// A Core Animation clock starts when the transaction commits, after this turn's layout. Read the real start
    /// back so a later interruption evaluates the solver at the moment actually on screen.
    private func readBackBeginTime() {
        DispatchQueue.main.async { [weak self] in
            guard let self, var f = self.flight, let a = self.fill.body.animation(forKey: "bounds"), a.beginTime > 0 else { return }
            f.begin = a.beginTime
            self.flight = f
        }
    }

    /// How a host's layer is transformed to show the content of size `target` inside a shape in state `f`.
    /// A layer's transform acts in its superlayer's orientation, about the anchor (which sits at `position`), whatever
    /// AppKit chose for the anchor and for the host's own flipping. So: the panel's top centre, in the superlayer.
    private func contentTransform(_ layer: CALayer, _ f: IslandFrame, target: CGSize, slides: Bool) -> CATransform3D? {
        guard let superlayer = layer.superlayer else { return nil }
        let sb = superlayer.bounds
        let topCenter = CGPoint(x: sb.midX, y: superlayer.isGeometryFlipped ? sb.minY : sb.maxY)
        let s = IslandGeometry.zoom(live: f.size, target: target)
        return IslandGeometry.scale(s, about: topCenter, anchor: layer.position, dx: slides ? CGFloat(f.slide) : 0)
    }

    private func bakeTransform(_ host: NSView, frames: [IslandFrame], target: CGSize, slides: Bool, bake: Bake) {
        guard let layer = host.layer, layer.superlayer != nil else { return }
        let values = frames.map { f in NSValue(caTransform3D: contentTransform(layer, f, target: target, slides: slides) ?? CATransform3DIdentity) }
        let identity = CATransform3DIdentity
        if values.allSatisfy({ CATransform3DEqualToTransform($0.caTransform3DValue, identity) }) {
            layer.removeAnimation(forKey: "island.transform")
        } else {
            bake.add(layer, "transform", values, key: "island.transform")
        }
    }

    // MARK: - Interactive drags

    /// Whether a finger has the island right now.
    var isInteracting: Bool { interaction != nil }

    /// The island's resting frame in `mode`.
    func frame(for mode: IslandMode) -> IslandFrame {
        let spec = model.spec(for: mode)
        let open = mode != .compact && !(mode == .alert && (model.alert?.kind.isWide ?? true))
        return IslandFrame(width: Double(spec.size.width), height: Double(spec.size.height), shoulder: Double(spec.shoulder),
                           corner: Double(spec.corner), slide: 0, rim: open ? (Access.increaseContrast ? 1 : 0.85) : 0, light: open ? 1 : 0)
    }

    /// How far along a drag shows: rubber-banded, and only ever stretching the island past its larger end. It never
    /// shrinks below the closed island (a shape shorter than the notch isn't a thing) and never grows past what's open
    /// for more than a whisper.
    private func shownProgress(_ i: Interaction) -> Double {
        let p = InteractiveTransition.band(i.progress)
        return i.to.height >= i.from.height ? max(0, p) : min(1, p)
    }

    /// Where the island is on screen right now.
    private func shownFrame(at now: CFTimeInterval) -> IslandFrame {
        if let i = interaction {
            var f = IslandFrame.mix(i.from, i.to, shownProgress(i))
            f.slide = i.slide
            return f
        }
        return flight?.state(at: now).0 ?? target
    }

    /// Takes the island by the hand: from wherever it is now (even mid-spring) toward `destination`. With `preview`,
    /// the open host shows that place as a miniature that grows with the finger.
    func beginInteractive(toward destination: IslandMode, preview: Bool) {
        guard interaction == nil else { return }
        let now = CACurrentMediaTime()
        let from = shownFrame(at: now)
        let i = Interaction(from: from, to: frame(for: destination), fromMode: model.mode, preview: preview ? destination : nil)
        flight = nil
        swapAt = 0
        target = from
        interaction = i
        if preview { model.setPreview(destination) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [rim, rimFade, rimSolid, radial, rising, lightView.root] as [CALayer] { l.removeAllAnimations() }
        for h in [compactHost, openHost] as [NSView] { h.layer?.removeAnimation(forKey: "island.swap") }
        CATransaction.commit()
        prepareInteractiveContent(i)
        render(i)
    }

    /// The finger moved: `progress` is how far toward the destination (0…1, unbounded: the island rubber-bands
    /// past either end) and `slide` the content's sideways offset.
    func updateInteractive(progress: Double, slide: Double = 0) {
        guard var i = interaction else { return }
        i.progress = progress
        i.slide = reduceMotion ? 0 : slide
        interaction = i
        render(i)
    }

    /// The finger lifted at `velocity` (progress per second). Completing runs `apply` (the model change) and springs
    /// on from where the finger left the island, with the finger's speed; otherwise the island springs back.
    func endInteractive(velocity: Double, commit: Bool, springBack: SpringToken, slideVelocity: Double = 0, apply: () -> Void) {
        guard let i = interaction else { if commit { apply() }; return }
        let shown = shownFrame(at: CACurrentMediaTime())
        interaction = nil
        flight = nil
        target = shown
        var v = IslandFrame.difference(i.from, i.to).scaled(by: (i.progress == shownProgress(i) ? velocity : 0))
        v.slide = slideVelocity
        launchVelocity = v
        if commit {
            suppressSlide = i.preview != nil
            apply()
            model.setPreview(nil)
        } else {
            followUpToken = springBack
            model.setPreview(nil)
        }
        dirty = true
    }

    /// Opens the right host for the drag and measures its content against the place it shows.
    private func prepareInteractiveContent(_ i: Interaction) {
        if let preview = i.preview {
            openTarget = model.spec(for: preview).size
            heldIsOpen = preview != .alert
            openVisible = true
        } else {
            openVisible = i.fromMode != .compact
        }
        setVisibility()
    }

    /// Model changes during a drag that don't end it (live content, a new tint): keep the content right.
    private func syncInteractive(_ i: Interaction) {
        updateLight()
        updateRimColor()
        prepareInteractiveContent(i)
        render(i)
    }

    /// Draws the drag: every engine-owned layer set directly to the frame, and each host held at its scale.
    private func render(_ i: Interaction) {
        var f = IslandFrame.mix(i.from, i.to, shownProgress(i))
        f.slide = i.slide
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyStatic(f)
        holdContent(compactHost, f, target: compactTarget, slides: false)
        holdContent(openHost, f, target: openTarget, slides: true)
        CATransaction.commit()
    }

    /// Pins a host at its transform for this frame with a never-ending animation (the model transform stays identity,
    /// which AppKit owns); the next event replaces it, and baking or a jump removes it.
    private func holdContent(_ host: NSView, _ f: IslandFrame, target: CGSize, slides: Bool) {
        guard let layer = host.layer, let t = contentTransform(layer, f, target: target, slides: slides) else { return }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: t)
        a.toValue = NSValue(caTransform3D: t)
        a.duration = 1000
        a.isRemovedOnCompletion = false
        a.fillMode = .forwards
        layer.add(a, forKey: "island.transform")
    }

    // MARK: - Rim and light

    private struct RimValues: Equatable {
        var rect: CGRect
        var radius: CGFloat
        var opacity: Float
        /// Where the top fade starts and ends (y), as `RimLight` places it.
        var fade: (CGFloat, CGFloat)
        var fadeWidth: CGFloat
        var solidHeight: CGFloat
        static func == (a: RimValues, b: RimValues) -> Bool {
            a.rect == b.rect && a.radius == b.radius && a.opacity == b.opacity && a.fade == b.fade
        }
    }

    private func rimValues(_ f: IslandFrame, _ g: IslandOutlineGeometry) -> RimValues {
        // A 1-pt line centred on the outline (half inside, half out), as the stroked `IslandOutline` draws it.
        let r = CGRect(x: g.body.minX - 0.5, y: g.body.minY, width: g.body.width + 1, height: g.body.height + 0.5)
        let h = max(CGFloat(f.height), 1)
        let start = min(0.9, notchHeight * 0.5 / h)
        let end = min(1, max(start + 0.02, (notchHeight + 16) / h))
        let b = container.bounds
        return RimValues(rect: r, radius: g.cornerRadius > 0 ? g.cornerRadius + 0.5 : 0, opacity: Float(min(1, max(0, f.rim))),
                         fade: (start * h, end * h), fadeWidth: b.width, solidHeight: b.height)
    }

    private func applyRim(_ v: RimValues) {
        rim.bounds = CGRect(origin: .zero, size: v.rect.size)
        rim.position = CGPoint(x: v.rect.midX, y: v.rect.midY)
        rim.cornerRadius = v.radius
        rim.opacity = v.opacity
        rimFade.bounds = CGRect(x: 0, y: 0, width: v.fadeWidth, height: v.fade.1 - v.fade.0)
        rimFade.position = CGPoint(x: v.fadeWidth / 2, y: (v.fade.0 + v.fade.1) / 2)
        rimSolid.bounds = CGRect(x: 0, y: 0, width: v.fadeWidth, height: v.solidHeight)
        rimSolid.position = CGPoint(x: v.fadeWidth / 2, y: v.fade.1 + v.solidHeight / 2)
    }

    private func updateRimColor() {
        let a: CGFloat = Access.increaseContrast ? 0.32 : 0.13
        guard a != rimAlpha else { return }
        rimAlpha = a
        rim.borderColor = NSColor.white.withAlphaComponent(a).cgColor
    }

    /// The light's colour is whatever's on show; a new colour crossfades over half a second (as ContentLight did).
    private func updateLight() {
        guard case .tint(let c) = model.rim else { return }
        let color = NSColor(c).usingColorSpace(.sRGB) ?? .white
        let cg = color.cgColor
        if let lightColor, lightColor == cg { return }
        let animated = lightColor != nil
        lightColor = cg
        let radialImage = Self.tinted(Glow.radial, color, alpha: 0.26 * 0.75)
        let risingImage = Self.tinted(Glow.rising, color, alpha: 0.05 * 0.75)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, image) in [(radial, radialImage), (rising, risingImage)] {
            if animated {
                let a = CABasicAnimation(keyPath: "contents")
                a.fromValue = layer.presentation()?.contents ?? layer.contents
                a.toValue = image
                a.duration = 0.5
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(a, forKey: "contents")
            }
            layer.contents = image
        }
        CATransaction.commit()
    }

    /// A glow image (white, shaped by alpha) in one colour.
    private static func tinted(_ image: NSImage, _ color: NSColor, alpha: CGFloat) -> CGImage? {
        guard let src = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = src.width, h = src.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(src, in: rect)
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(color.withAlphaComponent(color.alphaComponent * alpha).cgColor)
        ctx.fill(rect)
        return ctx.makeImage()
    }
}
