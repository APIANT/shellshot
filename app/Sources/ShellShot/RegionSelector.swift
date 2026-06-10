import AppKit

/// Full-screen drag-to-select overlay (one window per display).
/// Returns the selected rect in `screencapture -R` coordinates
/// (global, top-left origin), or nil on Esc.
/// Borderless windows refuse key status by default, which would break Esc.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class RegionSelector {
    private var windows: [NSWindow] = []
    private var completion: ((CGRect?) -> Void)?

    func select(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let win = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless, backing: .buffered, defer: false, screen: screen
            )
            win.level = .screenSaver
            win.backgroundColor = .clear
            win.isOpaque = false
            win.ignoresMouseEvents = false
            win.acceptsMouseMovedEvents = true
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onDone = { [weak self] rectInWindow in
                self?.finish(rectInWindow: rectInWindow, window: win)
            }
            view.onCancel = { [weak self] in self?.finish(rectInWindow: nil, window: win) }
            win.contentView = view
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)
            windows.append(win)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.set()
    }

    private func finish(rectInWindow: NSRect?, window: NSWindow) {
        let done = completion
        completion = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        guard let r = rectInWindow, r.width > 4, r.height > 4 else {
            done?(nil)
            return
        }
        // window-local (bottom-left origin) -> global Cocoa coords
        let global = NSRect(
            x: r.origin.x + window.frame.origin.x,
            y: r.origin.y + window.frame.origin.y,
            width: r.width, height: r.height
        )
        // Cocoa (bottom-left, primary screen) -> CG / screencapture (top-left)
        let primaryHeight = NSScreen.screens[0].frame.height
        let cg = CGRect(
            x: global.origin.x,
            y: primaryHeight - global.origin.y - global.height,
            width: global.width, height: global.height
        )
        done?(cg)
    }
}

private final class SelectionView: NSView {
    var onDone: ((NSRect?) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Esc
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; current = nil }
        guard let s = start, let c = current else { onCancel?(); return }
        onDone?(rect(s, c))
    }

    private func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        guard let s = start, let c = current else { return }
        let sel = rect(s, c)
        NSColor.clear.setFill()
        sel.fill(using: .copy)
        NSColor.systemRed.setStroke()
        let border = NSBezierPath(rect: sel)
        border.lineWidth = 2
        border.stroke()
        // dimensions badge
        let label = "\(Int(sel.width)) × \(Int(sel.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let pos = NSPoint(x: sel.maxX - size.width - 6, y: max(sel.minY - size.height - 6, 4))
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSRect(x: pos.x - 4, y: pos.y - 2, width: size.width + 8, height: size.height + 4).fill()
        label.draw(at: pos, withAttributes: attrs)
    }
}
