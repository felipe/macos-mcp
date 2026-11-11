import CommonCrypto
import Foundation
import Network

// Channel mode: the last hop between the iMessage poller and a Claude Code
// session.
//
// `macos-mcp serve` reads chat.db and POSTs each inbound text to a webhook.
// `macos-mcp channel` is the stdio MCP server Claude Code starts. It receives
// that webhook on loopback, pushes the text into the session as a channel
// event, and passes tool calls through to the serve process unchanged. It does
// not classify, rewrite, or answer anything itself.

private let channelServerName = "macos-mcp"

private struct ChannelConfig {
    var mcpURL = "http://127.0.0.1:9200/mcp"
    var host = "127.0.0.1"
    var port: UInt16 = 7888
    var secret: String?
    var logFile: String?
    var ownerName: String?
    var ownerPhone: String?
    var mcpToken: String?
}

// MARK: - Entry

func runChannel(args: [String]) -> Never {
    var config = ChannelConfig()
    let env = ProcessInfo.processInfo.environment
    config.secret = env["MACOS_MCP_WEBHOOK_SECRET"]
    config.ownerName = env["MACOS_MCP_OWNER_NAME"]
    config.ownerPhone = env["MACOS_MCP_OWNER_PHONE"]
    var secretFile = env["MACOS_MCP_WEBHOOK_SECRET_FILE"]
    var tokenFile: String?

    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { exitWithError("\(flag) requires a value") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--mcp-url": config.mcpURL = value("--mcp-url")
        case "--host": config.host = value("--host")
        case "--port":
            guard let p = UInt16(value("--port")) else { exitWithError("--port must be a number") }
            config.port = p
        case "--webhook-secret-file": secretFile = value("--webhook-secret-file")
        case "--log-file": config.logFile = value("--log-file")
        case "--owner-name": config.ownerName = value("--owner-name")
        case "--owner-phone": config.ownerPhone = value("--owner-phone")
        case "--mcp-token-file": tokenFile = value("--mcp-token-file")
        default: exitWithError("Unknown channel option: \(args[i])")
        }
        i += 1
    }

    if let path = secretFile {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let raw = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            exitWithError("Cannot read webhook secret file: \(path)")
        }
        config.secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let secret = config.secret, !secret.isEmpty else {
        exitWithError("channel needs the webhook secret: --webhook-secret-file PATH or MACOS_MCP_WEBHOOK_SECRET")
    }
    // Same token sources as `serve`: a non-loopback serve address requires one.
    do {
        config.mcpToken = try ServeAccess.loadToken(tokenFile: tokenFile, environment: env)
    } catch {
        exitWithError("Cannot load MCP token: \(error)")
    }
    guard config.host == "127.0.0.1" || config.host == "localhost" || config.host == "::1" else {
        exitWithError("channel only listens on loopback; got --host \(config.host)")
    }

    let channel = Channel(config: config, secret: secret)
    channel.run()
}

// MARK: - Channel

private final class Channel {
    private let config: ChannelConfig
    private let secret: String
    private let stdoutLock = NSLock()
    private let logLock = NSLock()
    private let work = DispatchQueue(label: "macos-mcp.channel.work", attributes: .concurrent)
    private let net = DispatchQueue(label: "macos-mcp.channel.net")
    private var listener: NWListener?
    // Events that arrive before the client finishes its MCP handshake are held and
    // delivered in order once it has. The poller does not resend an accepted text.
    private let eventLock = NSLock()
    private var sessionReady = false
    private var heldEvents: [[String: Any]] = []
    private let session: URLSession

    init(config: ChannelConfig, secret: String) {
        self.config = config
        self.secret = secret
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 300
        sessionConfig.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: sessionConfig)
    }

    func run() -> Never {
        log("start", ["mcp": config.mcpURL, "webhook": "\(config.host):\(config.port)"])
        startListener()

        // Blocking stdin reader. EOF means Claude Code went away: exit so the
        // webhook port is released and the poller's POSTs fail loudly instead
        // of landing in a process nobody is listening to.
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            work.async { self.handle(message) }
        }
        log("stdin closed, exiting")
        exit(0)
    }

    // MARK: stdio JSON-RPC

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        // The handshake ends with notifications/initialized. Any later request also
        // proves the client is past it, so a client that skips the notification
        // still gets its held events.
        if method != "initialize" && method != "ping" { sessionBecameReady() }
        // Notifications and responses carry no id (or no method); nothing to answer.
        guard let id = message["id"], !method.isEmpty else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            respond(id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": ["listChanged": false],
                    "experimental": ["claude/channel": [String: Any]()],
                ] as [String: Any],
                "serverInfo": ["name": channelServerName, "version": appVersion],
                "instructions": """
                iMessage texts arrive as <channel source="\(channelServerName)" chat_id="..." chat_type="direct|group" user="...">. \
                The sender only sees iMessage, never this session's output. Answer a direct chat with send_imessage, \
                passing chat_id as contact. Answer a group chat with send_to_chat, passing chat_id as chat_id. \
                user is the owner's name only when the text came from the owner's own number; otherwise it is the \
                sender's address or the group's id. One event may carry several texts joined by newlines.
                """,
            ])
        case "ping":
            respond(id, result: [:])
        case "tools/list", "tools/call":
            if method == "tools/call" {
                log("tool call", ["name": params["name"] as? String ?? "?"])
            }
            switch forward(method: method, params: params) {
            case .success(let reply):
                if let error = reply["error"] as? [String: Any] {
                    write(["jsonrpc": "2.0", "id": id, "error": error])
                } else {
                    respond(id, result: reply["result"] as? [String: Any] ?? [:])
                }
            case .failure(let failure):
                log("upstream failed", ["method": method, "error": failure.message])
                if method == "tools/call" {
                    // Report as a tool error so the model sees what went wrong and can say so.
                    respond(id, result: [
                        "content": [["type": "text", "text": "macos-mcp serve unreachable at \(config.mcpURL): \(failure.message)"]],
                        "isError": true,
                    ])
                } else {
                    write(["jsonrpc": "2.0", "id": id,
                           "error": ["code": -32603, "message": "macos-mcp serve unreachable: \(failure.message)"]])
                }
            }
        default:
            write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func respond(_ id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        stdoutLock.lock()
        FileHandle.standardOutput.write(data)
        stdoutLock.unlock()
    }

    // MARK: upstream (macos-mcp serve)

    private struct UpstreamFailure: Error { let message: String }

    /// Send one JSON-RPC request to the serve process and return its reply envelope.
    private func forward(method: String, params: [String: Any]) -> Result<[String: Any], UpstreamFailure> {
        guard let url = URL(string: config.mcpURL) else { return .failure(.init(message: "bad --mcp-url")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token = config.mcpToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ] as [String: Any])

        var outcome: Result<[String: Any], UpstreamFailure> = .failure(.init(message: "no reply"))
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error = error {
                outcome = .failure(.init(message: error.localizedDescription))
                return
            }
            guard let data = data, let reply = Channel.parseReply(data) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                outcome = .failure(.init(message: "unreadable reply (HTTP \(status))"))
                return
            }
            outcome = .success(reply)
        }.resume()
        done.wait()
        return outcome
    }

    /// The serve process answers as an SSE stream or as plain JSON; accept both.
    private static func parseReply(_ data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["result"] != nil || object["error"] != nil {
            return object
        }
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        var found: [String: Any]?
        for line in raw.split(whereSeparator: \.isNewline) where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let d = payload.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               object["result"] != nil || object["error"] != nil {
                found = object
            }
        }
        return found
    }

    // MARK: webhook listener

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(rawValue: config.port)!)

        guard let listener = try? NWListener(using: params) else {
            log("webhook listener could not be created, retrying", ["port": Int(config.port)])
            net.asyncAfter(deadline: .now() + 3) { self.startListener() }
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            connection.start(queue: self.net)
            self.receive(connection, buffer: Data())
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log("webhook listening", ["host": self.config.host, "port": Int(self.config.port)])
            case .failed(let error):
                // Usually the port is still held by a previous process. Keep trying:
                // a channel that cannot hear the poller is useless, so never settle.
                self.log("webhook listener failed, retrying", ["error": "\(error)"])
                listener.cancel()
                self.net.asyncAfter(deadline: .now() + 3) { self.startListener() }
            default:
                break
            }
        }
        listener.start(queue: net)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }

            switch ChannelHTTPRequest.parse(buffer) {
            case .request(let request):
                let (status, body) = self.handleWebhook(request)
                self.reply(connection, status: status, body: body)
            case .malformed:
                self.reply(connection, status: 400, body: "{\"error\":\"malformed request\"}")
            case .incomplete:
                if isComplete || error != nil || buffer.count > channelMaxBody + 65_536 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func reply(_ connection: NWConnection, status: Int, body: String) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleWebhook(_ request: ChannelHTTPRequest) -> (Int, String) {
        if request.method == "GET", request.path == "/health" {
            return (200, "{\"status\":\"ok\",\"server\":\"macos-mcp-channel\"}")
        }
        guard request.method == "POST", request.path == "/incoming" else {
            return (404, "{\"error\":\"not found\"}")
        }
        let expected = "sha256=" + channelHMAC(request.body, key: secret)
        guard let given = request.headers["x-hub-signature-256"], constantTimeEquals(given, expected) else {
            log("webhook rejected: bad signature")
            return (401, "{\"error\":\"bad signature\"}")
        }
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let text = json["text"] as? String,
              let from = json["from"] as? String else {
            log("webhook rejected: missing text or from")
            return (400, "{\"error\":\"text and from are required\"}")
        }

        // Meta values become attributes on the channel tag; they must be strings.
        // The poller sends chat.db's chat_identifier: a phone number or email for a
        // direct chat, "chat<digits>" for a group. The two need different reply tools.
        // (An address such as chat@example.com is a direct chat.)
        let chatID = json["chat_id"] as? String ?? from
        let isGroup = AccessConfig.isGroupIdentifier(chatID)
        // Only call the sender the owner when the text came from the owner's own number.
        var user = from
        if !isGroup, let name = config.ownerName, let phone = config.ownerPhone, samePhone(from, phone) {
            user = name
        }
        var meta: [String: String] = [
            "chat_id": chatID,
            "chat_type": isGroup ? "group" : "direct",
            "user": user,
            "event": json["event"] as? String ?? "message",
        ]
        if let count = json["message_count"] as? Int { meta["message_count"] = String(count) }
        if let rowids = json["rowids"] as? [Int], let last = rowids.max() { meta["rowid"] = String(last) }

        let delivered = emit([
            "jsonrpc": "2.0",
            "method": "notifications/claude/channel",
            "params": ["content": text, "meta": meta] as [String: Any],
        ])
        log(delivered ? "delivered to session" : "held until the session is ready",
            ["from": from, "chars": text.count, "rowid": meta["rowid"] ?? ""])
        return (200, "{\"received\":true}")
    }

    /// Write a channel event, or hold it if the client has not finished initializing.
    /// Returns false when held.
    private func emit(_ event: [String: Any]) -> Bool {
        eventLock.lock()
        defer { eventLock.unlock() }
        guard sessionReady else {
            heldEvents.append(event)
            return false
        }
        write(event)
        return true
    }

    private func sessionBecameReady() {
        eventLock.lock()
        let held = heldEvents
        heldEvents = []
        sessionReady = true
        for event in held { write(event) }
        eventLock.unlock()
        if !held.isEmpty { log("delivered to session", ["held": held.count]) }
    }

    // MARK: logging

    private func log(_ message: String, _ extra: [String: Any] = [:]) {
        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "component": "channel",
            "msg": message,
        ]
        for (key, value) in extra { entry[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        logLock.lock()
        defer { logLock.unlock() }
        fputs(line + "\n", stderr)
        guard let path = config.logFile else { return }
        let expanded = NSString(string: path).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: expanded) {
            FileManager.default.createFile(atPath: expanded, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: expanded) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }
}

// MARK: - Helpers

/// Largest webhook body accepted. A poller batch is a few texts; anything near this is not one.
private let channelMaxBody = 1_048_576

private enum ChannelHTTPParse {
    case incomplete
    case malformed
    case request(ChannelHTTPRequest)
}

/// Minimal HTTP/1.1 request parser for the webhook listener.
private struct ChannelHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// `.incomplete` until the headers and the declared body have arrived. This runs
    /// before the signature check, so it must not trap on anything a local process can send.
    static func parse(_ data: Data) -> ChannelHTTPParse {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[data.startIndex..<split.lowerBound], encoding: .utf8) else { return .malformed }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var length = 0
        if let declared = headers["content-length"] {
            guard let parsed = Int(declared), parsed >= 0, parsed <= channelMaxBody else { return .malformed }
            length = parsed
        }
        let body = data[split.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .request(ChannelHTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1].split(separator: "?").first ?? requestLine[1]),
            headers: headers,
            body: Data(body.prefix(length))))
    }
}

/// True when `handle` is the owner's phone number. An email handle is never the
/// owner's phone, whatever digits it contains.
private func samePhone(_ handle: String, _ ownerPhone: String) -> Bool {
    guard !handle.contains("@"), !ownerPhone.contains("@") else { return false }
    let a = AccessConfig.normalizePhone(handle), b = AccessConfig.normalizePhone(ownerPhone)
    return a.hasPrefix("+") && a == b
}

private func channelHMAC(_ data: Data, key: String) -> String {
    let keyData = Data(key.utf8)
    var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    keyData.withUnsafeBytes { keyBytes in
        data.withUnsafeBytes { dataBytes in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                   keyBytes.baseAddress, keyData.count,
                   dataBytes.baseAddress, data.count,
                   &mac)
        }
    }
    return mac.map { String(format: "%02x", $0) }.joined()
}

private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for index in 0..<x.count { diff |= x[index] ^ y[index] }
    return diff == 0
}
