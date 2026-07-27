import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureKey: HotKey?
    private var recordKey: HotKey?
    private let panel = SendPanelController()
    private let recorder = Recorder()
    private let regionSelector = RegionSelector()
    private var server: HTTPServer?
    private var listenerItem: NSMenuItem?
    private let pairingWindow = PairingWindowController()
    private var phraseKey: HotKey?
    private let phrasePanel = PhrasePanelController()

    /// Menu items rebuilt from the phrase file each time the menu opens.
    private static let phraseTag = 900

    /// Last known session list. The menu can't wait on the sidecar without
    /// stalling, so it shows this and refreshes for the next open.
    private var cachedSessions: [Session] = []

    static let listenerPort: UInt16 = 8472

    static var pairingToken: String {
        let d = UserDefaults.standard
        if let t = d.string(forKey: "pairingToken") { return t }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        d.set(t, forKey: "pairingToken")
        return t
    }

    static var supportDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ShellShot")
    }

    static var shotDir: URL {
        supportDir.appendingPathComponent("shots")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)

        let menu = NSMenu()
        menu.delegate = self
        let phraseSearch = NSMenuItem(title: "Send Phrase… (⌥⌘K)", action: #selector(showPhrasePanel), keyEquivalent: "")
        phraseSearch.target = self
        menu.addItem(phraseSearch)
        let editPhrases = NSMenuItem(title: "Edit Phrases…", action: #selector(editPhrases), keyEquivalent: "")
        editPhrases.target = self
        menu.addItem(editPhrases)
        menu.addItem(.separator())
        let capture = NSMenuItem(title: "Capture & Send (⌥⌘C)", action: #selector(captureAndSend), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        let record = NSMenuItem(title: "Record & Send (⌥⌘R)", action: #selector(toggleRecord), keyEquivalent: "")
        record.target = self
        menu.addItem(record)
        menu.addItem(.separator())
        let clipboardDefault = NSMenuItem(title: "Copy to Clipboard by Default", action: #selector(toggleClipboardDefault(_:)), keyEquivalent: "")
        clipboardDefault.target = self
        clipboardDefault.state = UserDefaults.standard.bool(forKey: "copyToClipboardDefault") ? .on : .off
        menu.addItem(clipboardDefault)
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
        phraseKey = HotKey(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(optionKey | cmdKey)
        ) { [weak self] in
            self?.showPhrasePanel()
        }
        recorder.onAutoStop = { [weak self] in self?.toggleRecord() }
        Phrases.createDefaultFile()
        refreshSessions() // so the first menu open shows a real target, not "none"
    }

    // MARK: - Phrases

    /// Rebuild the phrase section from the file every time the menu opens, so
    /// an edit shows up without a restart.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.phraseTag {
            menu.removeItem(item)
        }
        refreshSessions()
        var i = 0
        let target = NSMenuItem(title: targetLabel(), action: nil, keyEquivalent: "")
        target.tag = Self.phraseTag
        target.isEnabled = false
        menu.insertItem(target, at: i)
        i += 1
        for phrase in Phrases.load() {
            let item = NSMenuItem(title: phrase.name, action: #selector(sendPhraseFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Self.phraseTag
            item.toolTip = phrase.text
            item.representedObject = phrase
            menu.insertItem(item, at: i)
            i += 1
        }
        if i > 0 {
            let sep = NSMenuItem.separator()
            sep.tag = Self.phraseTag
            menu.insertItem(sep, at: i)
        }
    }

    /// Where a phrase picked right now would land, from the cached list.
    private func targetLabel() -> String {
        guard !cachedSessions.isEmpty else { return "No Claude Code session in iTerm2" }
        let sid = Self.resolveSession(nil, in: cachedSessions)
        let name = cachedSessions.first(where: { $0.sessionId == sid })?.displayName ?? sid
        return "→ \(name)"
    }

    private func refreshSessions() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sessions = (try? Sidecar.listSessions()) ?? []
            DispatchQueue.main.async { self?.cachedSessions = sessions }
        }
    }

    @objc private func sendPhraseFromMenu(_ item: NSMenuItem) {
        guard let phrase = item.representedObject as? Phrase else { return }
        send(phrase)
    }

    @objc func editPhrases() {
        Phrases.openInEditor()
    }

    @objc func showPhrasePanel() {
        if phrasePanel.isOpen {
            phrasePanel.close()
            return
        }
        let phrases = Phrases.load()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sessions = (try? Sidecar.listSessions()) ?? []
            let target = sessions.isEmpty
                ? nil
                : sessions.first(where: { $0.sessionId == Self.resolveSession(nil, in: sessions) })
            DispatchQueue.main.async {
                guard let self else { return }
                self.cachedSessions = sessions
                self.phrasePanel.show(phrases: phrases, target: target?.displayName) { phrase in
                    self.send(phrase, to: target?.sessionId)
                }
            }
        }
    }

    /// Send a phrase to the focused Claude session. Option inverts the phrase's
    /// own send-or-type setting.
    private func send(_ phrase: Phrase, to sessionId: String? = nil) {
        let flipped = NSEvent.modifierFlags.contains(.option)
        let submit = phrase.typeOnly ? flipped : !flipped
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var sid = sessionId
                if sid == nil {
                    let sessions = try Sidecar.listSessions()
                    guard !sessions.isEmpty else {
                        throw SidecarError.failed("No Claude Code sessions found in iTerm2.")
                    }
                    sid = Self.resolveSession(nil, in: sessions)
                }
                guard let sid else { return }
                try Sidecar.sendText(sessionId: sid, text: phrase.text, submit: submit)
                DispatchQueue.main.async {
                    UserDefaults.standard.set(sid, forKey: "lastSessionId")
                    // Hand focus straight back so the run is visible without a Cmd-Tab.
                    NSRunningApplication
                        .runningApplications(withBundleIdentifier: "com.googlecode.iterm2")
                        .first?
                        .activate(options: [])
                }
            } catch {
                DispatchQueue.main.async {
                    self?.alert("Could not send the phrase: \(error.localizedDescription)")
                }
            }
        }
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

    @objc func toggleClipboardDefault(_ item: NSMenuItem) {
        let d = UserDefaults.standard
        let enabled = !d.bool(forKey: "copyToClipboardDefault")
        d.set(enabled, forKey: "copyToClipboardDefault")
        item.state = enabled ? .on : .off
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
            let sid = Self.resolveSession(sessionId, in: sessions)
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

    /// Resolve a session from an /inject request: the value may be an exact
    /// session id, a /labels string with the id in ⟦…⟧, or a display-name
    /// substring. Falls back to the focused session, then the most recent.
    static func resolveSession(_ raw: String?, in sessions: [Session]) -> String {
        if let raw, !raw.isEmpty {
            // The routing key is a session-id prefix. It arrives either as the
            // leading token of a "<id8>  <name>" label, an old ⟦id⟧ tag, or a
            // bare id (the Shortcut may truncate the label at the first space).
            var key = raw
            if let l = raw.range(of: "⟦"), let r = raw.range(of: "⟧"), l.upperBound <= r.lowerBound {
                key = String(raw[l.upperBound..<r.lowerBound])
            } else if let first = raw.split(separator: " ").first {
                key = String(first)
            }
            if let m = sessions.first(where: { $0.sessionId == key || $0.sessionId.hasPrefix(key) }) {
                return m.sessionId
            }
            if let m = sessions.first(where: { $0.displayName.contains(raw) }) { return m.sessionId }
        }
        let lastUsed = UserDefaults.standard.string(forKey: "lastSessionId")
        return sessions.first(where: { $0.isActive == true })?.sessionId
            ?? sessions.first(where: { $0.sessionId == lastUsed })?.sessionId
            ?? sessions.first!.sessionId
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
