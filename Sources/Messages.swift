import Foundation
import SQLite3

// MARK: - Database

private let chatDBPath = NSString("~/Library/Messages/chat.db").expandingTildeInPath

private func openDB() -> OpaquePointer {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(chatDBPath, &db, flags, nil) == SQLITE_OK, let db = db else {
        exitWithError("Cannot open Messages database at \(chatDBPath). Is Full Disk Access granted?")
    }
    return db
}

private func query(_ db: OpaquePointer, sql: String, bind: ((OpaquePointer) -> Void)? = nil) -> [[String: Any]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
        let err = String(cString: sqlite3_errmsg(db))
        exitWithError("SQL prepare failed: \(err)")
    }
    defer { sqlite3_finalize(stmt) }

    bind?(stmt)

    var rows: [[String: Any]] = []
    let colCount = sqlite3_column_count(stmt)

    while sqlite3_step(stmt) == SQLITE_ROW {
        var row: [String: Any] = [:]
        for i in 0..<colCount {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER:
                row[name] = NSNumber(value: sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT:
                row[name] = NSNumber(value: sqlite3_column_double(stmt, i))
            case SQLITE_TEXT:
                row[name] = String(cString: sqlite3_column_text(stmt, i))
            case SQLITE_BLOB:
                let bytes = sqlite3_column_bytes(stmt, i)
                if let ptr = sqlite3_column_blob(stmt, i) {
                    row[name] = Data(bytes: ptr, count: Int(bytes))
                }
            case SQLITE_NULL:
                row[name] = NSNull()
            default:
                break
            }
        }
        rows.append(row)
    }
    return rows
}

// MARK: - attributedBody Decoding

private func decodeAttributedBody(_ data: Data) -> String? {
    // Try NSKeyedUnarchiver first (proper decoding)
    if let attrString = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) {
        let text = attrString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
    }

    // Fallback: scan raw bytes for printable UTF-8 runs (similar to shell's `strings -n 4`)
    // The attributedBody contains an NSKeyedArchiver plist with the text embedded.
    // Look for the longest printable string run that isn't a class name.
    let skipPrefixes = ["NS", "Apple", "streamtyped", "MSMessage", "bplist"]
    var bestRun = ""

    if let raw = String(data: data, encoding: .isoLatin1) {
        let runs = raw.components(separatedBy: CharacterSet.controlCharacters)
        for run in runs {
            let trimmed = run.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 4 && trimmed.count > bestRun.count {
                let shouldSkip = skipPrefixes.contains { trimmed.hasPrefix($0) }
                if !shouldSkip {
                    bestRun = trimmed
                }
            }
        }
    }

    return bestRun.isEmpty ? nil : bestRun
}

// MARK: - Attachment Query

private func fetchAttachments(db: OpaquePointer, messageRowid: Int64) -> [[String: Any]] {
    let sql = """
        SELECT a.ROWID, a.filename, a.mime_type, a.transfer_name
        FROM attachment a
        JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
        WHERE maj.message_id = ?
        """
    let rows = query(db, sql: sql) { stmt in
        sqlite3_bind_int64(stmt, 1, messageRowid)
    }

    return rows.map { row in
        var att: [String: Any] = [:]
        if let filename = row["filename"] as? String {
            att["filename"] = NSString(string: filename).expandingTildeInPath
        }
        if let mime = row["mime_type"] as? String { att["mime_type"] = mime }
        if let name = row["transfer_name"] as? String { att["transfer_name"] = name }
        return att
    }
}

// MARK: - Messages Check

private func messagesCheck(phone: String?, sinceMinutes: Int) {
    let db = openDB()
    defer { sqlite3_close(db) }

    let sinceUnix = Date().timeIntervalSince1970 - Double(sinceMinutes * 60)
    let sinceAppleNanos = Int64((sinceUnix - appleEpochOffset) * 1_000_000_000)

    var messages: [[String: Any]]

    if let phone = phone {
        let sql = """
            SELECT m.ROWID, COALESCE(m.text, '') as text, m.is_from_me, m.date,
                   h.id as handle_id, c.chat_identifier,
                   COALESCE(m.guid, '') as guid,
                   COALESCE(m.thread_originator_guid, '') as thread_originator_guid,
                   m.attributedBody
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id LIKE ? AND m.is_from_me = 0 AND m.date > ?
            ORDER BY m.date DESC
            LIMIT 50
            """
        messages = query(db, sql: sql) { stmt in
            let pattern = "%\(phone)%"
            sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(stmt, 2, sinceAppleNanos)
        }
    } else {
        let sql = """
            SELECT m.ROWID, COALESCE(m.text, '') as text, m.is_from_me, m.date,
                   '' as handle_id, '' as chat_identifier,
                   COALESCE(m.guid, '') as guid,
                   COALESCE(m.thread_originator_guid, '') as thread_originator_guid,
                   m.attributedBody
            FROM message m
            WHERE m.is_from_me = 0 AND m.date > ?
            ORDER BY m.date DESC
            LIMIT 50
            """
        messages = query(db, sql: sql) { stmt in
            sqlite3_bind_int64(stmt, 1, sinceAppleNanos)
        }
    }

    let result: [[String: Any]] = messages.map { row in
        let rowid = row["ROWID"] as? Int64 ?? 0
        var text = row["text"] as? String ?? ""

        // Decode attributedBody if text is empty
        if text.isEmpty, let bodyData = row["attributedBody"] as? Data {
            text = decodeAttributedBody(bodyData) ?? ""
        }

        let dateNanos = row["date"] as? Int64 ?? 0
        let guid = row["guid"] as? String ?? ""
        let threadReplyTo = row["thread_originator_guid"] as? String ?? ""
        let handleId = row["handle_id"] as? String ?? ""
        let chatId = row["chat_identifier"] as? String ?? ""

        let attachments = fetchAttachments(db: db, messageRowid: rowid)

        var msg: [String: Any] = [
            "rowid": NSNumber(value: rowid),
            "guid": guid,
            "date": appleNanosToISO(dateNanos),
            "text": text,
            "from": handleId,
            "chat": chatId,
            "attachments": attachments
        ]
        if !threadReplyTo.isEmpty {
            msg["thread_reply_to"] = threadReplyTo
        }
        return msg
    }

    printJSON(["messages": result])
}

// MARK: - Messages Read

private func messagesRead(phone: String?, limit: Int) {
    let db = openDB()
    defer { sqlite3_close(db) }

    var messages: [[String: Any]]

    if let phone = phone {
        let sql = """
            SELECT m.ROWID, COALESCE(m.text, '') as text, m.is_from_me, m.date,
                   h.id as handle_id, COALESCE(m.guid, '') as guid,
                   COALESCE(m.thread_originator_guid, '') as thread_originator_guid,
                   m.attributedBody
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id LIKE ?
            ORDER BY m.date DESC
            LIMIT ?
            """
        messages = query(db, sql: sql) { stmt in
            let pattern = "%\(phone)%"
            sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        }
    } else {
        let sql = """
            SELECT m.ROWID, COALESCE(m.text, '') as text, m.is_from_me, m.date,
                   '' as handle_id, COALESCE(m.guid, '') as guid,
                   COALESCE(m.thread_originator_guid, '') as thread_originator_guid,
                   m.attributedBody
            FROM message m
            ORDER BY m.date DESC
            LIMIT ?
            """
        messages = query(db, sql: sql) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(limit))
        }
    }

    let result: [[String: Any]] = messages.map { row in
        let rowid = row["ROWID"] as? Int64 ?? 0
        var text = row["text"] as? String ?? ""

        if text.isEmpty, let bodyData = row["attributedBody"] as? Data {
            text = decodeAttributedBody(bodyData) ?? ""
        }

        let dateNanos = row["date"] as? Int64 ?? 0
        let isFromMe = (row["is_from_me"] as? Int64 ?? 0) == 1
        let handleId = row["handle_id"] as? String ?? ""
        let guid = row["guid"] as? String ?? ""
        let threadReplyTo = row["thread_originator_guid"] as? String ?? ""

        let attachments = fetchAttachments(db: db, messageRowid: rowid)

        var msg: [String: Any] = [
            "rowid": NSNumber(value: rowid),
            "guid": guid,
            "date": appleNanosToISO(dateNanos),
            "text": text,
            "is_from_me": NSNumber(value: isFromMe),
            "handle": handleId,
            "attachments": attachments
        ]
        if !threadReplyTo.isEmpty {
            msg["thread_reply_to"] = threadReplyTo
        }
        return msg
    }

    // Reverse so oldest-first for conversation reading
    printJSON(["messages": Array(result.reversed())])
}

// MARK: - List Conversations

private func listConversations(limit: Int) {
    let db = openDB()
    defer { sqlite3_close(db) }

    let sql = """
        SELECT
            c.ROWID,
            c.chat_identifier,
            COALESCE(c.display_name, '') as display_name,
            c.style,
            MAX(m.date) as last_message_date,
            COUNT(m.ROWID) as message_count
        FROM chat c
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        JOIN message m ON cmj.message_id = m.ROWID
        GROUP BY c.ROWID
        ORDER BY last_message_date DESC
        LIMIT ?
        """
    let rows = query(db, sql: sql) { stmt in
        sqlite3_bind_int64(stmt, 1, Int64(limit))
    }

    // Fetch handle IDs for each conversation
    let conversations: [[String: Any]] = rows.map { row in
        let chatRowid = row["ROWID"] as? Int64 ?? 0
        let chatId = row["chat_identifier"] as? String ?? ""
        let displayName = row["display_name"] as? String ?? ""
        let style = row["style"] as? Int64 ?? 0
        let lastDate = row["last_message_date"] as? Int64 ?? 0
        let count = row["message_count"] as? Int64 ?? 0

        // Get participants
        let handleSql = """
            SELECT h.id FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            """
        let handles = query(db, sql: handleSql) { stmt in
            sqlite3_bind_int64(stmt, 1, chatRowid)
        }
        let participants = handles.compactMap { $0["id"] as? String }

        return [
            "chat_identifier": chatId,
            "display_name": displayName,
            "is_group": NSNumber(value: style == 45),
            "participants": participants,
            "last_message_date": appleNanosToISO(lastDate),
            "message_count": NSNumber(value: count)
        ] as [String: Any]
    }

    printJSON(["conversations": conversations])
}

// MARK: - Entry Point

func runMessages(subcommand: String, args: [String]) {
    switch subcommand {
    case "check":
        var phone: String?
        var sinceMinutes = 60
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--phone": phone = requireArgValue(args, &i, flag: "--phone")
            case "--since":
                let val = requireArgValue(args, &i, flag: "--since")
                sinceMinutes = Int(val) ?? 60
            default: break
            }
            i += 1
        }
        messagesCheck(phone: phone, sinceMinutes: sinceMinutes)

    case "read":
        var phone: String?
        var limit = 10
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--phone": phone = requireArgValue(args, &i, flag: "--phone")
            case "--limit":
                let val = requireArgValue(args, &i, flag: "--limit")
                limit = Int(val) ?? 10
            default: break
            }
            i += 1
        }
        messagesRead(phone: phone, limit: limit)

    case "list-conversations":
        var limit = 20
        var i = 0
        while i < args.count {
            if args[i] == "--limit" {
                let val = requireArgValue(args, &i, flag: "--limit")
                limit = Int(val) ?? 20
            }
            i += 1
        }
        listConversations(limit: limit)

    case "attachments":
        runAttachments(args: args)

    default:
        exitWithError("Unknown messages subcommand: \(subcommand)")
    }
}
