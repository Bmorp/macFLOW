import SwiftUI
import AppKit
import QuartzCore
import CoreImage

/// StandBy's stage: the wallpaper (or the album's colours) behind every page, and the wallpaper's foreground layer
/// in front of the clock. Drawn as Core Animation layers: their slow drift runs in the render server, so a StandBy
/// left on all evening costs the app nothing per frame. Offscreen renders get a still SwiftUI drawing instead.
enum StandByStage {
    /// When StandBy opened, in Core Animation time. Every drifting layer starts from it, so the picture and its
    /// foreground (two views, with the clock between them) move as one.
    static var epoch: CFTimeInterval = 0

    /// The Ken Burns loop: a slow zoom between 1.06 and 1.12 with a small pan, so the picture's edges never show.
    static let restScale: CGFloat = 1.06

    static func addDrift(to layer: CALayer, size: CGSize) {
        layer.removeAllAnimations()
        guard !Access.reduceMotion else {
            layer.setAffineTransform(CGAffineTransform(scaleX: restScale, y: restScale))
            return
        }
        layer.setAffineTransform(.identity)
        func loop(_ key: String, _ from: CGFloat, _ to: CGFloat, _ duration: Double) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.beginTime = epoch
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: key)
        }
        loop("transform.scale", restScale, 1.12, 35)
        loop("transform.translation.x", -size.width * 0.015, size.width * 0.015, 47)
        loop("transform.translation.y", -size.height * 0.008, size.height * 0.008, 41)
    }

    /// Film grain over wide gradients, so they never band on a big display.
    static let grain: NSImage = {
        let n = 160
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32)!
        var rng = SystemRandomNumberGenerator()
        let p = rep.bitmapData!
        for i in 0..<(n * n) {
            let white = Bool.random(using: &rng)
            let a = UInt8.random(in: 0...22, using: &rng)
            let v: UInt8 = white ? a : 0          // premultiplied
            p[i * 4] = v; p[i * 4 + 1] = v; p[i * 4 + 2] = v; p[i * 4 + 3] = a
        }
        let img = NSImage(size: NSSize(width: n / 2, height: n / 2))
        img.addRepresentation(rep)
        return img
    }()

    /// The cover as fields of its own colours: `base` covers the screen, `soft` fades out to its edges so the
    /// copies turning over it never show a corner.
    struct AlbumField: @unchecked Sendable {
        let base: CGImage
        let soft: CGImage
    }

    /// Averaged to 32 px, blurred, lifted if dark, more saturated.
    nonisolated static func albumField(_ image: NSImage) -> AlbumField? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = 32
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let small = ctx.makeImage(), let bytes = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var lum = 0.0
        for i in 0..<(n * n) {
            lum += (0.2126 * Double(bytes[i * 4]) + 0.7152 * Double(bytes[i * 4 + 1]) + 0.0722 * Double(bytes[i * 4 + 2])) / 255
        }
        lum = max(0.02, lum / Double(n * n))
        let input = CIImage(cgImage: small)
        let out = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 2.4)
            .cropped(to: input.extent)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: min(2.2, max(0, log2(0.32 / lum)))])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.65])
        guard let field = ciContext.createCGImage(out, from: input.extent) else { return nil }
        let N = 320
        guard let big = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        big.interpolationQuality = .high
        big.draw(field, in: CGRect(x: 0, y: 0, width: N, height: N))
        guard let base = big.makeImage() else { return nil }
        // Same picture, faded to nothing by the edge of its inscribed circle.
        big.setBlendMode(.destinationIn)
        let fade = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
                              locations: [0, 0.45, 1])!
        let c = CGPoint(x: N / 2, y: N / 2)
        big.drawRadialGradient(fade, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(N) / 2, options: [.drawsAfterEndLocation])
        guard let soft = big.makeImage() else { return nil }
        return AlbumField(base: base, soft: soft)
    }

    nonisolated(unsafe) private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
}

// MARK: - Backdrop

struct StandByBackdrop: View {
    enum Scene: Equatable { case picture, album }

    let scene: Scene
    let images: Wallpapers.Images?
    /// The album's fields (see `StandByStage.albumField`).
    let album: StandByStage.AlbumField?
    let playing: Bool
    /// Black laid over the picture so what's on it reads (0 – 1).
    let shade: Double
    let night: Bool

    var body: some View {
        if RenderMode.snapshot {
            still
        } else {
            BackdropLayers(scene: scene, picture: images?.picture, album: album, playing: playing, shade: shade, night: night)
        }
    }

    private var still: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if !night, scene == .picture, let pic = images?.picture {
                    Image(decorative: pic, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(StandByStage.restScale)
                        .clipped()
                }
                if !night, scene == .album, let album {
                    ForEach(Array(AlbumBlob.all.enumerated()), id: \.offset) { i, blob in
                        let side = max(geo.size.width, geo.size.height) * blob.size
                        Image(decorative: i == 0 ? album.base : album.soft, scale: 1).resizable().interpolation(.high)
                            .scaleEffect(x: blob.flip ? -1 : 1, y: 1)
                            .frame(width: side, height: side)
                            .rotationEffect(.degrees(blob.phase))
                            .position(x: geo.size.width * blob.center.x, y: geo.size.height * blob.center.y)
                            .opacity(blob.opacity)
                    }
                }
                Color.black.opacity(night ? 1 : scene == .album ? 0.12 : shade)
                RadialGradient(colors: [.clear, .black.opacity(scene == .album ? 0.5 : 0.28)], center: .center,
                               startRadius: geo.size.height * 0.35, endRadius: geo.size.width * 0.75)
            }
            .clipped()
        }
    }
}

/// The album scene: four copies of the cover's field, each turning slowly about its own centre, in its own direction.
struct AlbumBlob {
    let center: CGPoint
    /// Side, as a multiple of the screen's longer edge.
    let size: CGFloat
    let period: Double
    let clockwise: Bool
    let flip: Bool
    let opacity: Double
    /// Where it starts (degrees), so the still drawing isn't four squares aligned.
    let phase: Double

    static let all: [AlbumBlob] = [
        AlbumBlob(center: CGPoint(x: 0.5, y: 0.5), size: 1.5, period: 90, clockwise: true, flip: false, opacity: 1, phase: 0),
        AlbumBlob(center: CGPoint(x: 0.22, y: 0.3), size: 1.0, period: 64, clockwise: false, flip: true, opacity: 0.8, phase: 70),
        AlbumBlob(center: CGPoint(x: 0.8, y: 0.68), size: 0.95, period: 52, clockwise: true, flip: false, opacity: 0.7, phase: 160),
        AlbumBlob(center: CGPoint(x: 0.6, y: 0.18), size: 0.7, period: 40, clockwise: false, flip: true, opacity: 0.55, phase: 250),
    ]
}

private struct BackdropLayers: NSViewRepresentable {
    let scene: StandByBackdrop.Scene
    let picture: CGImage?
    let album: StandByStage.AlbumField?
    let playing: Bool
    let shade: Double
    let night: Bool

    func makeNSView(context: Context) -> BackdropView { BackdropView() }

    func updateNSView(_ v: BackdropView, context: Context) {
        v.set(picture: picture)
        v.set(album: album)
        v.set(scene: scene, shade: shade, night: night)
        v.setMoving(playing)
    }

    final class BackdropView: NSView {
        private let holder = CALayer()
        private let picture = CALayer()
        private let albumLayer = CALayer()
        private var blobs: [CALayer] = []
        private let shadeLayer = CALayer()
        private let vignette = CAGradientLayer()
        private let grain = CALayer()
        private var pictureImage: CGImage?
        private var albumImage: StandByStage.AlbumField?
        private var driftSize = CGSize.zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true

            picture.contentsGravity = .resizeAspectFill
            picture.minificationFilter = .trilinear
            picture.opacity = 0
            holder.addSublayer(picture)
            layer?.addSublayer(holder)

            albumLayer.opacity = 0
            for blob in AlbumBlob.all {
                let l = CALayer()
                l.contentsGravity = .resize
                l.magnificationFilter = .linear
                l.allowsEdgeAntialiasing = true
                l.opacity = Float(blob.opacity)
                albumLayer.addSublayer(l)
                blobs.append(l)
            }
            layer?.addSublayer(albumLayer)

            shadeLayer.backgroundColor = NSColor.black.cgColor
            shadeLayer.opacity = 0
            layer?.addSublayer(shadeLayer)

            vignette.type = .radial
            vignette.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.3).cgColor]
            vignette.locations = [0.45, 1]
            vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
            vignette.endPoint = CGPoint(x: 1.15, y: 1.15)
            layer?.addSublayer(vignette)

            grain.backgroundColor = NSColor(patternImage: StandByStage.grain).cgColor
            grain.opacity = 0
            layer?.addSublayer(grain)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let b = bounds
            for l in [holder, picture, albumLayer, shadeLayer, vignette, grain] as [CALayer] { l.frame = b }
            let long = max(b.width, b.height)
            for (l, blob) in zip(blobs, AlbumBlob.all) {
                let side = long * blob.size
                l.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                // Layers here are y-up.
                l.position = CGPoint(x: b.width * blob.center.x, y: b.height * (1 - blob.center.y))
                l.transform = CATransform3DRotate(CATransform3DMakeScale(blob.flip ? -1 : 1, 1, 1), blob.phase * .pi / 180, 0, 0, 1)
            }
            CATransaction.commit()
            if b.size != driftSize, b.width > 0 {
                driftSize = b.size
                StandByStage.addDrift(to: holder, size: b.size)
                addSpin()
            }
        }

        func set(picture image: CGImage?) {
            guard image !== pictureImage else { return }
            let first = pictureImage == nil
            pictureImage = image
            if !first, image != nil {
                let fade = CABasicAnimation(keyPath: "contents")
                fade.duration = 1.6
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                picture.add(fade, forKey: "contents")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.contents = image
            CATransaction.commit()
        }

        func set(album image: StandByStage.AlbumField?) {
            guard image?.base !== albumImage?.base else { return }
            let first = albumImage == nil
            albumImage = image
            for (i, l) in blobs.enumerated() {
                if !first {
                    let fade = CABasicAnimation(keyPath: "contents")
                    fade.duration = 1.2
                    fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    l.add(fade, forKey: "contents")
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                l.contents = i == 0 ? image?.base : image?.soft
                CATransaction.commit()
            }
        }

        func set(scene: StandByBackdrop.Scene, shade: Double, night: Bool) {
            let pictureOn: Float = !night && scene == .picture && pictureImage != nil ? 1 : 0
            let albumOn: Float = !night && scene == .album && albumImage != nil ? 1 : 0
            let shadeTo = Float(scene == .album ? 0.12 : shade)
            let vignetteTo: Float = night ? 0 : scene == .album ? 1.2 : 1
            guard picture.opacity != pictureOn || albumLayer.opacity != albumOn || shadeLayer.opacity != shadeTo
                    || vignette.opacity != vignetteTo else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(night ? 2 : 1.1)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            picture.opacity = pictureOn
            albumLayer.opacity = albumOn
            shadeLayer.opacity = shadeTo
            vignette.opacity = vignetteTo
            // The pictures carry their own dither; only the album's stretched colours need grain.
            grain.opacity = !night && scene == .album ? 0.6 : 0
            CATransaction.commit()
        }

        private func addSpin() {
            for (l, blob) in zip(blobs, AlbumBlob.all) {
                l.removeAnimation(forKey: "spin")
                guard !Access.reduceMotion else { continue }
                // Additive, on top of the layer's own flip and starting angle.
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = 0
                a.toValue = (blob.clockwise ? -2 : 2) * Double.pi
                a.isAdditive = true
                a.duration = blob.period
                a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                l.add(a, forKey: "spin")
            }
        }

        /// Pausing the song stills the colours where they are; playing picks up from there.
        func setMoving(_ on: Bool) {
            let l = albumLayer
            if on, l.speed == 0 {
                let paused = l.timeOffset
                l.speed = 1
                l.timeOffset = 0
                l.beginTime = 0
                l.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) - paused
            } else if !on, l.speed != 0 {
                l.timeOffset = l.convertTime(CACurrentMediaTime(), from: nil)
                l.speed = 0
            }
        }
    }
}

// MARK: - Depth

/// The wallpaper's foreground, drawn over the clock and drifting exactly as the picture behind it does.
struct StandByDepth: View {
    let image: CGImage?
    let visible: Bool

    var body: some View {
        if RenderMode.snapshot {
            GeometryReader { geo in
                if visible, let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(StandByStage.restScale)
                        .clipped()
                }
            }
            .allowsHitTesting(false)
        } else {
            DepthLayer(image: image, visible: visible)
        }
    }
}

private struct DepthLayer: NSViewRepresentable {
    let image: CGImage?
    let visible: Bool

    func makeNSView(context: Context) -> DepthView { DepthView() }

    func updateNSView(_ v: DepthView, context: Context) {
        v.set(image: image, visible: visible)
    }

    final class DepthView: NSView {
        private let holder = CALayer()
        private let front = CALayer()
        private var current: CGImage?
        private var driftSize = CGSize.zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            front.contentsGravity = .resizeAspectFill
            front.minificationFilter = .trilinear
            front.opacity = 0
            holder.addSublayer(front)
            layer?.addSublayer(holder)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            holder.frame = bounds
            front.frame = bounds
            CATransaction.commit()
            if bounds.size != driftSize, bounds.width > 0 {
                driftSize = bounds.size
                StandByStage.addDrift(to: holder, size: bounds.size)
            }
        }

        func set(image: CGImage?, visible: Bool) {
            if image !== current {
                let swap = current != nil && image != nil
                current = image
                if swap {
                    let fade = CABasicAnimation(keyPath: "contents")
                    fade.duration = 1.6
                    fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    front.add(fade, forKey: "contents")
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                front.contents = image
                CATransaction.commit()
            }
            let to: Float = visible && image != nil ? 1 : 0
            guard front.opacity != to else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.1)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            front.opacity = to
            CATransaction.commit()
        }
    }
}
