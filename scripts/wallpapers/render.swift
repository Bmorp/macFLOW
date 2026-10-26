// Renders StandBy's wallpapers on the GPU: each scene is a Metal function that traces one ray per call; this host
// accumulates many jittered samples per pixel (antialiasing, soft shadows, depth of field), tone-maps, dithers and
// writes HEIC. A scene can mark samples as foreground; their coverage becomes the alpha of a separate depth layer.
//
//   swiftc -O scripts/wallpapers/render.swift -o /tmp/wallrender
//   /tmp/wallrender dunes                         → Resources/Wallpapers/dunes.heic (+ dunes-depth.heic)
//   /tmp/wallrender dunes --preview --out /tmp/p  → a quick 960 × 600 JPEG
//   options: --samples N, --size WxH, --out DIR, --crop x,y,w,h (render only a region, for 1:1 checks)
import Foundation
import Metal
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: render <scene> [--preview] [--samples N] [--size WxH] [--out DIR]"); exit(1) }
let scene = args[1]
func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let preview = args.contains("--preview")
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repo = here.deletingLastPathComponent().deletingLastPathComponent()

var W = preview ? 960 : 3840, H = preview ? 600 : 2400
if let s = opt("--size") { let p = s.split(separator: "x").compactMap { Int($0) }; if p.count == 2 { W = p[0]; H = p[1] } }
let samples = Int(opt("--samples") ?? "") ?? (preview ? 8 : 48)
let outDir = URL(fileURLWithPath: opt("--out") ?? (preview ? here.appendingPathComponent("previews").path : repo.appendingPathComponent("Resources/Wallpapers").path))
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
// Region of the full canvas to render (the canvas stays W × H for the scene's maths).
var crop = (x: 0, y: 0, w: W, h: H)
if let c = opt("--crop") { let p = c.split(separator: ",").compactMap { Int($0) }; if p.count == 4 { crop = (p[0], p[1], p[2], p[3]) } }

// MARK: Compile

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("no Metal device") }
func read(_ name: String) -> String {
    guard let s = try? String(contentsOf: here.appendingPathComponent(name), encoding: .utf8) else { fatalError("missing \(name)") }
    return s
}
let source = read("common.metal") + "\n#line 1 \"\(scene).metal\"\n" + read("\(scene).metal") + "\n" + read("kernels.metal")
let options = MTLCompileOptions()
options.mathMode = .fast
options.languageVersion = .version3_1
let library: MTLLibrary
do { library = try device.makeLibrary(source: source, options: options) } catch { print(error); exit(1) }
func pipeline(_ name: String) -> MTLComputePipelineState {
    do { return try device.makeComputePipelineState(function: library.makeFunction(name: name)!) } catch { print(error); exit(1) }
}
let accumulate = pipeline("accumulate"), finish = pipeline("finish")

// MARK: Render

struct Params { var origin: SIMD2<UInt32>; var res: SIMD2<UInt32>; var pass: UInt32; var passes: UInt32; var offset: SIMD2<UInt32> }

func texture() -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: crop.w, height: crop.h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]
    d.storageMode = .private
    return device.makeTexture(descriptor: d)!
}
let acc = texture(), fg = texture()
// Zero them.
do {
    let zero = device.makeBuffer(length: crop.w * 16, options: .storageModeShared)!
    memset(zero.contents(), 0, crop.w * 16)
    let cb = queue.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    for t in [acc, fg] { for y in 0..<crop.h {
        blit.copy(from: zero, sourceOffset: 0, sourceBytesPerRow: crop.w * 16, sourceBytesPerImage: crop.w * 16,
                  sourceSize: MTLSize(width: crop.w, height: 1, depth: 1), to: t, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: y, z: 0))
    } }
    blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
}

let tile = 512
let start = Date()
for pass in 0..<samples {
    var buffers: [MTLCommandBuffer] = []
    for ty in stride(from: 0, to: crop.h, by: tile) {
        for tx in stride(from: 0, to: crop.w, by: tile) {
            let cb = queue.makeCommandBuffer()!, enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(accumulate)
            enc.setTexture(acc, index: 0); enc.setTexture(fg, index: 1)
            var p = Params(origin: SIMD2(UInt32(tx), UInt32(ty)), res: SIMD2(UInt32(W), UInt32(H)), pass: UInt32(pass),
                           passes: UInt32(samples), offset: SIMD2(UInt32(crop.x), UInt32(crop.y)))
            enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            let w = min(tile, crop.w - tx), h = min(tile, crop.h - ty)
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
            cb.commit()
            buffers.append(cb)
        }
    }
    buffers.last?.waitUntilCompleted()
    if let e = buffers.compactMap(\.error).first { print("GPU error: \(e)"); exit(1) }
    if pass == 0 || (pass + 1) % 8 == 0 || pass == samples - 1 {
        print(String(format: "  %@ pass %d/%d  %.1fs", scene, pass + 1, samples, Date().timeIntervalSince(start)))
    }
}

// MARK: Finish → 16-bit RGBA, premultiplied

let count = crop.w * crop.h
let full = device.makeBuffer(length: count * 8, options: .storageModeShared)!
let front = device.makeBuffer(length: count * 8, options: .storageModeShared)!
do {
    let cb = queue.makeCommandBuffer()!, enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(finish)
    enc.setTexture(acc, index: 0); enc.setTexture(fg, index: 1)
    enc.setBuffer(full, offset: 0, index: 0); enc.setBuffer(front, offset: 0, index: 1)
    var p = Params(origin: .zero, res: SIMD2(UInt32(W), UInt32(H)), pass: 0, passes: UInt32(samples), offset: SIMD2(UInt32(crop.x), UInt32(crop.y)))
    enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 2)
    var size = SIMD2(UInt32(crop.w), UInt32(crop.h))
    enc.setBytes(&size, length: 8, index: 3)
    enc.dispatchThreads(MTLSize(width: crop.w, height: crop.h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
}

func image(_ buf: MTLBuffer) -> CGImage {
    let data = Data(bytes: buf.contents(), count: count * 8)
    let provider = CGDataProvider(data: data as CFData)!
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
    return CGImage(width: crop.w, height: crop.h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: crop.w * 8,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

func write(_ img: CGImage, _ url: URL, _ type: UTType, quality: Double) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { fatalError("can't write \(url)") }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("failed to write \(url)") }
}

func scaled(_ img: CGImage, width: Int) -> CGImage {
    let h = Int((Double(img.height) * Double(width) / Double(img.width)).rounded())
    let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
    return ctx.makeImage()!
}

/// Whether the scene marked anything as foreground.
let hasFront: Bool = {
    let p = front.contents().bindMemory(to: UInt16.self, capacity: count * 4)
    for i in stride(from: 3, to: count * 4, by: 4 * 7) where p[i] > 0 { return true }
    return false
}()

let fullImage = image(full)
let suffix = crop.w == W && crop.h == H ? "" : "-crop"
if preview || !suffix.isEmpty {
    write(fullImage, outDir.appendingPathComponent("\(scene)\(suffix).jpg"), .jpeg, quality: 0.92)
    if hasFront {
        // The foreground over magenta, to check its edge.
        let ctx = CGContext(data: nil, width: crop.w, height: crop.h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: crop.w, height: crop.h))
        ctx.draw(image(front), in: CGRect(x: 0, y: 0, width: crop.w, height: crop.h))
        write(ctx.makeImage()!, outDir.appendingPathComponent("\(scene)\(suffix)-depth.jpg"), .jpeg, quality: 0.9)
    }
} else {
    write(fullImage, outDir.appendingPathComponent("\(scene).heic"), .heic, quality: 0.86)
    if hasFront { write(image(front), outDir.appendingPathComponent("\(scene)-depth.heic"), .heic, quality: 0.86) }
    let previews = here.appendingPathComponent("previews")
    try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
    write(scaled(fullImage, width: 960), previews.appendingPathComponent("\(scene)-final.jpg"), .jpeg, quality: 0.9)
}
print(String(format: "%@ done in %.1fs → %@%@", scene, Date().timeIntervalSince(start), outDir.path, hasFront ? " (with depth layer)" : ""))
