import AppKit
import ImageIO
import CoreImage

/// One of StandBy's pictures: original 3840 × 2400 GPU renders made by `scripts/wallpapers` (see render.swift).
struct Wallpaper: Identifiable, Equatable {
    let id: String
    let name: String
    /// Carries a separate foreground layer the clock can tuck behind.
    let hasDepth: Bool
}

/// The bundled wallpapers: where they live, decoded at the size the display needs, off the main thread.
enum Wallpapers {
    static let all: [Wallpaper] = [
        Wallpaper(id: "dunes", name: "Dunes", hasDepth: true),
        Wallpaper(id: "alpine", name: "Alpine", hasDepth: true),
        Wallpaper(id: "aurora", name: "Aurora", hasDepth: true),
        Wallpaper(id: "silk", name: "Silk", hasDepth: false),
        Wallpaper(id: "horizon", name: "Horizon", hasDepth: false),
        Wallpaper(id: "nebula", name: "Nebula", hasDepth: false),
        Wallpaper(id: "glass", name: "Glass", hasDepth: false),
        Wallpaper(id: "graphite", name: "Graphite", hasDepth: false),
    ]

    /// The setting's two special values.
    static let none = "none"
    static let shuffle = "shuffle"

    static func named(_ id: String) -> Wallpaper? { all.first { $0.id == id } }

    /// Inside the app: Contents/Resources/Wallpapers. A debug build run from the package reads the repo's copy.
    static let folder: URL? = {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Wallpapers"), fm.fileExists(atPath: res.path) { return res }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Wallpapers")
        if fm.fileExists(atPath: repo.path) { return repo }
        #endif
        return nil
    }()

    /// Installed pictures only (a picture missing from the bundle is simply not offered).
    static var available: [Wallpaper] { all.filter { url($0.id) != nil } }

    static func url(_ id: String, depth: Bool = false) -> URL? {
        guard let folder else { return nil }
        let base = depth ? "\(id)-depth" : id
        for ext in ["heic", "png", "jpg"] {
            let u = folder.appendingPathComponent("\(base).\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// What the setting means right now. Shuffle never repeats the picture before.
    static func resolve(_ setting: String, after previous: String? = nil) -> Wallpaper? {
        if setting == none { return nil }
        if setting != shuffle, let w = named(setting), url(w.id) != nil { return w }
        let pool = available.filter { $0.id != previous }
        return pool.randomElement() ?? available.first
    }

    static func next(after id: String?, by delta: Int) -> Wallpaper? {
        let list = available
        guard !list.isEmpty else { return nil }
        let i = list.firstIndex { $0.id == id } ?? (delta > 0 ? -1 : 0)
        return list[((i + delta) % list.count + list.count) % list.count]
    }

    // MARK: Decoding

    /// A picture's layers, decoded and ready for the GPU.
    struct Images: @unchecked Sendable {
        let id: String
        let picture: CGImage
        let depth: CGImage?
        /// The picture blurred and lifted: what frosted glass digits show of it.
        let frost: CGImage?
    }

    private static let queue = DispatchQueue(label: "atoll.wallpapers", qos: .userInitiated)
    nonisolated(unsafe) private static var cache: [String: Images] = [:]
    private static let lock = NSLock()

    /// Decodes a picture at the pixel size that fills `screen` (with room for the backdrop's slow zoom).
    @MainActor
    static func load(_ id: String, for screen: CGSize, scale: CGFloat, completion: @escaping @MainActor (Images?) -> Void) {
        let key = "\(id)@\(Int(screen.width * scale))"
        if let hit = lock.withLock({ cache[key] }) {
            completion(hit)
            return
        }
        queue.async {
            let pixels = max(screen.width, screen.height * 1.6) * scale * 1.14
            let images = decode(id, maxPixels: pixels)
            if let images { lock.withLock { cache = [key: images] } }
            DispatchQueue.main.async { completion(images) }
        }
    }

    nonisolated private static func decode(_ id: String, maxPixels: CGFloat) -> Images? {
        guard let u = url(id), let picture = image(u, maxPixels: maxPixels) else { return nil }
        let depth = named(id)?.hasDepth == true ? url(id, depth: true).flatMap { image($0, maxPixels: maxPixels) } : nil
        return Images(id: id, picture: picture, depth: depth, frost: frost(picture))
    }

    nonisolated private static func image(_ url: URL, maxPixels: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixels.rounded(.up)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    nonisolated(unsafe) private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// The picture at 1/8 size, blurred, a touch brighter and more saturated: frosted glass in front of it.
    nonisolated private static func frost(_ cg: CGImage) -> CGImage? {
        let w = max(64, cg.width / 8), h = max(40, cg.height / 8)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: small)
        let out = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(w) / 90)
            .cropped(to: input.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: 0.1])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.45])
        return ci.createCGImage(out, from: input.extent)
    }

    // MARK: Thumbnails

    nonisolated(unsafe) private static let thumbs: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 24
        return c
    }()

    /// A small picture for Settings (ImageIO thumbnail, kept in memory).
    static func thumbnail(_ id: String) -> NSImage? {
        if let t = thumbs.object(forKey: id as NSString) { return t }
        guard let u = url(id), let cg = image(u, maxPixels: 480) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        thumbs.setObject(img, forKey: id as NSString)
        return img
    }

    // MARK: Desktop

    /// Puts a picture on every display. It's copied out of the app first, so moving or updating the app never
    /// leaves the desktop blank.
    @MainActor
    static func setDesktop(_ id: String) -> Bool {
        guard let src = url(id) else { return false }
        let dir = Storage.directory.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil else { return false }
        var ok = true
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(dest, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true,
                ])
            } catch { ok = false }
        }
        return ok
    }
}
