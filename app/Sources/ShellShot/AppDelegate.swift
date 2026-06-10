import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var captureKey: HotKey?
    private var recordKey: HotKey?
    private let panel = SendPanelController()
    private let recorder = Recorder()
    private let regionSelector = RegionSelector()

    static var shotDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ShellShot/shots")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)

        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture & Send (⌥⌘C)", action: #selector(captureAndSend), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        let record = NSMenuItem(title: "Record & Send (⌥⌘R)", action: #selector(toggleRecord), keyEquivalent: "")
        record.target = self
        menu.addItem(record)
        menu.addItem(.separator())
        if Bundle.main.bundleIdentifier != nil {
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "Quit ShellShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        DispatchQueue.global(qos: .utility).async {
            Optimizer.prune(dir: Self.shotDir)
        }

        captureKey = HotKey(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(optionKey | cmdKey)
        ) { [weak self] in
            self?.captureAndSend()
        }
        recordKey = HotKey(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(optionKey | cmdKey)
        ) { [weak self] in
            self?.toggleRecord()
        }
        recorder.onAutoStop = { [weak self] in self?.toggleRecord() }
    }

    private func setIcon(recording: Bool) {
        statusItem.button?.image = NSImage(
            systemSymbolName: recording ? "record.circle.fill" : "camera.viewfinder",
            accessibilityDescription: "ShellShot"
        )
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: - Single capture

    @objc func captureAndSend() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let shotPath = self.capture() else { return } // Esc = cancel
            DispatchQueue.main.async {
                guard let image = NSImage(contentsOfFile: shotPath) else { return }
                self.presentPanel(frames: [Frame(path: shotPath, image: image)])
            }
        }
    }

    /// Interactive area capture. Returns nil if the user cancelled.
    private func capture() -> String? {
        try? FileManager.default.createDirectory(at: Self.shotDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let path = Self.shotDir.appendingPathComponent("shot-\(stamp).png").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", path]
        try? p.run()
        p.waitUntilExit()
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - Recording

    @objc func toggleRecord() {
        if recorder.isRecording {
            let paths = recorder.stop()
            setIcon(recording: false)
            guard !paths.isEmpty else { return }
            let frames = paths.compactMap { p -> Frame? in
                NSImage(contentsOfFile: p).map { Frame(path: p, image: $0) }
            }
            presentPanel(frames: frames)
        } else {
            regionSelector.select { [weak self] rect in
                guard let self, let rect else { return }
                self.setIcon(recording: true)
                self.recorder.start(rect: rect)
            }
        }
    }

    // MARK: - Panel + injection

    private func presentPanel(frames: [Frame]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sessions = (try? Sidecar.listSessions()) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                if sessions.isEmpty {
                    self.alert("No Claude Code sessions found in iTerm2.")
                    return
                }
                self.panel.show(frames: frames, sessions: sessions) { sid, msg, arrows, paths in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            var finalPaths = paths
                            if paths.count == 1 && !arrows.isEmpty {
                                finalPaths = [try Annotator.render(imagePath: paths[0], arrows: arrows)]
                            }
                            // clipboard gets the full-res (annotated) image...
                            if finalPaths.count == 1, let img = NSImage(contentsOfFile: finalPaths[0]) {
                                DispatchQueue.main.async {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.writeObjects([img])
                                }
                            }
                            // ...while Claude gets 1280px JPEG q75 to save tokens
                            finalPaths = finalPaths.map { Optimizer.downscale($0) }
                            try Sidecar.inject(sessionId: sid, imagePaths: finalPaths, message: msg)
                        } catch {
                            DispatchQueue.main.async {
                                self.alert("Injection failed: \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
        }
    }

    @objc func toggleLaunchAtLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                item.state = .off
            } else {
                try SMAppService.mainApp.register()
                item.state = .on
            }
        } catch {
            alert("Could not update Launch at Login: \(error.localizedDescription)")
        }
    }

    private func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "ShellShot"
        a.informativeText = text
        a.runModal()
    }
}
