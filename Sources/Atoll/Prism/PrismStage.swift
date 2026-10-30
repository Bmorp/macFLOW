import AppKit
import Metal
import QuartzCore
import os

/// Matches `RibbonUniforms` in Ribbon.metal, field for field (PrismTests checks the offsets).
struct RibbonUniforms {
    var viewport: SIMD2<Float> = .zero
    var scale: Float = 2
    var time: Float = 0
    var pitch: Float = 5
    var lens: Float = 0.8
    var depth: Float = 14
    var disperse: Float = 0.5
    var spec: Float = 0.5
    var sparks: Float = 0
    var seed: Float = 0
    var omega: Float = RibbonPace.clock.omega
    var zeta: Float = RibbonPace.clock.damping
    var lag: Float = RibbonSpring.lag
    var curl: Float = 6
    var fade: Float = 1
    var top: Float = 0
    var foot: Float = 1
    var flags: UInt32 = 0
    var sparkMotion: Float = 0
    var tint: SIMD4<Float> = SIMD4(1, 1, 1, 0)
    var backdrop: SIMD4<Float> = SIMD4(0, 0, 1, 1)

    static let sampleBackdrop: UInt32 = 1, disperse: UInt32 = 2, night: UInt32 = 4, contrast: UInt32 = 8
}

/// Everything a ribbon stage shows: the two halves of the time, how they're laid out, the glass, and what's behind it.
struct RibbonScene: Equatable, @unchecked Sendable {
    /// The time's two halves ("9", "41"), or a count's ("24", "59").
    var lead: String
    var trail: String
    var fontSize: CGFloat
    /// The view's size, points.
    var canvas: CGSize
    /// The rect `TimeGlyphs.path` lays the time out in (StandBy: the whole screen, so it sits where the other faces do).
    var layout: CGRect
    var style: PrismStyle
    /// The light's tint (alpha 0: steel to white).
    var tint: SIMD4<Float> = SIMD4(1, 1, 1, 0)
    var night = false
    /// The wallpaper, blurred: what the glass shows of what's behind it.
    var frost: CGImage?
    var env: PrismEnvironment
    /// How quickly figures flow: the clock once a minute, a count every second.
    var pace: RibbonPace = .clock

    var outline: CGPath { TimeGlyphs.path(hour: lead, minute: trail, size: fontSize, in: layout) }

    /// Same strips? (Then only the light changed, and one new frame is enough.)
    func sameShape(_ o: RibbonScene) -> Bool {
        lead == o.lead && trail == o.trail && fontSize == o.fontSize && layout == o.layout && style.pitch == o.style.pitch
    }

    static func == (a: Self, b: Self) -> Bool {
        a.sameShape(b) && a.canvas == b.canvas && a.style == b.style && a.tint == b.tint && a.night == b.night
            && a.frost === b.frost && a.env == b.env && a.pace == b.pace
    }

    var morph: RibbonLayout.Morph { env.morphs ? .spring : env.crossFades ? .crossFade : .cut }

    func uniforms(columns: RibbonColumns, time: Float, duration: Float, scale: Float, hasBackdrop: Bool) -> RibbonUniforms {
        var u = RibbonUniforms()
        u.viewport = SIMD2(Float(canvas.width), Float(canvas.height))
        u.scale = scale
        u.time = time
        u.pitch = Float(style.pitch)
        u.lens = Float(style.lens)
        u.depth = Float(style.depth)
        u.disperse = Float(style.disperse)
        u.spec = Float(style.specular)
        // Figures keep a clean silhouette: a spark or two across the whole time, never a scatter of hairlines.
        u.sparks = Float(min(style.sparks, 0.004))
        u.seed = Float(style.seed % 65536)
        u.curl = Float(style.pitch) * 1.2
        u.omega = pace.omega
        u.zeta = pace.damping
        u.fade = min(1, time / RibbonSpring.crossFade)
        u.top = columns.top
        u.foot = columns.foot
        if hasBackdrop && env.samplesBehind && !night { u.flags |= RibbonUniforms.sampleBackdrop }
        if env.dispersion { u.flags |= RibbonUniforms.disperse }
        if night { u.flags |= RibbonUniforms.night }
        if env.increaseContrast { u.flags |= RibbonUniforms.contrast }
        if env.movingSparks, duration > 0, morph == .spring { u.sparkMotion = max(0, 1 - time / duration) }
        u.tint = tint
        if let frost {
            // The picture as the backdrop shows it at rest: filling the screen, zoomed by the drift's rest scale.
            let iw = CGFloat(frost.width), ih = CGFloat(frost.height)
            let k = max(canvas.width / iw, canvas.height / ih) * StandByStage.restScale
            let w = iw * k, h = ih * k
            u.backdrop = SIMD4(Float((canvas.width - w) / 2), Float((canvas.height - h) / 2), Float(w), Float(h))
        }
        return u
    }
}

// MARK: - Renderer

/// The one pipeline and the one thread every ribbon stage shares. Frames are encoded on that thread, driven by each
/// stage's `CAMetalDisplayLink`; the main thread only hands over a new scene when something changes.
final class PrismRenderer: @unchecked Sendable {
    static let shared: PrismRenderer? = PrismLibrary.shared.flatMap { PrismRenderer($0) }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let runLoop: RunLoop
    private let cfRunLoop: CFRunLoop
    /// Built on first use, on whichever thread asks first (normally the render thread, at launch).
    private let pipelineLock = NSLock()
    private var pipelineState: MTLRenderPipelineState?
    private(set) lazy var empty: MTLTexture = makeTexture(width: 1, height: 1, pixels: [0, 0, 0, 0])!

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init?(_ loaded: PrismLibrary.Loaded) {
        guard let queue = loaded.device.makeCommandQueue() else { return nil }
        device = loaded.device
        self.queue = queue
        library = loaded.library
        // A thread of our own with a run loop the display links run on: frames never touch the main thread.
        var loops: (RunLoop, CFRunLoop)?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            loops = (RunLoop.current, CFRunLoopGetCurrent())
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while true { autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) } }
        }
        thread.name = "app.macflow.prism"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        (runLoop, cfRunLoop) = loops!
    }

    /// Builds the pipeline ahead of the first StandBy, off the main thread.
    static func warm() {
        guard let r = shared else { return }
        r.perform { _ = r.pipeline }
    }

    /// Runs `block` on the render thread.
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(cfRunLoop)
    }

    var pipeline: MTLRenderPipelineState? {
        pipelineLock.withLock {
            if let pipelineState { return pipelineState }
            let d = MTLRenderPipelineDescriptor()
            d.label = "Ribbon numerals"
            d.vertexFunction = library.makeFunction(name: "ribbonVertex")
            d.fragmentFunction = library.makeFunction(name: "ribbonFragment")
            let c = d.colorAttachments[0]!
            c.pixelFormat = Self.pixelFormat
            // Premultiplied over whatever the backdrop layer shows beneath.
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do {
                pipelineState = try device.makeRenderPipelineState(descriptor: d)
            } catch {
                PrismLibrary.log.error("Prism: ribbon pipeline failed: \(error.localizedDescription, privacy: .public)")
            }
            return pipelineState
        }
    }

    func makeTexture(width: Int, height: Int, pixels: [UInt8]) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        return t
    }

    /// The blurred wallpaper as a texture (it's small: an eighth of the picture).
    func texture(_ image: CGImage) -> MTLTexture? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? makeTexture(width: w, height: h, pixels: pixels) : nil
    }

    func makeStrips(_ strips: [RibbonStrip]) -> MTLBuffer? {
        guard !strips.isEmpty else { return nil }
        return strips.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    /// One frame: clear, then every strip as an instanced quad.
    func encode(_ cb: MTLCommandBuffer, target: MTLTexture, uniforms: RibbonUniforms, strips: MTLBuffer?, count: Int, backdrop: MTLTexture?) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let pipeline, let strips, count > 0 {
            var u = uniforms
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<RibbonUniforms>.stride, index: 0)
            enc.setVertexBuffer(strips, offset: 0, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<RibbonUniforms>.stride, index: 0)
            enc.setFragmentTexture(backdrop ?? empty, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        enc.endEncoding()
    }

    // MARK: Still frames

    /// A scene at rest, drawn offscreen: what snapshots show (ImageRenderer can't draw a CAMetalLayer). Waits for the GPU.
    func still(_ scene: RibbonScene, scale: CGFloat) -> CGImage? {
        let columns = RibbonLayout.columns(scene.outline, pitch: scene.style.pitch)
        let strips = RibbonLayout.strips(from: nil, to: columns, morph: .cut).strips
        let w = Int((scene.canvas.width * scale).rounded()), h = Int((scene.canvas.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }
        let backdrop = scene.frost.flatMap(texture)
        let u = scene.uniforms(columns: columns, time: 10, duration: 0, scale: Float(scale), hasBackdrop: backdrop != nil)
        return frame(width: w, height: h, uniforms: u, strips: strips, backdrop: backdrop)
    }

    /// Renders one frame offscreen and reads it back (snapshots, tests, the benchmark's look at a morph).
    func frame(width w: Int, height h: Int, uniforms: RibbonUniforms, strips: [RibbonStrip], backdrop: MTLTexture?) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        guard let target = device.makeTexture(descriptor: d),
              let readback = device.makeBuffer(length: w * h * 4, options: .storageModeShared),
              let cb = queue.makeCommandBuffer() else { return nil }
        encode(cb, target: target, uniforms: uniforms, strips: makeStrips(strips), count: strips.count, backdrop: backdrop)
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: readback, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        let data = Data(bytes: readback.contents(), count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Stage

/// One ribbon surface: a `CAMetalLayer` and a display link that runs only while strips are moving. Once a change has
/// settled the link pauses and the last frame stays on screen, so a clock that changes once a minute draws about
/// 160 frames a minute and none in between.
final class PrismStage: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    let layer = CAMetalLayer()
    private let renderer: PrismRenderer
    private let maxFrameRate: Float

    // Render-thread state.
    private var link: CAMetalDisplayLink?
    private var scene: RibbonScene?
    private var columns: RibbonColumns?
    private var strips: [RibbonStrip] = []
    private var stripBuffer: MTLBuffer?
    private var duration: Float = 0
    private var start: CFTimeInterval?
    private var backdrop: MTLTexture?
    private var backdropSource: CGImage?

    /// Frame timings, for the benchmark and the probe.
    struct Stats: Sendable {
        var frames = 0
        var encode: [Double] = []      // seconds on the render thread, per frame
        var gpu: [Double] = []         // seconds on the GPU, per frame
        var framesWhileIdle = 0
        var mainThreadFrames = 0
    }
    let stats = OSAllocatedUnfairLock(initialState: Stats())
    private var idle = true

    init(renderer: PrismRenderer, maxFrameRate: Float = 120) {
        self.renderer = renderer
        self.maxFrameRate = maxFrameRate
        super.init()
        layer.device = renderer.device
        layer.pixelFormat = PrismRenderer.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 3
        layer.needsDisplayOnBoundsChange = false
    }

    /// A new scene from the view. Main thread; returns at once.
    func show(_ scene: RibbonScene) {
        renderer.perform { [self] in apply(scene) }
    }

    /// The view left its window: stop the link and let go of drawables.
    func suspend() {
        renderer.perform { [self] in
            link?.invalidate()
            link = nil
            idle = true
        }
    }

    // MARK: Render thread

    private func apply(_ next: RibbonScene) {
        let previous = scene
        scene = next
        if let previous, previous.sameShape(next), columns != nil {
            // Only the light or what's behind changed: one new frame at the current point of any change in flight.
            if next.frost !== backdropSource { loadBackdrop(next.frost) }
            wake()
            return
        }
        if next.frost !== backdropSource { loadBackdrop(next.frost) }
        let new = RibbonLayout.columns(next.outline, pitch: next.style.pitch)
        var old = columns
        // A change that arrives mid-flight starts from where the strips are now.
        if let s = start, !idle, let c = columns {
            old = RibbonLayout.evaluate(strips, at: Float(CACurrentMediaTime() - s), pitch: c.pitch, top: c.top, foot: c.foot, pace: next.pace)
        }
        // A new size or layout (or the first time) appears at rest; only a change of figures moves.
        let moves = previous.map { $0.canvas == next.canvas && $0.layout.size == next.layout.size && $0.fontSize == next.fontSize } ?? false
        let built = RibbonLayout.strips(from: moves ? old : nil, to: new, morph: next.morph, pace: next.pace)
        columns = new
        strips = built.strips
        duration = built.duration
        stripBuffer = renderer.makeStrips(built.strips)
        start = nil
        wake()
    }

    private func loadBackdrop(_ image: CGImage?) {
        backdropSource = image
        backdrop = image.flatMap { renderer.texture($0) }
    }

    private func wake() {
        if link == nil {
            let l = CAMetalDisplayLink(metalLayer: layer)
            l.delegate = self
            l.preferredFrameLatency = 1
            l.add(to: renderer.runLoop, forMode: .default)
            link = l
        }
        let rate = min(maxFrameRate, scene?.env.maxFrameRate ?? 60)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        idle = false
        link?.isPaused = false
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let began = CACurrentMediaTime()
        guard let scene, let columns, let cb = renderer.queue.makeCommandBuffer() else { link.isPaused = true; return }
        let now = update.targetPresentationTimestamp
        if start == nil { start = now }
        let t = Float(now - start!)
        let texture = update.drawable.texture
        let scale = Float(texture.width) / Float(max(scene.canvas.width, 1))
        let u = scene.uniforms(columns: columns, time: t, duration: duration, scale: scale, hasBackdrop: backdrop != nil)
        renderer.encode(cb, target: texture, uniforms: u, strips: stripBuffer, count: strips.count, backdrop: backdrop)
        cb.present(update.drawable)
        let wasIdle = idle
        let stats = self.stats
        cb.addCompletedHandler { cb in
            let gpu = cb.gpuEndTime - cb.gpuStartTime
            stats.withLock { s in if s.gpu.count < 4096 { s.gpu.append(gpu) } }
        }
        cb.commit()
        let settled = t >= duration
        if settled {
            // Done: the last frame stays up and nothing runs until the next change.
            link.isPaused = true
            idle = true
        }
        let spent = CACurrentMediaTime() - began
        stats.withLock { s in
            s.frames += 1
            if wasIdle { s.framesWhileIdle += 1 }
            if Thread.isMainThread { s.mainThreadFrames += 1 }
            if s.encode.count < 4096 { s.encode.append(spent) }
        }
    }
}
