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
    private var server: HTTPServer?
    private var listenerItem: NSMenuItem?
    private let pairingWindow = PairingWindowController()

    static let listenerPort: UInt16 = 8472

    static var pairingToken: String {
        let d = UserDefaults.standard
        if let t = d.string(forKey: "pairingToken") { return t }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        d.set(t, forKey: "pairingToken")
        return t
    }

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
        }
        let listener = NSMenuItem(title: "iPad/iPhone Sharing (port \(Self.listenerPort))", action: #selector(toggleListener(_:)), keyEquivalent: "")
        listener.target = self
        menu.addItem(listener)
        listenerItem = listener
        let setup = NSMenuItem(title: "Set Up iPad/iPhone Shortcut…", action: #selector(setUpIPadShortcut), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        let pairing = NSMenuItem(title: "Copy iPad/iPhone Pairing Info", action: #selector(copyPairingInfo), keyEquivalent: "")
        pairing.target = self
        menu.addItem(pairing)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ShellShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        if UserDefaults.standard.bool(forKey: "listenerEnabled") {
            startListener()
        }

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

    // MARK: - iPad listener

    @objc func toggleListener(_ item: NSMenuItem) {
        if server != nil {
            server?.stop()
            server = nil
            item.state = .off
            UserDefaults.standard.set(false, forKey: "listenerEnabled")
        } else {
            startListener()
            UserDefaults.standard.set(true, forKey: "listenerEnabled")
        }
    }

    private func startListener() {
        let srv = HTTPServer(port: Self.listenerPort, token: Self.pairingToken)
        srv.onListSessions = { (try? Sidecar.listSessions()) ?? [] }
        srv.onInject = { data, sessionId, message in
            try FileManager.default.createDirectory(at: Self.shotDir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let path = Self.shotDir.appendingPathComponent("ipad-\(stamp).png").path
            try data.write(to: URL(fileURLWithPath: path))

            let sessions = try Sidecar.listSessions()
            guard !sessions.isEmpty else { throw SidecarError.failed("No Claude sessions") }
            let sid = sessionId
                ?? sessions.first(where: { $0.isActive == true })?.sessionId
                ?? sessions.first!.sessionId
            let opt = Optimizer.downscale(path)
            try Sidecar.inject(sessionId: sid, imagePaths: [opt], message: message ?? "")
            return sessions.first(where: { $0.sessionId == sid })?.displayName ?? sid
        }
        srv.onShortcut = {
            try? ShortcutBuilder.signed(
                host: ProcessInfo.processInfo.hostName,
                port: Self.listenerPort, token: Self.pairingToken
            )
        }
        do {
            try srv.start()
            server = srv
            listenerItem?.state = .on
        } catch {
            alert("Could not start iPad listener on port \(Self.listenerPort): \(error.localizedDescription)")
            listenerItem?.state = .off
        }
    }

    @objc func setUpIPadShortcut() {
        if server == nil {
            startListener()
            UserDefaults.standard.set(true, forKey: "listenerEnabled")
        }
        let host = ProcessInfo.processInfo.hostName
        let url = "http://\(host):\(Self.listenerPort)/shortcut?token=\(Self.pairingToken)"
        guard let qr = qrImage(url) else {
            alert("Could not generate the QR code.")
            return
        }
        pairingWindow.show(qr: qr, url: url)
    }

    @objc func copyPairingInfo() {
        let host = ProcessInfo.processInfo.hostName
        let info = """
        ShellShot iPad/iPhone pairing
        URL:   http://\(host):\(Self.listenerPort)/inject?token=\(Self.pairingToken)
        Token: \(Self.pairingToken)

        Build a Shortcut: Take Screenshot → Get Contents of URL (POST,
        Request Body = File/the screenshot, Header X-Message = your text)
        with the URL above. The device and Mac must be on the same Wi-Fi,
        and 'iPad/iPhone Sharing' must be enabled in the ShellShot menu.
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
        alert("Pairing info copied to clipboard.\n\n\(info)")
    }

    private func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "ShellShot"
        a.informativeText = text
        a.runModal()
    }
}
