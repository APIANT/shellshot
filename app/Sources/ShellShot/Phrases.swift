import AppKit
import Foundation

/// One saved instruction: a short name plus the text sent to Claude Code.
struct Phrase: Identifiable, Hashable {
    let name: String
    let text: String
    /// `true` = type the text and leave it in the prompt; `false` = press Enter.
    let typeOnly: Bool

    var id: String { name + "\u{0}" + text }
}

/// Plain-text phrase file: `=== name` starts a phrase, the lines under it are
/// the text. `=== name [type]` marks a phrase as type-only. Anything before the
/// first header is a comment block.
enum Phrases {
    static var fileURL: URL {
        AppDelegate.supportDir.appendingPathComponent("phrases.txt")
    }

    private static let header = "==="
    private static let typeMarker = "[type]"

    /// Re-read on every use so an edit is live as soon as the file is saved.
    static func load() -> [Phrase] {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            createDefaultFile()
            return (try? String(contentsOf: fileURL, encoding: .utf8)).map(parse) ?? []
        }
        return parse(raw)
    }

    static func parse(_ raw: String) -> [Phrase] {
        var out: [Phrase] = []
        var name: String?
        var typeOnly = false
        var body: [String] = []

        func flush() {
            guard let n = name else { return }
            let text = body.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(Phrase(name: n, text: text, typeOnly: typeOnly)) }
        }

        for line in raw.components(separatedBy: .newlines) {
            guard line.hasPrefix(header) else {
                if name != nil { body.append(line) }
                continue
            }
            flush()
            var title = line.dropFirst(header.count)
                .trimmingCharacters(in: .whitespaces)
            typeOnly = title.lowercased().hasSuffix(typeMarker)
            if typeOnly {
                title = String(title.dropLast(typeMarker.count))
                    .trimmingCharacters(in: .whitespaces)
            }
            name = title.isEmpty ? "(unnamed)" : title
            body = []
        }
        flush()
        return out
    }

    static func matches(_ query: String, in phrases: [Phrase]) -> [Phrase] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return phrases }
        // Name hits rank above body hits; original file order breaks ties.
        let byName = phrases.filter { $0.name.lowercased().contains(q) }
        let byText = phrases.filter {
            !$0.name.lowercased().contains(q) && $0.text.lowercased().contains(q)
        }
        return byName + byText
    }

    static func createDefaultFile() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? Self.template.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Open in the user's default editor for .txt.
    static func openInEditor() {
        createDefaultFile()
        NSWorkspace.shared.open(fileURL)
    }

    private static let template = """
    # ShellShot phrases — instructions you send into Claude Code often.
    #
    # A line starting with === names a phrase. Everything under it, up to the
    # next ===, is the text that gets sent. Blank lines between phrases are
    # ignored, and these notes at the top are ignored too.
    #
    # Phrases are sent with Enter pressed for you. Add [type] after the name to
    # have it typed into the prompt and left there instead. Holding Option while
    # picking a phrase does the opposite of whatever it normally does.
    #
    # Saving this file updates the list right away — no restart.

    === merge and deploy
    merge pr, deploy local+prod (override)

    === run the drain
    run the drain

    === wrap up
    /wrap-up

    === commit [type]
    commit and push
    """
}
