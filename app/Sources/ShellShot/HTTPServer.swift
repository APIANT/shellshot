import Foundation
import Network

/// Minimal HTTP/1.1 listener so an iPad (same Wi-Fi) can POST a screenshot.
/// Token-guarded. Routes:
///   GET  /sessions?token=…                          -> JSON [Session]
///   POST /inject?token=…[&session=…][&message=…]    body = image bytes
///        (session/message may also be X-Session / X-Message headers)
final class HTTPServer {
    private var listener: NWListener?
    let port: UInt16
    let token: String
    var onListSessions: (() -> [Session])?
    var onInject: ((Data, String?, String?) throws -> String)?
    var onShortcut: (() -> Data?)?

    init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInitiated))
            self?.receive(conn, buffer: Data())
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = self.parse(buf) {
                self.respond(conn, req)
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    /// Returns nil if more bytes are still needed.
    private func parse(_ buf: Data) -> Request? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerStr = String(data: buf.subdata(in: buf.startIndex..<headerEnd.lowerBound), encoding: .utf8) else {
            return nil
        }
        let lines = headerStr.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            let k = line[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buf.distance(from: bodyStart, to: buf.endIndex) >= contentLength else { return nil }
        let body = buf.subdata(in: bodyStart..<buf.index(bodyStart, offsetBy: contentLength))

        let split = target.split(separator: "?", maxSplits: 1)
        let path = String(split.first ?? "")
        var query: [String: String] = [:]
        if split.count > 1 {
            for pair in split[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let val = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = val
            }
        }
        return Request(method: method, path: path, query: query, headers: headers, body: body)
    }

    private func respond(_ conn: NWConnection, _ req: Request) {
        guard req.query["token"] == token || req.headers["x-token"] == token else {
            send(conn, "401 Unauthorized", "text/plain", Data("bad token\n".utf8))
            return
        }
        switch (req.method, req.path) {
        case ("GET", "/shortcut"):
            if let data = onShortcut?() {
                send(conn, "200 OK", "application/octet-stream", data,
                     extraHeaders: ["Content-Disposition": "attachment; filename=\"ShellShot.shortcut\""])
            } else {
                send(conn, "500 Internal Server Error", "text/plain", Data("shortcut build failed\n".utf8))
            }

        case ("GET", "/sessions"):
            let sessions = onListSessions?() ?? []
            let data = (try? JSONEncoder().encode(sessions)) ?? Data("[]".utf8)
            send(conn, "200 OK", "application/json", data)

        case ("GET", "/labels"):
            // A JSON array of display strings. A Shortcut "Get Contents of URL"
            // turns a JSON-array response into a list it can Choose from
            // directly. The session id is appended in ⟦…⟧ so /inject recovers it.
            // Short id goes FIRST: the iPad Shortcut truncates the chosen line
            // at the first space when sending it back, so the id must survive
            // as the leading whitespace-free token. /inject routes on it.
            let sessions = onListSessions?() ?? []
            let labels = sessions.map {
                "\($0.sessionId.prefix(8))  \($0.displayName)\($0.isActive == true ? " ●" : "")"
            }
            let data = (try? JSONEncoder().encode(labels)) ?? Data("[]".utf8)
            send(conn, "200 OK", "application/json", data)

        case ("POST", "/inject"):
            let session = req.headers["x-session"] ?? req.query["session"]
            let message = req.headers["x-message"] ?? req.query["message"]
            do {
                let result = try onInject?(req.body, session, message) ?? "ok"
                let json = #"{"ok":true,"session":"\#(result)"}"#
                send(conn, "200 OK", "application/json", Data(json.utf8))
            } catch {
                let json = #"{"ok":false,"error":"\#(error.localizedDescription)"}"#
                send(conn, "500 Internal Server Error", "application/json", Data(json.utf8))
            }

        default:
            send(conn, "404 Not Found", "text/plain", Data("not found\n".utf8))
        }
    }

    private func send(_ conn: NWConnection, _ status: String, _ contentType: String, _ body: Data,
                      extraHeaders: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }
}
