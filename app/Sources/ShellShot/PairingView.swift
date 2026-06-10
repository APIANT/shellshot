import AppKit
import CoreImage
import SwiftUI

func qrImage(_ string: String, scale: CGFloat = 10) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(string.data(using: .utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
    let rep = NSCIImageRep(ciImage: ci)
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
}

struct PairingView: View {
    let qr: NSImage
    let url: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Set up the iPad Shortcut")
                .font(.system(size: 20, weight: .semibold))
            Text("On your iPad (same Wi-Fi), open the Camera and point it at this code, then tap the link to add the Shortcut. The Mac's address and token are baked in.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Image(nsImage: qr)
                .interpolation(.none)
                .resizable()
                .frame(width: 240, height: 240)
            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Add it to Back Tap or the Action button for one-gesture capture. Keep “iPad Sharing” enabled in the menu.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(24)
        .frame(width: 340)
    }
}

final class PairingWindowController {
    private var window: NSWindow?

    func show(qr: NSImage, url: String) {
        close()
        let view = PairingView(qr: qr, url: url, onDone: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        let win = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = "ShellShot — iPad Setup"
        win.titlebarAppearsTransparent = true
        win.contentView = hosting
        win.setContentSize(hosting.fittingSize)
        win.center()
        win.level = .floating
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}
