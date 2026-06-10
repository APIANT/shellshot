import AppKit
import SwiftUI

/// One annotation arrow, endpoints normalized to 0–1 image coordinates
/// (top-left origin), so the same data renders in the preview and at
/// full pixel resolution on export.
struct Arrow: Equatable {
    var start: CGPoint
    var end: CGPoint

    static let red = CGColor(red: 0.93, green: 0.11, blue: 0.14, alpha: 1) // Monosnap red

    /// Tapered-shaft arrow polygon: thin tail widening into a filled
    /// triangular head, like Monosnap's. Points are in the target
    /// coordinate space; `size` is that space's dimensions.
    func polygon(in size: CGSize) -> [CGPoint] {
        let p0 = CGPoint(x: start.x * size.width, y: start.y * size.height)
        let p1 = CGPoint(x: end.x * size.width, y: end.y * size.height)
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let len = max(hypot(dx, dy), 0.001)
        let dir = CGPoint(x: dx / len, y: dy / len)
        let perp = CGPoint(x: -dir.y, y: dir.x)
        // Proportions scale with the drawing space so preview and export match
        let unit = min(size.width, size.height) / 100
        let headLen = min(max(len * 0.3, 5 * unit), 12 * unit)
        let headW = headLen * 0.7
        let neckW = headW * 0.32
        let tailW = max(unit * 0.6, headW * 0.1)
        let base = CGPoint(x: p1.x - dir.x * headLen, y: p1.y - dir.y * headLen)

        func off(_ p: CGPoint, _ w: CGFloat) -> CGPoint {
            CGPoint(x: p.x + perp.x * w, y: p.y + perp.y * w)
        }
        return [
            off(p0, tailW / 2),
            off(base, neckW / 2),
            off(base, headW / 2),
            p1,
            off(base, -headW / 2),
            off(base, -neckW / 2),
            off(p0, -tailW / 2),
        ]
    }

    func path(in size: CGSize) -> Path {
        var p = Path()
        let pts = polygon(in: size)
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        return p
    }
}

enum Annotator {
    /// Composite arrows onto an image in memory at full pixel resolution.
    static func composite(image: NSImage, arrows: [Arrow]) throws -> CGImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SidecarError.failed("Could not read image")
        }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SidecarError.failed("Could not create drawing context")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext is bottom-left origin; arrows are top-left normalized — flip
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(Arrow.red)
        let size = CGSize(width: w, height: h)
        for arrow in arrows {
            let pts = arrow.polygon(in: size)
            ctx.beginPath()
            ctx.move(to: pts[0])
            for pt in pts.dropFirst() { ctx.addLine(to: pt) }
            ctx.closePath()
            ctx.fillPath()
        }
        guard let outCG = ctx.makeImage() else {
            throw SidecarError.failed("Could not render annotated image")
        }
        return outCG
    }

    /// Composite arrows onto the image at full pixel resolution and write
    /// a new PNG next to the original. Returns the annotated file's path.
    static func render(imagePath: String, arrows: [Arrow]) throws -> String {
        guard let image = NSImage(contentsOfFile: imagePath) else {
            throw SidecarError.failed("Could not read \(imagePath)")
        }
        let outCG = try composite(image: image, arrows: arrows)
        let outPath = (imagePath as NSString).deletingPathExtension + "-annotated.png"
        let url = URL(fileURLWithPath: outPath) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
            throw SidecarError.failed("Could not write \(outPath)")
        }
        CGImageDestinationAddImage(dest, outCG, nil)
        CGImageDestinationFinalize(dest)
        return outPath
    }
}
