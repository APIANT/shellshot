import Foundation

struct Session: Codable, Identifiable, Hashable {
    let sessionId: String
    let pid: Int
    let tty: String
    let path: String?
    let name: String?
    let lastActive: Double?
    let isActive: Bool?

    var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case pid, tty, path, name
        case lastActive = "last_active"
        case isActive = "is_active"
    }

    var displayName: String {
        let dir = (path as NSString?)?.lastPathComponent ?? "?"
        // iTerm2's autoName carries Claude's spinner glyph (✳/✻/⚹…) — strip
        // leading symbols so the picker shows just the session title.
        let clean = (name ?? "").drop { !($0.isLetter || $0.isNumber) }
        if !clean.isEmpty { return "\(dir) — \(clean)" }
        return dir
    }

    var ageLabel: String {
        guard let lastActive else { return "" }
        let secs = Date().timeIntervalSince1970 - lastActive
        if secs < 90 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86400))d ago"
    }
}

/// Wraps the Python iTerm2 sidecar (prototype/shellshot.py).
enum Sidecar {
    static var root: URL {
        if let env = ProcessInfo.processInfo.environment["SHELLSHOT_ROOT"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("shellshot")
    }

    /// Prefer the PyInstaller-bundled sidecar inside the .app; fall back to
    /// the dev venv + script for `swift run` during development.
    private static var command: [String] {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("sidecar/shellshot-sidecar").path,
            FileManager.default.isExecutableFile(atPath: bundled) {
            return [bundled]
        }
        return [
            root.appendingPathComponent("prototype/.venv/bin/python").path,
            root.appendingPathComponent("prototype/shellshot.py").path,
        ]
    }

    private static func run(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let cmd = command
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd[0])
        p.arguments = Array(cmd.dropFirst()) + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, stdout, stderr)
    }

    static func listSessions() throws -> [Session] {
        let r = try run(["list", "--json"])
        guard r.status == 0, let data = r.stdout.data(using: .utf8) else {
            throw SidecarError.failed(r.stderr.isEmpty ? r.stdout : r.stderr)
        }
        return try JSONDecoder().decode([Session].self, from: data)
    }

    static func inject(sessionId: String, imagePaths: [String], message: String) throws {
        var args = ["send", "--session", sessionId]
        if imagePaths.isEmpty {
            args.append("--no-capture")
        } else {
            for p in imagePaths { args += ["--image", p] }
        }
        args.append(message)
        let r = try run(args)
        guard r.status == 0 else {
            throw SidecarError.failed(r.stderr.isEmpty ? r.stdout : r.stderr)
        }
    }

    /// Type a saved phrase into a session. `submit: false` leaves it in the
    /// prompt for the user to finish.
    static func sendText(sessionId: String, text: String, submit: Bool) throws {
        var args = ["send", "--session", sessionId, "--no-capture"]
        if !submit { args.append("--no-submit") }
        args += ["--", text] // a phrase may legitimately start with "-"
        let r = try run(args)
        guard r.status == 0 else {
            throw SidecarError.failed(r.stderr.isEmpty ? r.stdout : r.stderr)
        }
    }
}

enum SidecarError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let msg) = self { return msg }
        return nil
    }
}
