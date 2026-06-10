import AppKit

/// Polls `screencapture -R` on a timer, then dedups frames perceptually
/// and thins to the frame cap.
final class Recorder {
    static let frameCap = 20
    static let interval: TimeInterval = 0.7
    static let maxDuration: TimeInterval = 30

    private(set) var isRecording = false
    private var timer: DispatchSourceTimer?
    private var dir: URL!
    private var rect: CGRect = .zero
    private var frameIndex = 0
    var onAutoStop: (() -> Void)?

    func start(rect: CGRect) {
        self.rect = rect
        frameIndex = 0
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        dir = AppDelegate.shotDir.appendingPathComponent("rec-\(stamp)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        isRecording = true

        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: Self.interval)
        let deadline = Date().addingTimeInterval(Self.maxDuration)
        t.setEventHandler { [weak self] in
            guard let self, self.isRecording else { return }
            if Date() > deadline {
                DispatchQueue.main.async { self.onAutoStop?() }
                return
            }
            self.captureFrame()
        }
        timer = t
        t.resume()
    }

    /// Stops and returns deduped, capped frame paths (chronological).
    func stop() -> [String] {
        isRecording = false
        timer?.cancel()
        timer = nil
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".png") }
            .sorted()
            .map { dir.appendingPathComponent($0).path }
        let kept = dedup(paths: all)
        // remove dropped duplicates from disk
        for p in all where !kept.contains(p) {
            try? FileManager.default.removeItem(atPath: p)
        }
        return thin(kept, to: Self.frameCap)
    }

    private func captureFrame() {
        let path = dir.appendingPathComponent(String(format: "frame-%03d.png", frameIndex)).path
        frameIndex += 1
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = [
            "-x",
            "-R\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))",
            path,
        ]
        try? p.run()
        p.waitUntilExit()
    }

    private func dedup(paths: [String]) -> [String] {
        var kept: [String] = []
        var lastHash: UInt64?
        for p in paths {
            guard let img = NSImage(contentsOfFile: p), let h = dHash(img) else { continue }
            if let last = lastHash, hamming(h, last) <= 4 { continue } // near-identical
            kept.append(p)
            lastHash = h
        }
        return kept
    }

    /// Evenly thin to `cap`, always keeping first and last.
    private func thin(_ paths: [String], to cap: Int) -> [String] {
        guard paths.count > cap, cap >= 2 else { return paths }
        let step = Double(paths.count - 1) / Double(cap - 1)
        var out: [String] = []
        for i in 0..<cap {
            out.append(paths[Int((Double(i) * step).rounded())])
        }
        return Array(NSOrderedSet(array: out)) as! [String]
    }
}

/// 64-bit difference hash: 9x8 grayscale, compare horizontal neighbors.
func dHash(_ image: NSImage) -> UInt64? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = 9, h = 8
    var pixels = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(
        data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .low
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var hash: UInt64 = 0
    for row in 0..<h {
        for col in 0..<(w - 1) {
            hash <<= 1
            if pixels[row * w + col] > pixels[row * w + col + 1] { hash |= 1 }
        }
    }
    return hash
}

func hamming(_ a: UInt64, _ b: UInt64) -> Int {
    (a ^ b).nonzeroBitCount
}
