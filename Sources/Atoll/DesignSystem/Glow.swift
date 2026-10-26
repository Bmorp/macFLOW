import AppKit
import SwiftUI

/// Light, pre-rendered. SwiftUI gradients inside the island were drawn by CoreGraphics on the CPU — and redrawn
/// every frame while the shape animated (the samples showed `ripc_DrawShading` / `rgba64_shade` on the main thread,
/// up to 100+ ms a frame when Search opened). These are drawn once; the GPU only scales and tints them.
enum Glow {
    /// White radial falloff in alpha: full at the centre, gone at the edge, with a soft, light-like curve.
    static let radial: NSImage = render(size: 256) { ctx, s in
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.27), CGColor(gray: 1, alpha: 0.07), CGColor(gray: 1, alpha: 0)] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.38, 0.7, 1])!
        let c = CGPoint(x: s / 2, y: s / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
    }

    /// White, transparent at the top → opaque at the bottom.
    static let rising: NSImage = render(size: 64) { ctx, s in
        let colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 1)] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    }

    /// White, opaque on the left → transparent on the right, starting to fade past the middle.
    static let fadeRight: NSImage = render(size: 64) { ctx, s in
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: s, y: 0), options: [])
    }

    /// White, soft at both ends: clear → opaque by 20 % → opaque to 55 % → clear (the closed island's light: it fades
    /// toward the camera and at the island's outer end, so a wider shape never shows a coloured box).
    static let edges: NSImage = render(size: 64) { ctx, s in
        let colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.2, 0.55, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: s, y: 0), options: [])
    }

    private static func render(size: Int, _ draw: (CGContext, CGFloat) -> Void) -> NSImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, CGFloat(size))
        let img = NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: size, height: size))
        img.isTemplate = true
        return img
    }
}

extension Image {
    /// A glow image, stretched to fill and tinted by `foregroundStyle`.
    static func glow(_ image: NSImage) -> some View {
        Image(nsImage: image).renderingMode(.template).resizable().interpolation(.medium)
    }
}
