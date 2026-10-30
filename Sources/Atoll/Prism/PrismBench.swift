#if DEBUG
import AppKit
import SwiftUI
import Metal

/// `Atoll --prism <dir>`: Prism's checks in one run.
/// - Snapshots of the StandBy Prism face (the `--standby` shots), the material on sample content, and a morph as a
///   strip of frames.
/// - Budgets, from MTLCommandBuffer GPU times: the island material per render, the StandBy stage per frame at
///   3456 × 2234 through a whole morph, and the render thread's time per frame.
/// - With `--live`, a real stage in a small offscreen window: frames per change, frames while idle, main-thread frames.
/// Fallbacks: ATOLL_PRISM_RT=1 (Reduce Transparency), ATOLL_PRISM_RM=1, ATOLL_PRISM_LOWPOWER=1, ATOLL_PRISM_INTEL=1,
/// ATOLL_PRISM_THERMAL=serious|critical, ATOLL_METALLIB=none or a path.
@MainActor
enum PrismBench {
    static func run(outDir: String) {
        Storage.readOnly = true
        RenderMode.snapshot = true
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let env = PrismConditions.shared.current
        print("prism: library \(PrismLibrary.shared?.origin ?? "none") · effects \(PrismLibrary.shared?.effects != nil) · tier \(env.tier) · rt \(env.reduceTransparency)")
        if CommandLine.arguments.contains("--budgets") {
            // Only the measurements (repeat runs to see past other GPU work on the machine).
            budgets()
            return
        }
        let suffix = ProcessInfo.processInfo.environment["ATOLL_PRISM_RT"] == "1" ? "-rt" : ""
        // This Mac's SDK declares Date.<= but its Foundation lacks it; the calendar chip compares dates that way.
        CalendarModel.shared.debugSet([])
        SurfaceHarness.standBy(outDir: outDir, only: ["76-standby-prism"])
        materialSamples(outDir: outDir, suffix: suffix)
        filmstrip(outDir: outDir)
        if PrismRenderer.shared != nil { budgets() }
        if CommandLine.arguments.contains("--live") { live(outDir: outDir) } else { print("prism ok → \(outDir)") }
    }

    // MARK: Material

    /// Album-art-like content through each style, the way the island and StandBy would use it.
    static func materialSamples(outDir: String, suffix: String) {
        let card = ZStack {
            LinearGradient(colors: [Color(red: 0.95, green: 0.35, blue: 0.2), Color(red: 0.55, green: 0.15, blue: 0.75), Color(red: 0.1, green: 0.35, blue: 0.95)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 4) {
                Text("Midnight City").font(.system(size: 28, weight: .bold))
                Text("M83 · Hurry Up, We're Dreaming").font(.system(size: 15, weight: .medium)).opacity(0.8)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 460, height: 160)
        let styles: [(String, PrismStyle)] = [("island", .island), ("nowplaying", .nowPlaying), ("flow", .flow), ("standby", .standBy)]
        let sheet = VStack(spacing: 12) {
            ForEach(styles, id: \.0) { name, style in
                HStack(spacing: 12) {
                    card.prism(style)
                    Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).frame(width: 90, alignment: .leading)
                }
            }
            HStack(spacing: 12) { card; Text("plain").font(.system(size: 13, weight: .medium)).foregroundStyle(.white).frame(width: 90, alignment: .leading) }
            // The island's expanded timer, as it could show a count in Ribbon numerals.
            HStack(spacing: 24) {
                RibbonCount(lead: "24", trail: "59", fontSize: 44)
                RibbonCount(lead: "1", trail: "07", fontSize: 30)
                Spacer()
                Text("count").font(.system(size: 13, weight: .medium)).foregroundStyle(.white).frame(width: 90, alignment: .leading)
            }
            .frame(width: 562)
        }
        .padding(20)
        .background(Color.black)
        save(sheet, name: "77-prism-material\(suffix)", outDir: outDir)
    }

    static func save<V: View>(_ view: V, name: String, outDir: String, scale: CGFloat = 2) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        r.scale = scale
        guard let cg = r.cgImage else { print("render failed: \(name)"); return }
        write(cg, URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png"))
    }

    static func write(_ cg: CGImage, _ url: URL) {
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Morph

    static func scene(_ h: String, _ m: String, canvas: CGSize = CGSize(width: 1470, height: 956), frost: CGImage? = nil) -> RibbonScene {
        RibbonScene(lead: h, trail: m, fontSize: canvas.height * ClockLayout.timeSize, canvas: canvas,
                    layout: CGRect(origin: .zero, size: canvas), style: .standBy, frost: frost, env: PrismConditions.shared.current)
    }

    /// A change of every figure (9:59 → 10:00), as six frames cropped to the numerals, one under the other.
    static func filmstrip(outDir: String) {
        guard let r = PrismRenderer.shared else { return }
        let frost = Wallpapers.available.first.flatMap { w in Wallpapers.url(w.id) }.flatMap { url -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480] as CFDictionary)
        }
        let a = scene("9", "59", frost: frost), b = scene("10", "00", frost: frost)
        let old = RibbonLayout.columns(a.outline, pitch: a.style.pitch), new = RibbonLayout.columns(b.outline, pitch: b.style.pitch)
        let (strips, duration) = RibbonLayout.strips(from: old, to: new, morph: .spring)
        let scale: CGFloat = 1
        let w = Int(b.canvas.width * scale), h = Int(b.canvas.height * scale)
        let backdrop = frost.flatMap { r.texture($0) }
        let times: [Float] = [0, 0.15, 0.3, 0.45, 0.65, duration]
        let crop = CGRect(x: 0, y: Int(Double(new.top) * scale) - 30, width: w, height: Int(Double(new.foot - new.top) * scale) + 60)
        let sheet = CGContext(data: nil, width: w, height: Int(crop.height) * times.count, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        sheet.setFillColor(CGColor(gray: 0, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: w, height: Int(crop.height) * times.count))
        for (i, t) in times.enumerated() {
            let u = b.uniforms(columns: new, time: t, duration: duration, scale: Float(scale), hasBackdrop: backdrop != nil)
            guard let frame = r.frame(width: w, height: h, uniforms: u, strips: strips, backdrop: backdrop),
                  let part = frame.cropping(to: crop) else { continue }
            let y = Int(crop.height) * (times.count - 1 - i)
            sheet.draw(part, in: CGRect(x: 0, y: y, width: w, height: Int(crop.height)))
        }
        if let img = sheet.makeImage() { write(img, URL(fileURLWithPath: outDir).appendingPathComponent("78-ribbon-morph.png")) }
        print(String(format: "prism: morph 9:59 → 10:00 · %d strips · %.2f s", strips.count, duration))
    }

    // MARK: Budgets

    struct Timing {
        var samples: [Double]
        var median: Double { samples.sorted()[samples.count / 2] }
        var p95: Double { samples.sorted()[min(samples.count - 1, Int(Double(samples.count) * 0.95))] }
        var max: Double { samples.max() ?? 0 }
        func line(_ label: String) -> String {
            String(format: "%@: median %.3f ms · p95 %.3f ms · max %.3f ms (%d frames)", label, median * 1000, p95 * 1000, max * 1000, samples.count)
        }
    }

    static func budgets() {
        guard let r = PrismRenderer.shared else { return }
        // Warm the pipeline and caches, as the app's prewarm does.
        _ = r.pipeline
        // The StandBy stage at a 16-inch MacBook Pro's native size, through the 9:59 → 10:00 change (every column moves).
        let canvas = CGSize(width: 1728, height: 1117), scale: CGFloat = 2
        let frost = Wallpapers.available.first.flatMap { w in Wallpapers.url(w.id) }.flatMap { url -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480] as CFDictionary)
        }
        let a = scene("9", "59", canvas: canvas, frost: frost), b = scene("10", "00", canvas: canvas, frost: frost)
        let gpu = stageTimes(r, from: a, to: b, scale: scale)
        print("prism budget · " + gpu.gpu.line("stage GPU per frame, 3456×2234, morph (≤ 1.5 ms)"))
        print("prism budget · " + gpu.cpu.line("stage render thread per frame (≤ 0.5 ms)"))
        print("prism budget · stage strips during the morph: \(gpu.strips)")
        // The island material: one render of an expanded island's content through `.island` flutes.
        do {
            if let island = try materialTimes(width: 1200, height: 400) {
                print("prism budget · " + island.line("island Prism GPU per render, 600×200 pt @2x (≤ 0.25 ms)"))
            }
            if let full = try materialTimes(width: 3456, height: 2234) {
                print("prism budget · " + full.line("Prism material GPU per render, full 3456×2234 (reference)"))
            }
        } catch {
            print("prism budget · material bench failed: \(error)")
        }
    }

    /// Encodes every frame of a morph at 120 Hz into an offscreen drawable-sized texture, on a background thread like
    /// the render thread, timing the GPU and the encoding.
    nonisolated static func stageTimes(_ r: PrismRenderer, from a: RibbonScene, to b: RibbonScene, scale: CGFloat) -> (gpu: Timing, cpu: Timing, strips: Int) {
        let old = RibbonLayout.columns(a.outline, pitch: a.style.pitch), new = RibbonLayout.columns(b.outline, pitch: b.style.pitch)
        let (strips, duration) = RibbonLayout.strips(from: old, to: new, morph: .spring)
        let w = Int(b.canvas.width * scale), h = Int(b.canvas.height * scale)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: PrismRenderer.pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        /// What the timing thread needs, handed over whole.
        final class Run: @unchecked Sendable {
            let target: MTLTexture, buffer: MTLBuffer?, backdrop: MTLTexture?
            var gpu: [Double] = [], cpu: [Double] = [], cold: Double = 0
            init(target: MTLTexture, buffer: MTLBuffer?, backdrop: MTLTexture?) { self.target = target; self.buffer = buffer; self.backdrop = backdrop }
        }
        let run = Run(target: r.device.makeTexture(descriptor: d)!, buffer: r.makeStrips(strips), backdrop: b.frost.flatMap { r.texture($0) })
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let frames = Int(ceil(duration * 120)) + 1
            for pass in 0..<3 {   // two passes warm caches and clocks; the third is measured
                for i in 0..<frames {
                    let began = CACurrentMediaTime()
                    guard let cb = r.queue.makeCommandBuffer() else { continue }
                    let u = b.uniforms(columns: new, time: Float(i) / 120, duration: duration, scale: Float(scale), hasBackdrop: run.backdrop != nil)
                    r.encode(cb, target: run.target, uniforms: u, strips: run.buffer, count: strips.count, backdrop: run.backdrop)
                    cb.commit()
                    if pass == 2 { run.cpu.append(CACurrentMediaTime() - began) }
                    // One frame in flight at a time, as a display paces it, so GPU times don't overlap.
                    cb.waitUntilCompleted()
                    if pass == 2 { run.gpu.append(cb.gpuEndTime - cb.gpuStartTime) }
                    if pass == 0, i == 0 { run.cold = cb.gpuEndTime - cb.gpuStartTime }
                }
            }
            done.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        done.wait()
        print(String(format: "prism budget · stage GPU, first frame from an idle GPU: %.3f ms", run.cold * 1000))
        // The same frames back to back in one command buffer: the cost per frame with other GPU clients' scheduling
        // averaged out.
        if let cb = r.queue.makeCommandBuffer() {
            let frames = Int(ceil(duration * 120)) + 1
            for i in 0..<frames {
                let u = b.uniforms(columns: new, time: Float(i) / 120, duration: duration, scale: Float(scale), hasBackdrop: run.backdrop != nil)
                r.encode(cb, target: run.target, uniforms: u, strips: run.buffer, count: strips.count, backdrop: run.backdrop)
            }
            cb.commit()
            cb.waitUntilCompleted()
            print(String(format: "prism budget · stage GPU per frame, amortised over %d frames: %.3f ms", frames, (cb.gpuEndTime - cb.gpuStartTime) * 1000 / Double(frames)))
        }
        return (Timing(samples: run.gpu), Timing(samples: run.cpu), strips.count)
    }

    /// `prismFlutes` itself, called from a fragment shader over a `SwiftUI::Layer` built the way SwiftUI builds one:
    /// what the shader costs per render of a surface this size.
    nonisolated static func materialTimes(width w: Int, height h: Int) throws -> Timing? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let bench = """
        struct BenchOut { float4 position [[position]]; };
        vertex BenchOut benchVertex(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            BenchOut o; o.position = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;
        }
        fragment half4 benchFragment(BenchOut in [[stage_in]], texture2d<half> tex [[texture(0)]], constant float4& size [[buffer(0)]]) {
            SwiftUI::Layer layer;
            layer.tex = tex;
            layer.info[0] = float2(1.0 / size.x, 0.0);
            layer.info[1] = float2(0.0, 1.0 / size.y);
            layer.info[2] = float2(0.0);
            layer.info[3] = float2(0.0);
            layer.info[4] = float2(1.0);
            float2 p = in.position.xy / size.z;
            return prismFlutes(p, layer, float4(0, 0, size.x, size.y), 2.5, 0.6, 1.4, 6.0, 0.25, 0.35, 0.0, 0.0, half4(1.0));
        }
        """
        // As a plain function: a [[stitchable]] one is only reachable through linking, which SwiftUI does for itself.
        let src = try PrismLibrary.source("PrismFlutes.metal").replacingOccurrences(of: "[[stitchable]]", with: "static") + "\n" + bench
        let options = MTLCompileOptions()
        options.languageVersion = .version2_4
        let lib = try device.makeLibrary(source: src, options: options)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "benchVertex")
        pd.fragmentFunction = lib.makeFunction(name: "benchFragment")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pd)
        // The layer SwiftUI would hand the shader: the content rasterised at the same size.
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        cd.usage = [.shaderRead]
        let content = device.makeTexture(descriptor: cd)!
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let i = (y * w + x) * 4
            pixels[i] = UInt8(x * 255 / w); pixels[i + 1] = UInt8(y * 255 / h); pixels[i + 2] = 180; pixels[i + 3] = 255 } }
        content.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .private
        let target = device.makeTexture(descriptor: td)!
        var size = SIMD4<Float>(Float(w) / 2, Float(h) / 2, 2, 0)
        func pass(_ cb: MTLCommandBuffer) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(content, index: 0)
            enc.setFragmentBytes(&size, length: 16, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        // Amortised: 100 renders in one command buffer.
        if let cb = queue.makeCommandBuffer() {
            for _ in 0..<100 { pass(cb) }
            cb.commit()
            cb.waitUntilCompleted()
            print(String(format: "prism budget · material %d×%d GPU per render, amortised over 100: %.3f ms", w, h, (cb.gpuEndTime - cb.gpuStartTime) * 10))
        }
        var times: [Double] = []
        // 60 frames back to back bring the GPU to its working clock (as the window server's own compositing does
        // when the island changes); then 60 measured one at a time.
        for i in 0..<120 {
            let cb = queue.makeCommandBuffer()!
            pass(cb)
            cb.commit()
            if i >= 59 { cb.waitUntilCompleted() }
            if i >= 60 { times.append(cb.gpuEndTime - cb.gpuStartTime) }
        }
        return Timing(samples: times)
    }

    // MARK: Live

    /// A real stage in a window parked off screen: one change of every figure, then two seconds of nothing.
    static func live(outDir: String) {
        RenderMode.snapshot = false
        let size = CGSize(width: 960, height: 400)
        let view = PrismStageView(maxFrameRate: 120)
        view.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = view
        win.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        win.orderFrontRegardless()
        let layout = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        func show(_ h: String, _ m: String) {
            view.show(RibbonScene(lead: h, trail: m, fontSize: size.height * 0.55, canvas: size, layout: layout, style: .standBy, env: PrismConditions.shared.current))
        }
        show("9", "59")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard let stage = view.stage else { print("prism live: no stage"); exit(1) }
        let first = stage.stats.withLock { $0 }
        show("10", "00")
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))
        let morph = stage.stats.withLock { $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let after = stage.stats.withLock { $0 }
        print("prism live: first appearance \(first.frames) frame(s); the change \(morph.frames - first.frames) frames; then idle 2 s: \(after.frames - morph.frames) frames")
        print("prism live: frames while idle \(after.framesWhileIdle) · frames on the main thread \(after.mainThreadFrames)")
        if !morph.encode.isEmpty { print("prism live · " + Timing(samples: morph.encode).line("render thread per frame")) }
        if !morph.gpu.isEmpty { print("prism live · " + Timing(samples: morph.gpu).line("GPU per frame (960×400 pt)")) }
        win.orderOut(nil)
        print("prism ok → \(outDir)")
    }
}
#endif
