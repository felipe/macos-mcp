import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CMailSQLite
#endif

struct MailSearchQuery {
    var query: String?
    var sender: String?
    var recipient: String?
    var subject: String?
    var mailbox: String?
    var since: Double?
    var offset: Int = 0
    var read: Bool?
    var flagged: Bool?
    var limit: Int = 20

    init(query: String? = nil, sender: String? = nil, recipient: String? = nil,
         subject: String? = nil, mailbox: String? = nil, since: Double? = nil,
         limit: Int = 20) {
        self.query = query
        self.sender = sender
        self.recipient = recipient
        self.subject = subject
        self.mailbox = mailbox
        self.since = since
        self.limit = limit
    }
}

struct MailSummary: Equatable {
    let rowid: Int64
    let documentID: String?
    let subject: String
    let sender: String
    let mailbox: String
    let dateReceived: Double
    let read: Bool
    let flagged: Bool
}

struct MailMailbox: Equatable {
    let rowid: Int64
    let url: String
}

enum MailDBError: Error, LocalizedError, Equatable {
    case mailDataNotFound
    case databaseOpenFailed
    case unsupportedSchema
    case queryFailed
    case messageNotFound
    case ambiguousMessage
    case messageFileNotFound
    case ambiguousMessageFile
    case messageFileSearchLimitExceeded

    var errorDescription: String? {
        switch self {
        case .mailDataNotFound: return "Apple Mail data was not found"
        case .databaseOpenFailed: return "Unable to open Apple Mail index"
        case .unsupportedSchema: return "Apple Mail index has an unsupported schema"
        case .queryFailed: return "Apple Mail index query failed"
        case .messageNotFound: return "Message was not found"
        case .ambiguousMessage: return "Message identifier matches more than one message"
        case .messageFileNotFound: return "Message file was not found"
        case .ambiguousMessageFile: return "Message file identity is ambiguous"
        case .messageFileSearchLimitExceeded: return "Message file search exceeded its safety limit"
        }
    }
}

/// Read-only access to Apple's Envelope Index. Instances are intended for one serial queue.
final class MailDBConnection {
    private var db: OpaquePointer?
    private let databasePath: String
    private let versionDirectory: URL
    private let supportsMessageIDHeaders: Bool

    /// `MAIL_DATA_DIR` may name the Mail directory, a version directory (such as V10),
    /// or its MailData directory. It is primarily useful for fixtures and controlled tests.
    init(path: String? = nil, mailRoot: URL? = nil) throws {
        let root: URL
        if let mailRoot {
            root = try Self.resolveVersionDirectory(from: mailRoot)
        } else if let configured = ProcessInfo.processInfo.environment["MAIL_DATA_DIR"], !configured.isEmpty {
            root = try Self.resolveVersionDirectory(from: URL(fileURLWithPath: configured))
        } else if let path {
            // An explicit index path normally has the form V*/MailData/Envelope Index.
            root = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
        } else {
            root = try Self.resolveVersionDirectory(from: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mail", isDirectory: true))
        }

        let indexURL = path.map(URL.init(fileURLWithPath:))
            ?? root.appendingPathComponent("MailData/Envelope Index", isDirectory: false)
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw MailDBError.mailDataNotFound
        }

        self.databasePath = indexURL.path
        self.versionDirectory = root

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw MailDBError.databaseOpenFailed
        }
        self.db = handle
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try Self.validateSchema(handle)
            self.supportsMessageIDHeaders = Self.hasColumns(handle, table: "messages", columns: ["global_message_id"])
                && Self.hasColumns(handle, table: "message_global_data", columns: ["message_id_header"])
        } catch {
            sqlite3_close(handle)
            self.db = nil
            throw error
        }
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close(db); self.db = nil }
    }

    func search(_ query: MailSearchQuery) throws -> [MailSummary] {
        let limit = max(1, min(query.limit, 200))
        var clauses = ["m.deleted = 0"]
        var bindings: [Binding] = []

        func contains(_ value: String) -> String { "%\(Self.escapeLike(value))%" }
        if let value = nonEmpty(query.query) {
            clauses.append("(s.subject LIKE ? ESCAPE '\\' COLLATE NOCASE OR sender.address LIKE ? ESCAPE '\\' COLLATE NOCASE OR sender.comment LIKE ? ESCAPE '\\' COLLATE NOCASE)")
            let pattern = contains(value)
            bindings += [.text(pattern), .text(pattern), .text(pattern)]
        }
        if let value = nonEmpty(query.sender) {
            clauses.append("(sender.address LIKE ? ESCAPE '\\' COLLATE NOCASE OR sender.comment LIKE ? ESCAPE '\\' COLLATE NOCASE)")
            let pattern = contains(value)
            bindings += [.text(pattern), .text(pattern)]
        }
        if let value = nonEmpty(query.recipient) {
            clauses.append("EXISTS (SELECT 1 FROM recipients r JOIN addresses recipient ON recipient.ROWID = r.address WHERE r.message = m.ROWID AND (recipient.address LIKE ? ESCAPE '\\' COLLATE NOCASE OR recipient.comment LIKE ? ESCAPE '\\' COLLATE NOCASE))")
            let pattern = contains(value)
            bindings += [.text(pattern), .text(pattern)]
        }
        if let value = nonEmpty(query.subject) {
            clauses.append("s.subject LIKE ? ESCAPE '\\' COLLATE NOCASE")
            bindings.append(.text(contains(value)))
        }
        if let value = nonEmpty(query.mailbox) {
            clauses.append("mb.url = ? COLLATE NOCASE")
            bindings.append(.text(value))
        }
        if let since = query.since {
            clauses.append("m.date_received >= ?")
            bindings.append(.double(since))
        }
        if let read = query.read { clauses.append("m.read = ?"); bindings.append(.int64(read ? 1 : 0)) }
        if let flagged = query.flagged { clauses.append("m.flagged = ?"); bindings.append(.int64(flagged ? 1 : 0)) }
        bindings.append(.int64(Int64(limit)))
        bindings.append(.int64(Int64(max(0, query.offset))))

        let sql = """
        SELECT m.ROWID, m.document_id, COALESCE(s.subject, ''),
               COALESCE(sender.address, sender.comment, ''), COALESCE(mb.url, ''),
               COALESCE(m.date_received, 0), m.read, m.flagged
        FROM messages m
        LEFT JOIN addresses sender ON sender.ROWID = m.sender
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN mailboxes mb ON mb.ROWID = m.mailbox
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY m.date_received DESC, m.ROWID DESC
        LIMIT ? OFFSET ?
        """
        return try summaries(sql: sql, bindings: bindings)
    }

    func mailboxes() throws -> [MailMailbox] {
        let db = try database()
        let sql = "SELECT ROWID, url FROM mailboxes ORDER BY url COLLATE NOCASE, ROWID"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MailDBError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        var result: [MailMailbox] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(MailMailbox(rowid: sqlite3_column_int64(statement, 0), url: Self.text(statement, column: 1)))
        }
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else { throw MailDBError.queryFailed }
        return result
    }

    func message(rowid: Int64) throws -> MailSummary {
        let matches = try summaries(sql: Self.summarySQL(where: "m.ROWID = ?"), bindings: [.int64(rowid)])
        guard let result = matches.first else { throw MailDBError.messageNotFound }
        return result
    }

    /// Resolves an RFC 822 Message-ID through Apple's global-message table.
    /// A duplicate header is deliberately rejected instead of choosing an arbitrary copy.
    func message(messageID: String) throws -> MailSummary {
        guard supportsMessageIDHeaders else { throw MailDBError.unsupportedSchema }
        let matches = try summaries(sql: Self.summarySQL(where: "mgd.message_id_header = ?", includeGlobalData: true), bindings: [.text(messageID)])
        guard !matches.isEmpty else { throw MailDBError.messageNotFound }
        guard matches.count == 1 else { throw MailDBError.ambiguousMessage }
        return matches[0]
    }

    /// Finds the `.emlx` whose basename is the Envelope Index rowid. If copies exist,
    /// the RFC 822 Message-ID must identify exactly one of them; otherwise this fails closed.
    func messageFile(rowid: Int64) throws -> URL {
        let summary = try message(rowid: rowid)
        let expectedMessageID = try messageIDHeader(rowid: rowid)
        let filename = "\(rowid).emlx"
        let scope = Self.mailboxDirectory(url: summary.mailbox, in: versionDirectory)
        let candidates = try Self.findMessageFiles(named: filename, under: scope ?? versionDirectory)
        guard !candidates.isEmpty else { throw MailDBError.messageFileNotFound }
        guard let expectedMessageID else {
            guard candidates.count == 1 else { throw MailDBError.ambiguousMessageFile }
            return candidates[0]
        }
        let matching = candidates.filter { Self.rfc822MessageID(in: $0) == expectedMessageID }
        guard matching.count == 1 else {
            throw matching.isEmpty ? MailDBError.messageFileNotFound : MailDBError.ambiguousMessageFile
        }
        return matching[0]
    }

    private enum Binding { case text(String), double(Double), int64(Int64) }

    private func summaries(sql: String, bindings: [Binding]) throws -> [MailSummary] {
        let db = try database()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MailDBError.queryFailed }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case .double(let value): result = sqlite3_bind_double(statement, index, value)
            case .int64(let value): result = sqlite3_bind_int64(statement, index, value)
            }
            guard result == SQLITE_OK else { throw MailDBError.queryFailed }
        }
        var result: [MailSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(MailSummary(rowid: sqlite3_column_int64(statement, 0), documentID: Self.optionalText(statement, column: 1), subject: Self.text(statement, column: 2), sender: Self.text(statement, column: 3), mailbox: Self.text(statement, column: 4), dateReceived: sqlite3_column_double(statement, 5), read: sqlite3_column_int(statement, 6) != 0, flagged: sqlite3_column_int(statement, 7) != 0))
        }
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else { throw MailDBError.queryFailed }
        return result
    }

    func messageIDHeader(rowid: Int64) throws -> String? {
        guard supportsMessageIDHeaders else { return nil }
        let db = try database()
        let sql = "SELECT mgd.message_id_header FROM messages m JOIN message_global_data mgd ON mgd.ROWID = m.global_message_id WHERE m.ROWID = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MailDBError.queryFailed }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, rowid) == SQLITE_OK else { throw MailDBError.queryFailed }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.optionalText(statement, column: 0)
    }

    private func database() throws -> OpaquePointer {
        guard let db else { throw MailDBError.databaseOpenFailed }
        return db
    }

    private static func summarySQL(where clause: String, includeGlobalData: Bool = false) -> String {
        let globalJoin = includeGlobalData ? "JOIN message_global_data mgd ON mgd.ROWID = m.global_message_id" : ""
        return """
        SELECT m.ROWID, m.document_id, COALESCE(s.subject, ''),
               COALESCE(sender.address, sender.comment, ''), COALESCE(mb.url, ''),
               COALESCE(m.date_received, 0), m.read, m.flagged
        FROM messages m
        LEFT JOIN addresses sender ON sender.ROWID = m.sender
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN mailboxes mb ON mb.ROWID = m.mailbox
        \(globalJoin)
        WHERE \(clause)
        """
    }

    private static func resolveVersionDirectory(from input: URL) throws -> URL {
        let fm = FileManager.default
        let direct = input.standardizedFileURL
        if fm.fileExists(atPath: direct.appendingPathComponent("MailData/Envelope Index").path) { return direct }
        if direct.lastPathComponent == "MailData", fm.fileExists(atPath: direct.appendingPathComponent("Envelope Index").path) { return direct.deletingLastPathComponent() }
        let contents = (try? fm.contentsOfDirectory(at: direct, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let versions = contents.compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            guard name.first == "V", let number = Int(name.dropFirst()), fm.fileExists(atPath: url.appendingPathComponent("MailData/Envelope Index").path) else { return nil }
            return (number, url)
        }
        guard let highest = versions.max(by: { $0.0 < $1.0 })?.1 else { throw MailDBError.mailDataNotFound }
        return highest
    }

    /// Maps imap://<account-storage-id>/<folder>/<child> to
    /// <V*>/<account-storage-id>/<folder>.mbox/<child>.mbox. Returns nil for
    /// malformed URLs or a mailbox that is not currently cached locally.
    private static func mailboxDirectory(url: String, in versionDirectory: URL) -> URL? {
        guard let components = URLComponents(string: url),
              let host = components.host, !host.isEmpty,
              let scheme = components.scheme, ["imap", "local", "pop"].contains(scheme.lowercased()) else { return nil }
        let encodedParts = components.percentEncodedPath.split(separator: "/").map(String.init)
        guard !encodedParts.isEmpty else { return nil }
        let parts = encodedParts.compactMap { $0.removingPercentEncoding }
        guard parts.count == encodedParts.count,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") }) else { return nil }
        var directory = versionDirectory.appendingPathComponent(host, isDirectory: true)
        for part in parts { directory.appendPathComponent("\(part).mbox", isDirectory: true) }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue ? directory : nil
    }

    private static func findMessageFiles(named filename: String, under root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw MailDBError.messageFileNotFound
        }
        var candidates: [URL] = []
        var visited = 0
        let maximumVisitedEntries = 1_000_000
        for case let file as URL in enumerator {
            visited += 1
            guard visited <= maximumVisitedEntries else { throw MailDBError.messageFileSearchLimitExceeded }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard file.lastPathComponent == filename,
                  !file.path.contains(".partial.emlx"),
                  values?.isRegularFile == true,
                  file.pathComponents.contains("Messages") else { continue }
            candidates.append(file)
        }
        return candidates
    }

    private static func validateSchema(_ db: OpaquePointer) throws {
        let requirements: [(String, [String])] = [
            ("messages", ["message_id", "document_id", "sender", "subject", "date_sent", "date_received", "mailbox", "read", "flagged", "deleted"]),
            ("addresses", ["address", "comment"]),
            ("subjects", ["subject"]),
            ("mailboxes", ["url"]),
            ("recipients", ["message", "address", "type", "position"])
        ]
        guard requirements.allSatisfy({ hasColumns(db, table: $0.0, columns: $0.1) }) else { throw MailDBError.unsupportedSchema }
    }

    private static func hasColumns(_ db: OpaquePointer, table: String, columns: [String]) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        var present = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { present.insert(text(statement, column: 1)) }
        return Set(columns).isSubset(of: present)
    }

    private static func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String { optionalText(statement, column: column) ?? "" }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    private static func rfc822MessageID(in file: URL) -> String? {
        // Headers are tiny; cap reads and never decode the body (which may be binary).
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        let bytes = [UInt8](data)
        guard let firstNewline = bytes.firstIndex(of: 10) else { return nil }
        let headerStart = firstNewline + 1
        var headerEnd: Int?
        var index = headerStart
        while index + 1 < bytes.count {
            if bytes[index] == 10, bytes[index + 1] == 10 {
                headerEnd = index
                break
            }
            if index + 3 < bytes.count,
               bytes[index] == 13, bytes[index + 1] == 10,
               bytes[index + 2] == 13, bytes[index + 3] == 10 {
                headerEnd = index
                break
            }
            index += 1
        }
        guard let headerEnd else { return nil }
        var value: String?
        var collecting = false
        var lineStart = headerStart
        while lineStart < headerEnd {
            var lineEnd = lineStart
            while lineEnd < headerEnd, bytes[lineEnd] != 10, bytes[lineEnd] != 13 { lineEnd += 1 }
            let string = String(String.UnicodeScalarView(bytes[lineStart..<lineEnd].map { UnicodeScalar(UInt32($0))! }))
            if string.isEmpty { break }
            if collecting, string.hasPrefix(" ") || string.hasPrefix("\t") {
                value = (value ?? "") + string.trimmingCharacters(in: .whitespaces)
            } else {
                collecting = false
                if string.lowercased().hasPrefix("message-id:") {
                    value = String(string.dropFirst("message-id:".count)).trimmingCharacters(in: .whitespaces)
                    collecting = true
                }
            }
            while lineEnd < headerEnd, bytes[lineEnd] == 10 || bytes[lineEnd] == 13 { lineEnd += 1 }
            lineStart = lineEnd
        }
        return value
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}
