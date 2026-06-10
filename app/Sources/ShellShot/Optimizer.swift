import AppKit

enum Optimizer {
    /// Downscale and re-encode as JPEG. Returns the new path, or the
    /// original if it can't be processed. The width cap is adaptive:
    /// region captures get 1280px, but very wide grabs (full-screen)
    /// keep 2000px so small UI text stays legible to Claude.
    static func downscale(_ path: String, quality: CGFloat = 0.75) -> String {
        guard let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return path
        }
        let maxWidth = cg.width > 2000 ? 2000 : 1280
        let scale = min(CGFloat(maxWidth) / CGFloat(cg.width), 1)
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return path }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let outCG = ctx.makeImage() else { return path }
        let outPath = (path as NSString).deletingPathExtension + "-opt.jpg"
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: outPath) as CFURL, "public.jpeg" as CFString, 1, nil
        ) else { return path }
        CGImageDestinationAddImage(dest, outCG, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? outPath : path
    }

    /// Delete captures older than `days` from the shots directory.
    static func prune(dir: URL, days: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in items {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if mtime < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
