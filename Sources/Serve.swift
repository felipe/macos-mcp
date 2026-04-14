import CommonCrypto
import Foundation
import Network

// MARK: - Structured Logging

private enum LogLevel: String {
    case info = "info"
    case warn = "warn"
    case error = "error"
}

private enum LogComponent: String {
    case mcp = "mcp"
    case poller = "poller"
    case typing = "typing"
    case webhook = "webhook"
    case vault = "vault"
    case server = "server"
}

/// Log file handle — set via MACOS_MCP_LOG_FILE env var.
/// When set, structured logs go to the file AND stderr.
private let logFileHandle: FileHandle? = {
    guard let path = ProcessInfo.processInfo.environment["MACOS_MCP_LOG_FILE"] else { return nil }
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    return FileHandle(forWritingAtPath: path)
}()

private func log(_ level: LogLevel, _ component: LogComponent, _ message: String, extra: [String: Any]? = nil) {
    let ts = ISO8601DateFormatter().string(from: Date())
    var entry: [String: Any] = [
        "ts": ts,
        "level": level.rawValue,
        "component": component.rawValue,
        "msg": message,
    ]
    if let extra = extra {
        for (k, v) in extra { entry[k] = v }
    }
    if let data = try? JSONSerialization.data(withJSONObject: entry, options: []),
       let json = String(data: data, encoding: .utf8) {
        let line = json + "\n"
        fputs(line, stderr)
        if let fh = logFileHandle, let lineData = line.data(using: .utf8) {
            fh.seekToEndOfFile()
            fh.write(lineData)
        }
    } else {
        let line = "[\(ts)] [\(level.rawValue)] [\(component.rawValue)] \(message)\n"
        fputs(line, stderr)
        if let fh = logFileHandle, let lineData = line.data(using: .utf8) {
            fh.seekToEndOfFile()
            fh.write(lineData)
        }
    }
}

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
        "name": "reply",
        "description": "Reply to an iMessage conversation. Use the chat_id from the channel notification.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "chat_id": ["type": "string", "description": "Chat GUID from the channel notification meta"],
                "text": ["type": "string", "description": "Message text to send"],
                "files": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Absolute file paths to attach. Sent as separate messages after the text.",
                ] as [String: Any],
            ],
            "required": ["chat_id", "text"],
        ] as [String: Any],
    ],
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
        "description": "Read a file from the Obsidian vault (the Obsidian vault). Path is relative to vault root.",
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
        "description": "Write or update a file in the Obsidian vault (the Obsidian vault). Path is relative to vault root.",
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
    case "reply":
        let chatId = input["chat_id"] as? String ?? ""
        let text = input["text"] as? String ?? ""
        let textResult = runProcess(binary, arguments: ["send", "chat", chatId, text])
        if textResult.exitCode != 0 {
            let err = textResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            log(.error, .mcp, "Reply failed", extra: ["chat": chatId, "error": err])
            return err.isEmpty ? "{\"error\": \"Failed to send reply\"}" : err
        }
        var fileSent = 0
        if let files = input["files"] as? [String] {
            for file in files {
                let fileResult = runProcess(binary, arguments: ["send", "file-to-chat", chatId, file])
                if fileResult.exitCode == 0 {
                    fileSent += 1
                } else {
                    log(.error, .mcp, "File send failed", extra: ["file": file])
                }
            }
        }
        return fileSent > 0 ? "{\"sent\": true, \"parts\": \(1 + fileSent)}" : "{\"sent\": true}"
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
    // Message tools run in-process to avoid TCC/FDA issues with subprocesses
    case "check_messages":
        let conn = ChatDBConnection()
        defer { conn.close() }
        let phone = input["phone"] as? String
        let afterRowid: Int64
        if let r = input["after_rowid"] as? Int { afterRowid = Int64(r) }
        else if let r = input["after_rowid"] as? Double { afterRowid = Int64(r) }
        else { afterRowid = max(0, conn.maxRowid() - 50) }
        let msgs = conn.checkMessages(afterRowid: afterRowid, phone: phone)
        let result: [[String: Any]] = msgs.map { msg in
            var m: [String: Any] = [
                "rowid": NSNumber(value: msg.rowid), "guid": msg.guid,
                "date": msg.date, "text": msg.text,
                "from": msg.from, "chat": msg.chatGuid.isEmpty ? msg.chat : msg.chatGuid,
            ]
            if msg.hasAttachments, let img = conn.fetchFirstImagePath(messageRowid: msg.rowid) {
                m["image_path"] = img
            }
            return m
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["messages": result], options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else { return "{\"messages\":[]}" }
        return json
    case "read_conversation":
        let conn = ChatDBConnection()
        defer { conn.close() }
        let phone = input["phone"] as? String
        let limit = (input["limit"] as? Int) ?? (input["limit"] as? Double).map { Int($0) } ?? 20
        let msgs = conn.readConversation(phone: phone, limit: limit)
        guard let data = try? JSONSerialization.data(withJSONObject: ["messages": msgs], options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else { return "{\"messages\":[]}" }
        return json
    case "list_conversations":
        let conn = ChatDBConnection()
        defer { conn.close() }
        let limit = (input["limit"] as? Int) ?? (input["limit"] as? Double).map { Int($0) } ?? 10
        let convos = conn.listConversations(limit: limit)
        guard let data = try? JSONSerialization.data(withJSONObject: ["conversations": convos], options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else { return "{\"conversations\":[]}" }
        return json
    case "max_rowid":
        let conn = ChatDBConnection()
        defer { conn.close() }
        return "{\"max_rowid\": \(conn.maxRowid())}"
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
        let errorMsg = err.isEmpty ? (output.isEmpty ? "exit code \(result.exitCode)" : output) : err
        log(.error, .mcp, "Tool failed", extra: ["tool": name, "exit_code": result.exitCode, "error": errorMsg])
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

    // SSRF protection: only allow http/https
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
        return "{\"error\": \"Only http/https URLs are allowed\"}"
    }

    let downloadDir = NSHomeDirectory() + "/tmp/imessage/downloads"
    try? FileManager.default.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)

    // Determine filename — strip any path components to prevent traversal
    let rawName: String
    if let f = filename, !f.isEmpty {
        rawName = (f as NSString).lastPathComponent  // strip directory components
    } else {
        let lastComponent = url.lastPathComponent
        if lastComponent.count > 1 && lastComponent.contains(".") {
            rawName = lastComponent
        } else {
            rawName = "download-\(UUID().uuidString.prefix(8))"
        }
    }
    // Extra safety: reject any remaining traversal
    let name = rawName.replacingOccurrences(of: "..", with: "_")

    guard let destPath = safePath(root: downloadDir, relative: name) else {
        return "{\"error\": \"Invalid filename\"}"
    }

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

// MARK: - Path Safety

/// Resolve a relative path against a root and verify it doesn't escape.
/// Returns nil if the path escapes the root (path traversal).
private func safePath(root: String, relative: String) -> String? {
    let full = (root as NSString).appendingPathComponent(relative)
    let resolved = URL(fileURLWithPath: full).standardized.path
    let resolvedRoot = URL(fileURLWithPath: root).standardized.path
    guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
        return nil
    }
    return resolved
}

// MARK: - Vault Helpers

private let vaultRoot = (ProcessInfo.processInfo.environment["OBSIDIAN_VAULT_PATH"]
    ?? NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Obsidian")

private func vaultRead(_ path: String) -> String {
    guard let fullPath = safePath(root: vaultRoot, relative: path) else {
        log(.error, .vault, "Path traversal blocked", extra: ["path": path])
        return "{\"error\": \"Invalid path\"}"
    }
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
    guard let fullPath = safePath(root: vaultRoot, relative: path) else {
        log(.error, .vault, "Path traversal blocked", extra: ["path": path])
        return "{\"error\": \"Invalid path\"}"
    }
    let dir = (fullPath as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
        log(.info, .vault, "Written", extra: ["path": path, "bytes": content.utf8.count])
        return "{\"ok\": true, \"path\": \"\(path)\"}"
    } catch {
        log(.error, .vault, "Write failed", extra: ["path": path, "error": error.localizedDescription])
        return "{\"error\": \"Write failed: \(error.localizedDescription)\"}"
    }
}

private func vaultList(_ path: String) -> String {
    let fullPath: String
    if path.isEmpty {
        fullPath = vaultRoot
    } else {
        guard let resolved = safePath(root: vaultRoot, relative: path) else {
            log(.error, .vault, "Path traversal blocked", extra: ["path": path])
            return "{\"error\": \"Invalid path\"}"
        }
        fullPath = resolved
    }
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

// MARK: - Stdio MCP Transport

/// Thread-safe stdout writer for the stdio transport.
/// Both the main stdin reader and the background poller write JSON-RPC to stdout.
private let stdoutLock = NSLock()

private func stdioWrite(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    var out = data
    out.append(0x0A) // newline
    stdoutLock.lock()
    FileHandle.standardOutput.write(out)
    stdoutLock.unlock()
}

/// Stdio MCP server — reads JSON-RPC from stdin, writes to stdout.
/// Includes a background poller that pushes incoming iMessages as channel notifications.
func runStdio() {
    log(.info, .mcp, "Stdio transport started")

    // --- Access control, echo suppression, SMS filter ---
    let accessConfig = AccessConfig.load()
    let echoTracker = EchoTracker()
    let allowSMS = ProcessInfo.processInfo.environment["MACOS_MCP_ALLOW_SMS"] == "true"

    // --- Channel poller: starts immediately, like the official plugin ---
    let pollerQueue = DispatchQueue(label: "stdio-poller")
    let initConn = ChatDBConnection()
    var watermark = initConn.maxRowid()
    initConn.close()

    if accessConfig.isEmpty {
        log(.warn, .poller, "No access config — all messages blocked. Set MACOS_MCP_OWNER_PHONE or create ~/.config/macos-mcp/access.json")
    } else {
        log(.info, .poller, "Channel poller started", extra: [
            "watermark": watermark,
            "allowed_phones": accessConfig.allowFrom.count,
            "allowed_groups": accessConfig.allowedGroups.count,
        ])
    }

    // Poll on a 1-second timer (same approach as the official channel plugin).
    // WAL dispatch sources are unreliable — macOS checkpoints can silence them.
    let pollerSource = DispatchSource.makeTimerSource(queue: pollerQueue)
    pollerSource.schedule(deadline: .now() + 1, repeating: 1.0)

    pollerSource.setEventHandler {
        let conn = ChatDBConnection()
        let messages = conn.checkMessages(afterRowid: watermark, phone: nil)
        for msg in messages {
            watermark = msg.rowid

            // SMS/RCS filter — only iMessage by default
            if !allowSMS && !msg.service.isEmpty && msg.service != "iMessage" { continue }

            // Access control — check sender/group against allowlist
            if !accessConfig.isAllowed(from: msg.from, chatGuid: msg.chatGuid) { continue }

            // Need text or an attachment to deliver
            let text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || msg.hasAttachments else { continue }

            // Echo suppression — skip messages that match recent sends
            if echoTracker.isEcho(text) {
                log(.info, .poller, "Suppressed echo", extra: ["rowid": msg.rowid])
                continue
            }

            // Build notification meta with chat GUID and message GUID
            var meta: [String: Any] = [
                "chat_id": msg.chatGuid.isEmpty ? msg.chat : msg.chatGuid,
                "message_id": msg.guid.isEmpty ? String(msg.rowid) : msg.guid,
                "user": ProcessInfo.processInfo.environment["MACOS_MCP_OWNER_NAME"] ?? msg.from,
                "ts": msg.date,
            ]

            // Surface first image attachment path
            if msg.hasAttachments {
                if let imagePath = conn.fetchFirstImagePath(messageRowid: msg.rowid) {
                    meta["image_path"] = imagePath
                }
            }

            let content = text.isEmpty ? "(image)" : text
            let notification: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "notifications/claude/channel",
                "params": [
                    "content": content,
                    "meta": meta,
                ] as [String: Any],
            ]
            stdioWrite(notification)
            // Log the full notification payload for debugging
            if let notifData = try? JSONSerialization.data(withJSONObject: notification, options: [.sortedKeys]),
               let notifJSON = String(data: notifData, encoding: .utf8) {
                log(.info, .poller, "Channel notification sent", extra: [
                    "rowid": msg.rowid, "from": msg.from, "service": msg.service,
                    "payload": notifJSON,
                ])
            } else {
                log(.info, .poller, "Channel notification sent", extra: ["rowid": msg.rowid, "from": msg.from])
            }

            // Start typing indicator while Claude thinks
            let contact = msg.from.hasPrefix("+") ? String(msg.from.dropFirst()) : msg.from
            let binary = ProcessInfo.processInfo.arguments[0]
            let baseRowid = watermark
            DispatchQueue.global().async {
                runProcess(binary, arguments: ["typing", contact, "start"], timeout: 10)
                let typingDB = ChatDBConnection()
                let startTime = Date()
                while Date().timeIntervalSince(startTime) < 300 {
                    Thread.sleep(forTimeInterval: 25)
                    if Int(typingDB.maxRowid()) > baseRowid { break }
                    runProcess(binary, arguments: ["typing", contact, "keepalive"], timeout: 10)
                }
                typingDB.close()
                runProcess(binary, arguments: ["typing", contact, "stop"], timeout: 10)
            }
        }
        conn.close()
    }
    pollerSource.resume()

    // --- Main loop: read JSON-RPC from stdin ---
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        let method = jsonObj["method"] as? String ?? ""
        let id = jsonObj["id"]
        let params = jsonObj["params"] as? [String: Any] ?? [:]

        // Notifications have no id — acknowledge silently
        guard id != nil else { continue }

        let result: [String: Any]
        switch method {
        case "initialize":
            result = jsonRpcResult(id, [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": ["listChanged": false],
                    "experimental": [
                        "claude/channel": [:] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "serverInfo": mcpServerInfo,
            ])
        case "tools/list":
            result = jsonRpcResult(id, ["tools": mcpTools])
        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let toolArgs = params["arguments"] as? [String: Any] ?? [:]
            log(.info, .mcp, "Tool call", extra: ["tool": toolName])
            let output = dispatchTool(toolName, toolArgs)
            // Track sends for echo suppression
            if ["send_imessage", "send_to_chat", "reply"].contains(toolName),
               let text = toolArgs["text"] as? String {
                echoTracker.trackSend(text)
            }
            result = jsonRpcResult(id, [
                "content": [["type": "text", "text": output]],
            ])
        case "ping":
            result = jsonRpcResult(id, [:])
        default:
            result = jsonRpcError(id, code: -32601, message: "Method not found: \(method)")
        }

        stdioWrite(result)
    }

    pollerSource.cancel()
    log(.info, .mcp, "Stdio transport closed")
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
    resp += "Access-Control-Expose-Headers: Mcp-Session-Id\r\n"
    resp += "\r\n"
    var data = resp.data(using: .utf8)!
    data.append(body)
    return data
}

// MARK: - MCP Request Handler

private func handleMCPRequest(_ request: HTTPRequest) -> Data {
    // CORS preflight
    if request.method == "OPTIONS" {
        return httpResponse(status: 204, statusText: "No Content", headers: [
            "Access-Control-Expose-Headers": "Mcp-Session-Id",
        ], body: Data())
    }

    // Only POST is used for Streamable HTTP
    guard request.method == "POST" else {
        return jsonResponse(status: 405, jsonRpcError(nil, code: -32000, message: "Method not allowed"))
    }

    // Auth check: if --mcp-secret is set, require Authorization: Bearer <secret>
    if let secret = mcpSecret {
        let auth = request.headers["authorization"] ?? ""
        guard auth == "Bearer \(secret)" else {
            log(.warn, .mcp, "Unauthorized MCP request")
            return jsonResponse(status: 401, ["error": "Unauthorized"])
        }
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
        let result = jsonRpcResult(id, [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": ["listChanged": true]],
            "serverInfo": mcpServerInfo,
        ])
        return sseResponse(sessionId: sessionId, events: [sseEvent(result)])

    case "notifications/initialized":
        // No response needed for notifications
        return httpResponse(status: 200, statusText: "OK", headers: [
            "Content-Type": "text/event-stream",
            "Mcp-Session-Id": sessionId,
            "Access-Control-Expose-Headers": "Mcp-Session-Id",
        ], body: Data())

    case "tools/list":
        let result = jsonRpcResult(id, ["tools": mcpTools])
        return sseResponse(sessionId: sessionId, events: [sseEvent(result)])

    case "tools/call":
        let toolName = params["name"] as? String ?? ""
        let toolArgs = params["arguments"] as? [String: Any] ?? [:]

        log(.info, .mcp, "Tool call", extra: ["tool": toolName])
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

private var mcpSecret: String? = nil

func runServe(args: [String]) {
    var port: UInt16 = 9200
    var host = "127.0.0.1"
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
        case "--mcp-secret":
            i += 1; guard i < args.count else { fputs("--mcp-secret requires a value\n", stderr); exit(1) }
            mcpSecret = args[i]
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

    let nwPort = NWEndpoint.Port(rawValue: port)!
    var listener: NWListener!
    for attempt in 1...10 {
        do {
            listener = try NWListener(using: params, on: nwPort)
            break
        } catch {
            if attempt == 10 {
                log(.error, .server, "Failed to bind port \(port) after 10 attempts: \(error)")
                exit(1)
            }
            log(.warn, .server, "Port \(port) busy, retrying (\(attempt)/10)…")
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

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
            log(.info, .server, "MCP server listening", extra: ["host": host, "port": port])
            log(.info, .server, "Streamable HTTP endpoint", extra: ["url": "http://\(host):\(port)/mcp"])
        case .failed(let error):
            log(.error, .server, "Server failed", extra: ["error": "\(error)"])
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

// MARK: - WAL File Watcher

/// Watch the chat.db WAL file for writes. Returns nil if file doesn't exist.
private func startWALWatcher(semaphore: DispatchSemaphore, queue: DispatchQueue) -> DispatchSourceFileSystemObject? {
    let walPath = NSString("~/Library/Messages/chat.db-wal").expandingTildeInPath
    let fd = Darwin.open(walPath, O_EVTONLY)
    guard fd >= 0 else {
        log(.warn, .poller, "WAL file not found, using timer-only polling")
        return nil
    }

    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.write, .extend], queue: queue
    )
    source.setEventHandler { semaphore.signal() }
    source.setCancelHandler { Darwin.close(fd) }
    source.resume()
    log(.info, .poller, "WAL watcher active")
    return source
}

// MARK: - iMessage Poller

/// Polls chat.db for new messages and POSTs them to the hermes webhook.
/// Reads SQLite in-process (no subprocess) and watches the WAL file for changes.
private func startPoller(
    webhookURL: String, webhookSecret: String, phone: String,
    pollInterval: TimeInterval, debounceWindow: TimeInterval,
    watermarkPath: String
) {
    let pollerQueue = DispatchQueue(label: "imessage-poller")

    pollerQueue.async {
        let connection = ChatDBConnection()
        let webhookAllowSMS = ProcessInfo.processInfo.environment["MACOS_MCP_ALLOW_SMS"] == "true"
        var watermark = loadWatermark(watermarkPath)

        // Initialize watermark if needed
        if watermark == 0 {
            watermark = Int(connection.maxRowid())
            if watermark > 0 { saveWatermark(watermarkPath, watermark) }
        }

        log(.info, .poller, "Poller started", extra: [
            "watermark": watermark,
            "phone": phone.isEmpty ? "all" : phone,
            "webhook": webhookURL,
            "mode": "in-process",
        ])

        // WAL watcher: signals semaphore on DB changes for instant pickup
        let walSemaphore = DispatchSemaphore(value: 0)
        let walSource = startWALWatcher(semaphore: walSemaphore, queue: pollerQueue)

        var pending: [(text: String, thread: String, rowid: Int)] = []
        var lastMessageTime: Date = .distantPast
        var lastHeartbeat: Date = Date()
        let heartbeatInterval: TimeInterval = 300
        var consecutiveErrors = 0

        while true {
            // Wait for WAL change or fallback timer
            _ = walSemaphore.wait(timeout: .now() + pollInterval)

            // Periodic heartbeat
            if Date().timeIntervalSince(lastHeartbeat) >= heartbeatInterval {
                log(.info, .poller, "Heartbeat", extra: ["watermark": watermark, "pending": pending.count])
                lastHeartbeat = Date()
            }

            // In-process query — no subprocess
            let messages = connection.checkMessages(
                afterRowid: Int64(watermark),
                phone: phone.isEmpty ? nil : phone
            )

            if messages.isEmpty && consecutiveErrors > 0 {
                // Previous errors + empty results = possible stale connection
                consecutiveErrors += 1
                if consecutiveErrors >= 10 {
                    log(.warn, .poller, "Reconnecting after \(consecutiveErrors) empty polls")
                    connection.reconnect()
                    consecutiveErrors = 0
                }
            } else {
                consecutiveErrors = 0
            }

            for msg in messages {
                let rowid = Int(msg.rowid)
                if rowid > watermark {
                    watermark = rowid
                    saveWatermark(watermarkPath, watermark)
                }

                // SMS/RCS filter — only iMessage by default
                if !webhookAllowSMS && !msg.service.isEmpty && msg.service != "iMessage" { continue }

                if msg.text.isEmpty { continue }

                let thread = msg.chat.isEmpty ? msg.from : msg.chat
                if thread.isEmpty { continue }

                log(.info, .poller, "New message", extra: ["rowid": rowid, "thread": thread, "preview": String(msg.text.prefix(80))])
                pending.append((text: msg.text, thread: thread, rowid: rowid))
                lastMessageTime = Date()
            }

            // Flush if debounce expired
            if !pending.isEmpty && Date().timeIntervalSince(lastMessageTime) >= debounceWindow {
                flushToWebhook(pending, webhookURL: webhookURL, webhookSecret: webhookSecret)
                pending.removeAll()
            }
        }

        // Cleanup (unreachable in practice but good form)
        walSource?.cancel()
        connection.close()
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
            let binary = ProcessInfo.processInfo.arguments[0]
            log(.info, .typing, "Starting typing indicator", extra: ["thread": thread])
            runProcess(binary, arguments: ["typing", contact, "start"], timeout: 10)

            // In-process DB connection for max-rowid checks (own connection for thread safety)
            let typingDB = ChatDBConnection()
            let keepaliveInterval: TimeInterval = 25
            let maxWait: TimeInterval = 300
            let startTime = Date()
            let baseRowid = maxRowid

            while Date().timeIntervalSince(startTime) < maxWait {
                Thread.sleep(forTimeInterval: keepaliveInterval)

                // Check if an outbound message appeared (hermes replied)
                let currentMax = Int(typingDB.maxRowid())
                if currentMax > baseRowid {
                    log(.info, .typing, "Outbound detected, stopping")
                    break
                }

                runProcess(binary, arguments: ["typing", contact, "keepalive"], timeout: 10)
            }

            typingDB.close()
            runProcess(binary, arguments: ["typing", contact, "stop"], timeout: 10)
        }

        log(.info, .webhook, "Flushing to webhook", extra: ["thread": thread, "count": msgs.count])

        guard let url = URL(string: webhookURL) else { continue }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sha256=\(signature)", forHTTPHeaderField: "X-Hub-Signature-256")
        request.httpBody = body

        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                log(.error, .webhook, "Request failed", extra: ["error": error.localizedDescription])
            } else if let httpResp = response as? HTTPURLResponse {
                let respBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if httpResp.statusCode >= 400 {
                    log(.error, .webhook, "HTTP error", extra: ["status": httpResp.statusCode, "body": String(respBody.prefix(200))])
                } else {
                    log(.info, .webhook, "Accepted", extra: ["status": httpResp.statusCode])
                }
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
