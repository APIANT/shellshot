import Foundation

/// Builds a signed ShellShot iPad Shortcut with this Mac's host/port/token
/// baked in. Uses the system `shortcuts sign` tool (always present on macOS),
/// so the result imports on any device with no "untrusted shortcuts" toggle.
enum ShortcutBuilder {
    private static let obj = "\u{FFFC}"  // attachment placeholder

    static func signed(host: String, port: UInt16, token: String) throws -> Data {
        let labelsUUID = UUID().uuidString
        let chosenUUID = UUID().uuidString
        let msgUUID = UUID().uuidString
        let injectURL = "http://\(host):\(port)/inject?token=\(token)"
        let labelsURL = "http://\(host):\(port)/labels?token=\(token)"

        func inline(_ outUUID: String, _ name: String) -> [String: Any] {
            ["WFSerializationType": "WFTextTokenString",
             "Value": ["string": obj,
                       "attachmentsByRange": ["{0, 1}": ["Type": "ActionOutput", "OutputUUID": outUUID, "OutputName": name]]]]
        }
        func actionVar(_ outUUID: String, _ name: String) -> [String: Any] {
            ["WFSerializationType": "WFTextTokenAttachment",
             "Value": ["Type": "ActionOutput", "OutputUUID": outUUID, "OutputName": name]]
        }
        // The image comes from the Share Sheet — iPadOS can't screenshot
        // programmatically — so the request body is the Shortcut Input.
        let shortcutInput: [String: Any] = [
            "WFSerializationType": "WFTextTokenAttachment",
            "Value": ["Type": "ExtensionInput"],
        ]

        func header(_ key: String, _ value: [String: Any]) -> [String: Any] {
            ["WFItemType": 0,
             "WFKey": ["WFSerializationType": "WFTextTokenString",
                       "Value": ["string": key, "attachmentsByRange": [:]]],
             "WFValue": value]
        }

        let actions: [[String: Any]] = [
            // 1. fetch the session list — a JSON-array response becomes a list
            ["WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
             "WFWorkflowActionParameters": ["UUID": labelsUUID, "WFURL": labelsURL, "WFHTTPMethod": "GET"]],
            // 2. pick a session (operates on the previous action's list)
            ["WFWorkflowActionIdentifier": "is.workflow.actions.choosefromlist",
             "WFWorkflowActionParameters": ["UUID": chosenUUID,
                "WFInput": actionVar(labelsUUID, "Contents of URL"),
                "WFChooseFromListActionPrompt": "Send to which session?"]],
            // 3. ask for a message
            ["WFWorkflowActionIdentifier": "is.workflow.actions.ask",
             "WFWorkflowActionParameters": ["UUID": msgUUID, "WFInputType": "Text",
                "WFAskActionPrompt": "Message for Claude (optional)"]],
            // 4. POST the shared image to the chosen session
            ["WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
             "WFWorkflowActionParameters": [
                "WFURL": injectURL,
                "WFHTTPMethod": "POST",
                "WFHTTPBodyType": "File",
                "WFRequestVariable": shortcutInput,
                "WFHTTPHeaders": [
                    "WFSerializationType": "WFDictionaryFieldValue",
                    "Value": ["WFDictionaryFieldValueItems": [
                        header("X-Session", inline(chosenUUID, "Chosen Item")),
                        header("X-Message", inline(msgUUID, "Provided Input")),
                    ]],
                ],
             ]],
        ]

        let plist: [String: Any] = [
            "WFWorkflowActions": actions,
            "WFWorkflowClientVersion": "2605",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowHasShortcutInputVariables": true,
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 946986751, "WFWorkflowIconGlyphNumber": 61440],
            "WFWorkflowImportQuestions": [],
            // ActionExtension => appears in the Share Sheet for images
            "WFWorkflowTypes": ["ActionExtension"],
            "WFWorkflowInputContentItemClasses": [
                "WFImageContentItem", "WFGenericFileContentItem",
            ],
        ]

        // Unique temp names so concurrent /shortcut fetches don't clobber.
        let tmp = FileManager.default.temporaryDirectory
        let stem = UUID().uuidString
        let unsigned = tmp.appendingPathComponent("\(stem)-unsigned.shortcut")
        let out = tmp.appendingPathComponent("\(stem).shortcut")
        defer { try? FileManager.default.removeItem(at: unsigned) }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: unsigned)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["sign", "--mode", "anyone", "-i", unsigned.path, "-o", out.path]
        let err = Pipe()
        p.standardError = err
        defer { try? FileManager.default.removeItem(at: out) }
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let signed = try? Data(contentsOf: out) else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "sign failed"
            throw SidecarError.failed(msg)
        }
        return signed
    }
}
