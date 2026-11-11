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
}

// MARK: - Entry

func runChannel(args: [String]) -> Never {
    var config = ChannelConfig()
    let env = ProcessInfo.processInfo.environment
    config.secret = env["MACOS_MCP_WEBHOOK_SECRET"]
    config.ownerName = env["MACOS_MCP_OWNER_NAME"]
    var secretFile = env["MACOS_MCP_WEBHOOK_SECRET_FILE"]

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
                iMessage texts arrive as <channel source="\(channelServerName)" chat_id="..." user="...">. \
                The sender only sees iMessage, never this session's output: answer with the send_imessage tool, \
                passing the chat_id value as contact. One event may carry several texts joined by newlines.
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

            if let request = ChannelHTTPRequest(buffer) {
                let (status, body) = self.handleWebhook(request)
                self.reply(connection, status: status, body: body)
                return
            }
            if isComplete || error != nil || buffer.count > 4_194_304 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
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
        var meta: [String: String] = [
            "chat_id": json["chat_id"] as? String ?? from,
            "user": config.ownerName ?? from,
            "event": json["event"] as? String ?? "message",
        ]
        if let count = json["message_count"] as? Int { meta["message_count"] = String(count) }
        if let rowids = json["rowids"] as? [Int], let last = rowids.max() { meta["rowid"] = String(last) }

        write([
            "jsonrpc": "2.0",
            "method": "notifications/claude/channel",
            "params": ["content": text, "meta": meta] as [String: Any],
        ])
        log("delivered to session", ["from": from, "chars": text.count, "rowid": meta["rowid"] ?? ""])
        return (200, "{\"received\":true}")
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

/// Minimal HTTP/1.1 request parser. Returns nil until headers and the full body have arrived.
private struct ChannelHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = data[split.upperBound...]
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard body.count >= length else { return nil }
        self.method = String(requestLine[0])
        self.path = String(requestLine[1].split(separator: "?").first ?? requestLine[1])
        self.headers = headers
        self.body = Data(body.prefix(length))
    }
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
