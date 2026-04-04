import CommonCrypto
import Foundation
import Network

// MARK: - MCP Server

/// Lightweight MCP server (Streamable HTTP transport).
/// Runs an HTTP server that exposes macos-mcp CLI commands as MCP tools.
/// Each tool call shells out to this same binary.

private let mcpServerInfo: [String: Any] = [
    "name": "macos-mcp",
    "version": appVersion,
]

private let mcpTools: [[String: Any]] = [
    [
        "name": "send_imessage",
        "description": "Send an iMessage (or SMS fallback) to a contact phone number",
        "inputSchema": [
            "type": "object",
            "properties": [
                "contact": ["type": "string", "description": "Phone number like +13035551234"],
                "text": ["type": "string", "description": "Message text to send"],
            ],
            "required": ["contact", "text"],
        ] as [String: Any],
    ],
    [
        "name": "send_to_chat",
        "description": "Send a message to an iMessage group chat by chat ID",
        "inputSchema": [
            "type": "object",
            "properties": [
                "chat_id": ["type": "string"],
                "text": ["type": "string"],
            ],
            "required": ["chat_id", "text"],
        ] as [String: Any],
    ],
    [
        "name": "send_file",
        "description": "Send a file attachment via iMessage (image, PDF, etc.)",
        "inputSchema": [
            "type": "object",
            "properties": [
                "contact": ["type": "string", "description": "Phone number like +13035551234"],
                "file_path": ["type": "string", "description": "Absolute path to file on the Mac"],
            ],
            "required": ["contact", "file_path"],
        ] as [String: Any],
    ],
    [
        "name": "download_file",
        "description": "Download a file from a URL to the Mac. Returns the local path. Use with send_file to send images/files via iMessage.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "URL to download"],
                "filename": ["type": "string", "description": "Optional filename (auto-detected if omitted)"],
            ],
            "required": ["url"],
        ] as [String: Any],
    ],
    [
        "name": "vault_read",
        "description": "Read a file from the Obsidian vault (Obsidian Vault). Path is relative to vault root.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Relative path like Personal/VOICE.md"],
            ],
            "required": ["path"],
        ] as [String: Any],
    ],
    [
        "name": "vault_write",
        "description": "Write or update a file in the Obsidian vault (Obsidian Vault). Path is relative to vault root.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Relative path like Work/notes.md"],
                "content": ["type": "string", "description": "File content to write"],
            ],
            "required": ["path", "content"],
        ] as [String: Any],
    ],
    [
        "name": "vault_list",
        "description": "List files and folders in the Obsidian vault. Path is relative to vault root.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Relative path (empty for root)"],
            ],
        ] as [String: Any],
    ],
    [
        "name": "vault_search",
        "description": "Search for files in the Obsidian vault by name or content.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Search term"],
                "content_search": ["type": "boolean", "description": "Search inside file contents (default: filename only)"],
            ],
            "required": ["query"],
        ] as [String: Any],
    ],
    [
        "name": "check_messages",
        "description": "Check for new iMessages. Use after_rowid for efficient polling.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "phone": ["type": "string", "description": "Filter by phone number"],
                "after_rowid": ["type": "integer", "description": "Only return messages after this ROWID"],
            ],
        ] as [String: Any],
    ],
    [
        "name": "read_conversation",
        "description": "Read recent messages from a conversation",
        "inputSchema": [
            "type": "object",
            "properties": [
                "phone": ["type": "string"],
                "limit": ["type": "integer", "default": 20],
            ],
        ] as [String: Any],
    ],
    [
        "name": "list_conversations",
        "description": "List recent iMessage conversations",
        "inputSchema": [
            "type": "object",
            "properties": [
                "limit": ["type": "integer", "default": 10],
            ],
        ] as [String: Any],
    ],
    [
        "name": "max_rowid",
        "description": "Get current max message ROWID for polling watermark",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any]] as [String: Any],
    ],
    [
        "name": "typing_indicator",
        "description": "Control iMessage typing indicator (start/stop/keepalive)",
        "inputSchema": [
            "type": "object",
            "properties": [
                "contact": ["type": "string"],
                "action": ["type": "string", "enum": ["start", "stop", "keepalive"]],
            ],
            "required": ["contact", "action"],
        ] as [String: Any],
    ],
    [
        "name": "calendar_list",
        "description": "List all visible calendars",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any]] as [String: Any],
    ],
    [
        "name": "calendar_upcoming",
        "description": "Get upcoming calendar events",
        "inputSchema": [
            "type": "object",
            "properties": [
                "hours": ["type": "integer", "default": 24],
                "calendar_id": ["type": "string"],
            ],
        ] as [String: Any],
    ],
    [
        "name": "calendar_events",
        "description": "Get calendar events in a date range (ISO 8601)",
        "inputSchema": [
            "type": "object",
            "properties": [
                "from_date": ["type": "string"],
                "to_date": ["type": "string"],
                "calendar_id": ["type": "string"],
            ],
            "required": ["from_date", "to_date"],
        ] as [String: Any],
    ],
    [
        "name": "calendar_search",
        "description": "Search calendar events by title/notes/location",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string"],
                "days": ["type": "integer", "default": 30],
                "calendar_id": ["type": "string"],
            ],
            "required": ["query"],
        ] as [String: Any],
    ],
    [
        "name": "calendar_create",
        "description": "Create a calendar event",
        "inputSchema": [
            "type": "object",
            "properties": [
                "calendar_id": ["type": "string"],
                "title": ["type": "string"],
                "start": ["type": "string"],
                "end": ["type": "string"],
                "notes": ["type": "string"],
                "location": ["type": "string"],
                "all_day": ["type": "boolean", "default": false],
            ],
            "required": ["calendar_id", "title", "start", "end"],
        ] as [String: Any],
    ],
]

// MARK: - Tool Dispatch

/// Build CLI args for a tool call, execute self, return JSON string.
private func dispatchTool(_ name: String, _ input: [String: Any]) -> String {
    let binary = ProcessInfo.processInfo.arguments[0]
    var args: [String] = []

    switch name {
    case "send_imessage":
        args = ["send", "message", input["contact"] as? String ?? "", input["text"] as? String ?? ""]
    case "send_to_chat":
        args = ["send", "chat", input["chat_id"] as? String ?? "", input["text"] as? String ?? ""]
    case "send_file":
        args = ["send", "file", input["contact"] as? String ?? "", input["file_path"] as? String ?? ""]
    case "download_file":
        return downloadFile(input["url"] as? String ?? "", filename: input["filename"] as? String)
    case "vault_read":
        return vaultRead(input["path"] as? String ?? "")
    case "vault_write":
        return vaultWrite(input["path"] as? String ?? "", content: input["content"] as? String ?? "")
    case "vault_list":
        return vaultList(input["path"] as? String ?? "")
    case "vault_search":
        return vaultSearch(input["query"] as? String ?? "", contentSearch: input["content_search"] as? Bool ?? false)
    case "check_messages":
        args = ["messages", "check"]
        if let phone = input["phone"] as? String, !phone.isEmpty { args += ["--phone", phone] }
        if let rowid = input["after_rowid"] as? Int { args += ["--after-rowid", String(rowid)] }
        if let rowid = input["after_rowid"] as? Double { args += ["--after-rowid", String(Int(rowid))] }
    case "read_conversation":
        args = ["messages", "read"]
        if let phone = input["phone"] as? String, !phone.isEmpty { args += ["--phone", phone] }
        let limit = (input["limit"] as? Int) ?? (input["limit"] as? Double).map { Int($0) } ?? 20
        args += ["--limit", String(limit)]
    case "list_conversations":
        let limit = (input["limit"] as? Int) ?? (input["limit"] as? Double).map { Int($0) } ?? 10
        args = ["messages", "list-conversations", "--limit", String(limit)]
    case "max_rowid":
        args = ["messages", "max-rowid"]
    case "typing_indicator":
        args = ["typing", input["contact"] as? String ?? "", input["action"] as? String ?? ""]
    case "calendar_list":
        args = ["calendar", "list"]
    case "calendar_upcoming":
        let hours = (input["hours"] as? Int) ?? (input["hours"] as? Double).map { Int($0) } ?? 24
        args = ["calendar", "upcoming", "--hours", String(hours)]
        if let cal = input["calendar_id"] as? String, !cal.isEmpty { args += ["--cal", cal] }
    case "calendar_events":
        args = ["calendar", "events", "--from", input["from_date"] as? String ?? "", "--to", input["to_date"] as? String ?? ""]
        if let cal = input["calendar_id"] as? String, !cal.isEmpty { args += ["--cal", cal] }
    case "calendar_search":
        args = ["calendar", "search", input["query"] as? String ?? ""]
        let days = (input["days"] as? Int) ?? (input["days"] as? Double).map { Int($0) } ?? 30
        args += ["--days", String(days)]
        if let cal = input["calendar_id"] as? String, !cal.isEmpty { args += ["--cal", cal] }
    case "calendar_create":
        args = ["calendar", "create",
                "--cal", input["calendar_id"] as? String ?? "",
                "--title", input["title"] as? String ?? "",
                "--start", input["start"] as? String ?? "",
                "--end", input["end"] as? String ?? ""]
        if let notes = input["notes"] as? String, !notes.isEmpty { args += ["--notes", notes] }
        if let loc = input["location"] as? String, !loc.isEmpty { args += ["--location", loc] }
        if input["all_day"] as? Bool == true { args += ["--all-day"] }
    default:
        return "{\"error\": \"Unknown tool: \(name)\"}"
    }

    let result = runProcess(binary, arguments: args)
    let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.exitCode != 0 {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? (output.isEmpty ? "{\"error\": \"exit code \(result.exitCode)\"}" : output) : err
    }
    return output.isEmpty ? "{\"ok\": true}" : output
}

// MARK: - Download Helper

/// Download a URL to a temp file on the Mac, return JSON with the local path.
private func downloadFile(_ urlString: String, filename: String?) -> String {
    guard let url = URL(string: urlString) else {
        return "{\"error\": \"Invalid URL\"}"
    }

    let downloadDir = NSHomeDirectory() + "/tmp/imessage/downloads"
    try? FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)

    // Determine filename
    let name: String
    if let f = filename, !f.isEmpty {
        name = f
    } else {
        // Use last path component or generate one
        let lastComponent = url.lastPathComponent
        if lastComponent.count > 1 && lastComponent.contains(".") {
            name = lastComponent
        } else {
            name = "download-\(UUID().uuidString.prefix(8))"
        }
    }

    let destPath = (downloadDir as NSString).appendingPathComponent(name)

    let sem = DispatchSemaphore(value: 0)
    var resultJSON = "{\"error\": \"Download failed\"}"

    let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
        if let error = error {
            resultJSON = "{\"error\": \"\(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))\"}"
            sem.signal()
            return
        }
        guard let tempURL = tempURL else {
            sem.signal()
            return
        }

        // Move to destination
        try? FileManager.default.removeItem(atPath: destPath)
        do {
            try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: destPath))
            let size = (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? Int) ?? 0
            resultJSON = "{\"path\": \"\(destPath)\", \"size\": \(size)}"
        } catch {
            resultJSON = "{\"error\": \"Failed to save: \(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))\"}"
        }
        sem.signal()
    }
    task.resume()

    // Wait up to 60 seconds
    if sem.wait(timeout: .now() + 60) == .timedOut {
        task.cancel()
        return "{\"error\": \"Download timed out\"}"
    }

    return resultJSON
}

// MARK: - Vault Helpers

private let vaultRoot = (ProcessInfo.processInfo.environment["OBSIDIAN_VAULT_PATH"]
    ?? NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Obsidian Vault")

private func vaultRead(_ path: String) -> String {
    let fullPath = (vaultRoot as NSString).appendingPathComponent(path)
    guard FileManager.default.fileExists(atPath: fullPath) else {
        return "{\"error\": \"File not found: \(path)\"}"
    }
    guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
        return "{\"error\": \"Could not read file: \(path)\"}"
    }
    let escaped = content.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "{\"path\": \"\(path)\", \"content\": \"\(escaped)\"}"
}

private func vaultWrite(_ path: String, content: String) -> String {
    let fullPath = (vaultRoot as NSString).appendingPathComponent(path)
    let dir = (fullPath as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
        return "{\"ok\": true, \"path\": \"\(path)\"}"
    } catch {
        return "{\"error\": \"Write failed: \(error.localizedDescription)\"}"
    }
}

private func vaultList(_ path: String) -> String {
    let fullPath = path.isEmpty ? vaultRoot : (vaultRoot as NSString).appendingPathComponent(path)
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: fullPath) else {
        return "{\"error\": \"Could not list: \(path)\"}"
    }
    let entries = items.filter { !$0.hasPrefix(".") }.sorted().map { name -> [String: Any] in
        let itemPath = (fullPath as NSString).appendingPathComponent(name)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir)
        return ["name": name, "type": isDir.boolValue ? "directory" : "file"]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: ["path": path, "entries": entries]),
          let json = String(data: data, encoding: .utf8) else {
        return "{\"error\": \"Serialization failed\"}"
    }
    return json
}

private func vaultSearch(_ query: String, contentSearch: Bool) -> String {
    let fm = FileManager.default
    var results: [[String: String]] = []
    let enumerator = fm.enumerator(atPath: vaultRoot)

    while let file = enumerator?.nextObject() as? String {
        guard file.hasSuffix(".md"), !file.contains("/.") else { continue }

        if contentSearch {
            let fullPath = (vaultRoot as NSString).appendingPathComponent(file)
            if let content = try? String(contentsOfFile: fullPath, encoding: .utf8),
               content.localizedCaseInsensitiveContains(query) {
                results.append(["path": file, "match": "content"])
            }
        } else {
            if file.localizedCaseInsensitiveContains(query) {
                results.append(["path": file, "match": "filename"])
            }
        }

        if results.count >= 50 { break }
    }

    guard let data = try? JSONSerialization.data(withJSONObject: ["query": query, "results": results]),
          let json = String(data: data, encoding: .utf8) else {
        return "{\"error\": \"Serialization failed\"}"
    }
    return json
}

// MARK: - JSON-RPC Helpers

private func jsonRpcResult(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
    return ["jsonrpc": "2.0", "id": id as Any, "result": result]
}

private func jsonRpcError(_ id: Any?, code: Int, message: String) -> [String: Any] {
    return ["jsonrpc": "2.0", "id": id as Any, "error": ["code": code, "message": message]]
}

private func sseEvent(_ data: [String: Any]) -> Data {
    guard let json = try? JSONSerialization.data(withJSONObject: data),
          let jsonStr = String(data: json, encoding: .utf8) else {
        return Data()
    }
    return "event: message\ndata: \(jsonStr)\n\n".data(using: .utf8)!
}

// MARK: - HTTP Request Parsing

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
    guard let str = String(data: data, encoding: .utf8) else { return nil }

    // Split headers from body
    let parts = str.components(separatedBy: "\r\n\r\n")
    guard !parts.isEmpty else { return nil }

    let headerSection = parts[0]
    let bodyStr = parts.count > 1 ? parts[1...].joined(separator: "\r\n\r\n") : ""

    let lines = headerSection.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }

    let requestParts = requestLine.split(separator: " ", maxSplits: 2)
    guard requestParts.count >= 2 else { return nil }

    let method = String(requestParts[0])
    let path = String(requestParts[1])

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        if let colonIdx = line.firstIndex(of: ":") {
            let key = line[line.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
    }

    return HTTPRequest(method: method, path: path, headers: headers, body: bodyStr.data(using: .utf8) ?? Data())
}

// MARK: - HTTP Response Building

private func httpResponse(status: Int, statusText: String, headers: [String: String], body: Data) -> Data {
    var resp = "HTTP/1.1 \(status) \(statusText)\r\n"
    for (key, value) in headers {
        resp += "\(key): \(value)\r\n"
    }
    resp += "Content-Length: \(body.count)\r\n"
    resp += "\r\n"
    var data = resp.data(using: .utf8)!
    data.append(body)
    return data
}

private func jsonResponse(status: Int = 200, _ obj: Any) -> Data {
    let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    return httpResponse(
        status: status,
        statusText: status == 200 ? "OK" : "Error",
        headers: [
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type, Accept, Mcp-Session-Id",
            "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
            "Access-Control-Expose-Headers": "Mcp-Session-Id",
        ],
        body: body
    )
}

private func sseResponse(sessionId: String, events: [Data]) -> Data {
    var body = Data()
    for event in events {
        body.append(event)
    }

    var resp = "HTTP/1.1 200 OK\r\n"
    resp += "Content-Type: text/event-stream\r\n"
    resp += "Cache-Control: no-cache\r\n"
    resp += "Connection: close\r\n"
    resp += "Mcp-Session-Id: \(sessionId)\r\n"
    resp += "Access-Control-Allow-Origin: *\r\n"
    resp += "Access-Control-Allow-Headers: Content-Type, Accept, Mcp-Session-Id\r\n"
    resp += "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n"
    resp += "Access-Control-Expose-Headers: Mcp-Session-Id\r\n"
    resp += "\r\n"
    var data = resp.data(using: .utf8)!
    data.append(body)
    return data
}

// MARK: - MCP Request Handler

private var sessions = Set<String>()

private func handleMCPRequest(_ request: HTTPRequest) -> Data {
    // CORS preflight
    if request.method == "OPTIONS" {
        return httpResponse(status: 204, statusText: "No Content", headers: [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type, Accept, Mcp-Session-Id",
            "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
            "Access-Control-Expose-Headers": "Mcp-Session-Id",
        ], body: Data())
    }

    // Only POST is used for Streamable HTTP
    guard request.method == "POST" else {
        return jsonResponse(status: 405, jsonRpcError(nil, code: -32000, message: "Method not allowed"))
    }

    // Check Accept header
    let accept = request.headers["accept"] ?? ""
    guard accept.contains("text/event-stream") else {
        return jsonResponse(status: 406, ["jsonrpc": "2.0", "error": [
            "code": -32000,
            "message": "Not Acceptable: Client must accept both application/json and text/event-stream",
        ], "id": NSNull()])
    }

    // Parse JSON-RPC
    guard let jsonObj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
        return jsonResponse(status: 400, jsonRpcError(nil, code: -32700, message: "Parse error"))
    }

    let method = jsonObj["method"] as? String ?? ""
    let id = jsonObj["id"]
    let params = jsonObj["params"] as? [String: Any] ?? [:]
    let sessionId = request.headers["mcp-session-id"] ?? UUID().uuidString

    switch method {
    case "initialize":
        sessions.insert(sessionId)
        let result = jsonRpcResult(id, [
            "protocolVersion": "2025-11-25",
            "capabilities": ["tools": ["listChanged": true]],
            "serverInfo": mcpServerInfo,
        ])
        return sseResponse(sessionId: sessionId, events: [sseEvent(result)])

    case "notifications/initialized":
        // No response needed for notifications
        return httpResponse(status: 200, statusText: "OK", headers: [
            "Content-Type": "text/event-stream",
            "Mcp-Session-Id": sessionId,
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Expose-Headers": "Mcp-Session-Id",
        ], body: Data())

    case "tools/list":
        let result = jsonRpcResult(id, ["tools": mcpTools])
        return sseResponse(sessionId: sessionId, events: [sseEvent(result)])

    case "tools/call":
        let toolName = params["name"] as? String ?? ""
        let toolArgs = params["arguments"] as? [String: Any] ?? [:]

        fputs("[\(ISO8601DateFormatter().string(from: Date()))] Tool call: \(toolName)\n", stderr)
        let output = dispatchTool(toolName, toolArgs)

        let result = jsonRpcResult(id, [
            "content": [["type": "text", "text": output]],
        ])
        return sseResponse(sessionId: sessionId, events: [sseEvent(result)])

    case "ping":
        let result = jsonRpcResult(id, [:])
        return sseResponse(sessionId: sessionId, events: [sseEvent(result)])

    default:
        let result = jsonRpcError(id, code: -32601, message: "Method not found: \(method)")
        return sseResponse(sessionId: sessionId, events: [sseEvent(result)])
    }
}

// MARK: - TCP Server

func runServe(args: [String]) {
    var port: UInt16 = 9200
    var host = "0.0.0.0"
    var webhookURL: String? = nil
    var webhookSecret: String? = nil
    var phone: String = ""
    var pollInterval: TimeInterval = 1.0
    var debounceWindow: TimeInterval = 3.0
    var watermarkPath = NSHomeDirectory() + "/tmp/imessage/watermark"

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--port":
            i += 1
            guard i < args.count, let p = UInt16(args[i]) else {
                fputs("--port requires a number\n", stderr)
                exit(1)
            }
            port = p
        case "--host":
            i += 1
            guard i < args.count else {
                fputs("--host requires a value\n", stderr)
                exit(1)
            }
            host = args[i]
        case "--webhook-url":
            i += 1; guard i < args.count else { fputs("--webhook-url requires a value\n", stderr); exit(1) }
            webhookURL = args[i]
        case "--webhook-secret":
            i += 1; guard i < args.count else { fputs("--webhook-secret requires a value\n", stderr); exit(1) }
            webhookSecret = args[i]
        case "--phone":
            i += 1; guard i < args.count else { fputs("--phone requires a value\n", stderr); exit(1) }
            phone = args[i]
        case "--poll-interval":
            i += 1; guard i < args.count, let v = TimeInterval(args[i]) else { fputs("--poll-interval requires a number\n", stderr); exit(1) }
            pollInterval = v
        case "--debounce":
            i += 1; guard i < args.count, let v = TimeInterval(args[i]) else { fputs("--debounce requires a number\n", stderr); exit(1) }
            debounceWindow = v
        case "--watermark-file":
            i += 1; guard i < args.count else { fputs("--watermark-file requires a value\n", stderr); exit(1) }
            watermarkPath = args[i]
        default:
            break
        }
        i += 1
    }

    // Start poller if webhook is configured
    if let url = webhookURL, let secret = webhookSecret {
        startPoller(
            webhookURL: url, webhookSecret: secret, phone: phone,
            pollInterval: pollInterval, debounceWindow: debounceWindow,
            watermarkPath: watermarkPath
        )
    }

    let serverQueue = DispatchQueue(label: "mcp-server", attributes: .concurrent)

    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    // Disable Nagle for low-latency responses


    let listener = try! NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

    listener.newConnectionHandler = { connection in
        connection.start(queue: serverQueue)

        // Read full request (accumulate until we have headers + body)
        func readRequest() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, isComplete, error in
                guard let data = data, !data.isEmpty else {
                    connection.cancel()
                    return
                }

                // Check if we have a complete HTTP request
                guard let request = parseHTTPRequest(data) else {
                    // Might need more data — try reading more
                    connection.cancel()
                    return
                }

                // Check content-length and read more body if needed
                if let clStr = request.headers["content-length"],
                   let contentLength = Int(clStr),
                   request.body.count < contentLength {
                    // Need to read more body data
                    let remaining = contentLength - request.body.count
                    connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { moreData, _, _, _ in
                        var fullBody = request.body
                        if let moreData = moreData {
                            fullBody.append(moreData)
                        }
                        let fullRequest = HTTPRequest(method: request.method, path: request.path, headers: request.headers, body: fullBody)
                        let response = handleRequest(fullRequest)
                        sendAndClose(connection, response)
                    }
                    return
                }

                let response = handleRequest(request)
                sendAndClose(connection, response)
            }
        }

        readRequest()
    }

    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            fputs("macos-mcp MCP server listening on \(host):\(port)\n", stderr)
            fputs("Streamable HTTP: http://\(host):\(port)/mcp\n", stderr)
        case .failed(let error):
            fputs("Server failed: \(error)\n", stderr)
            exit(1)
        default:
            break
        }
    }

    listener.start(queue: serverQueue)

    // Keep the process alive
    dispatchMain()
}

private func handleRequest(_ request: HTTPRequest) -> Data {
    switch request.path.split(separator: "?").first.map(String.init) ?? request.path {
    case "/health":
        return jsonResponse(status: 200, ["status": "ok", "server": "macos-mcp"])
    case "/mcp":
        return handleMCPRequest(request)
    default:
        return jsonResponse(status: 404, ["error": "Not found"])
    }
}

private func sendAndClose(_ connection: NWConnection, _ data: Data) {
    connection.send(content: data, completion: .contentProcessed { _ in
        connection.cancel()
    })
}

// MARK: - iMessage Poller

/// Polls chat.db for new messages and POSTs them to the hermes webhook.
private func startPoller(
    webhookURL: String, webhookSecret: String, phone: String,
    pollInterval: TimeInterval, debounceWindow: TimeInterval,
    watermarkPath: String
) {
    let binary = ProcessInfo.processInfo.arguments[0]
    let pollerQueue = DispatchQueue(label: "imessage-poller")

    pollerQueue.async {
        var watermark = loadWatermark(watermarkPath)

        // Initialize watermark if needed
        if watermark == 0 {
            let result = runProcess(binary, arguments: ["messages", "max-rowid"])
            if let data = result.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let maxRowid = json["max_rowid"] as? Int {
                watermark = maxRowid
                saveWatermark(watermarkPath, watermark)
            }
        }

        fputs("Poller started (watermark: \(watermark), phone: \(phone.isEmpty ? "all" : phone))\n", stderr)
        fputs("Webhook: \(webhookURL)\n", stderr)

        var pending: [(text: String, thread: String, rowid: Int)] = []
        var lastMessageTime: Date = .distantPast

        while true {
            Thread.sleep(forTimeInterval: pollInterval)

            // Poll for new messages
            var checkArgs = ["messages", "check", "--after-rowid", String(watermark)]
            if !phone.isEmpty { checkArgs += ["--phone", phone] }

            let result = runProcess(binary, arguments: checkArgs)
            guard let data = result.stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = json["messages"] as? [[String: Any]] else {
                // Flush if debounce expired
                if !pending.isEmpty && Date().timeIntervalSince(lastMessageTime) >= debounceWindow {
                    flushToWebhook(pending, webhookURL: webhookURL, webhookSecret: webhookSecret)
                    pending.removeAll()
                }
                continue
            }

            for msg in messages {
                let rowid = msg["rowid"] as? Int ?? 0
                if rowid > watermark {
                    watermark = rowid
                    saveWatermark(watermarkPath, watermark)
                }

                // Skip outbound
                if msg["is_from_me"] as? Bool == true || msg["is_from_me"] as? Int == 1 {
                    continue
                }

                let text = msg["text"] as? String ?? ""
                let thread = msg["chat"] as? String ?? msg["from"] as? String ?? "unknown"
                if text.isEmpty { continue }

                fputs("New message (rowid: \(rowid), thread: \(thread)): \(String(text.prefix(80)))\n", stderr)
                pending.append((text: text, thread: thread, rowid: rowid))
                lastMessageTime = Date()
            }

            // Flush if debounce expired
            if !pending.isEmpty && Date().timeIntervalSince(lastMessageTime) >= debounceWindow {
                flushToWebhook(pending, webhookURL: webhookURL, webhookSecret: webhookSecret)
                pending.removeAll()
            }
        }
    }
}

private func loadWatermark(_ path: String) -> Int {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
    return Int(contents.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

private func saveWatermark(_ path: String, _ value: Int) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? String(value).write(toFile: path, atomically: true, encoding: .utf8)
}

private func flushToWebhook(
    _ messages: [(text: String, thread: String, rowid: Int)],
    webhookURL: String, webhookSecret: String
) {
    let binary = ProcessInfo.processInfo.arguments[0]

    // Group by thread
    var threads: [String: [(text: String, rowid: Int)]] = [:]
    for msg in messages {
        threads[msg.thread, default: []].append((text: msg.text, rowid: msg.rowid))
    }

    for (thread, msgs) in threads {
        let combinedText = msgs.map(\.text).joined(separator: "\n")
        let maxRowid = msgs.map(\.rowid).max() ?? 0
        let payload: [String: Any] = [
            "event": "imessage",
            "from": thread,
            "text": combinedText,
            "message_count": msgs.count,
            "rowids": msgs.map(\.rowid),
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { continue }

        let signature = hmacSHA256(body, key: webhookSecret)

        // Extract contact number for typing indicator (strip + prefix for AppleScript)
        let contact = thread.hasPrefix("+") ? String(thread.dropFirst()) : thread

        // Run ALL typing indicator work in background — never block the poller
        DispatchQueue.global().async {
            fputs("Starting typing indicator for \(thread)\n", stderr)
            runProcess(binary, arguments: ["typing", contact, "start"], timeout: 10)

            let keepaliveInterval: TimeInterval = 25
            let maxWait: TimeInterval = 300
            let startTime = Date()
            let baseRowid = maxRowid

            while Date().timeIntervalSince(startTime) < maxWait {
                Thread.sleep(forTimeInterval: keepaliveInterval)

                // Check if an outbound message appeared (hermes replied)
                let result = runProcess(binary, arguments: ["messages", "max-rowid"])
                if let data = result.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let currentMax = json["max_rowid"] as? Int,
                   currentMax > baseRowid {
                    fputs("Outbound message detected, stopping typing indicator\n", stderr)
                    break
                }

                runProcess(binary, arguments: ["typing", contact, "keepalive"], timeout: 10)
            }

            runProcess(binary, arguments: ["typing", contact, "stop"], timeout: 10)
        }

        fputs("Flushing \(msgs.count) message(s) from \(thread) to webhook\n", stderr)

        guard let url = URL(string: webhookURL) else { continue }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sha256=\(signature)", forHTTPHeaderField: "X-Hub-Signature-256")
        request.httpBody = body

        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                fputs("Webhook error: \(error.localizedDescription)\n", stderr)
            } else if let httpResp = response as? HTTPURLResponse {
                let respBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                fputs("Webhook response: \(httpResp.statusCode) \(String(respBody.prefix(200)))\n", stderr)
            }
            sem.signal()
        }
        task.resume()
        sem.wait()

        // Don't block the poller — typing watcher runs independently
        // It will stop itself when it detects the reply or times out
    }
}

private func hmacSHA256(_ data: Data, key: String) -> String {
    let keyData = key.data(using: .utf8)!
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
