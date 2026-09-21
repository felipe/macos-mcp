import Foundation
import CoreFoundation

func runMail(subcommand: String, args: [String]) {
    if subcommand == "help" || args == ["--help"] {
        printJSON(["usage": [
            "mail search [QUERY] [--sender EMAIL] [--recipient EMAIL] [--subject TEXT] [--mailbox URL] [--since ISO_DATE] [--limit 20]",
            "mail read ROWID [--include-html] | mail read --message-id RFC_MESSAGE_ID",
            "mail mailboxes",
            "mail send --to EMAIL --subject TEXT --body TEXT [--cc EMAIL] [--bcc EMAIL] [--attach PATH] [--account SENDER_EMAIL]",
            "mail draft --subject TEXT --body TEXT [--to EMAIL] [--attach PATH]",
            "mail reply ROWID --body TEXT [--all]",
            "mail forward ROWID --to EMAIL --body TEXT",
            "mail move ROWID --target-mailbox PATH [--account SENDER_EMAIL]",
            "mail flag ROWID [--read|--unread] [--flag|--unflag]",
            "Actions also accept --message-id RFC_MESSAGE_ID instead of ROWID, with --account and --mailbox for disambiguation.",
        ]])
        return
    }
    do {
        guard let spec = mailToolSpecs.first(where: { $0.action == subcommand }) else { throw MailInputError(message: "Unknown mail subcommand") }
        let input = try parseMailCLI(spec: spec, args: args)
        _ = try mailCLIArguments(tool: spec.name, input: input)
        if subcommand == "mailboxes" {
            let boxes = try MailDBConnection().mailboxes()
            printJSON(["mailboxes": boxes.map { ["rowid": $0.rowid, "url": $0.url] as [String: Any] }])
        } else if subcommand == "search" {
            var query = MailSearchQuery()
            query.query = input["query"] as? String; query.sender = input["sender"] as? String
            query.recipient = input["recipient"] as? String; query.subject = input["subject"] as? String
            query.mailbox = input["mailbox"] as? String
            query.limit = (input["limit"] as? NSNumber)?.intValue ?? 20
            if let since = input["since"] as? String {
                guard let date = parseDate(since) else { throw MailInputError(message: "since must be an ISO 8601 date") }
                query.since = date.timeIntervalSince1970
            }
            let messages = try MailDBConnection().search(query)
            printJSON(["messages": messages.map(mailSummaryJSON), "search_scope": "subject_sender_metadata", "limit": query.limit])
        } else if subcommand == "read" {
            let db = try MailDBConnection()
            let summary: MailSummary
            if let rowid = input["rowid"] as? NSNumber { summary = try db.message(rowid: rowid.int64Value) }
            else { summary = try db.message(messageID: input["message_id"] as! String) }
            let parsed = try readMailFile(db: db, rowid: summary.rowid, html: input["include_html"] as? Bool ?? false)
            var result = mailSummaryJSON(summary)
            result["headers"] = parsed.headers; result["body"] = parsed.body
            result["html"] = parsed.html
            result["attachments"] = parsed.attachments.map { ["filename": $0.filename as Any? ?? NSNull(), "content_type": $0.contentType, "size": $0.size] }
            printJSON(result)
        } else {
            var actionArgs: [String: String] = [:]
            for (key, value) in input {
                if let values = value as? [String] { actionArgs[key] = values.joined(separator: "\n") }
                else if let value = value as? String { actionArgs[key] = value }
                else if let value = value as? NSNumber { actionArgs[key] = CFGetTypeID(value) == CFBooleanGetTypeID() ? (value.boolValue ? "true" : "false") : value.stringValue }
            }
            if let rowid = input["rowid"] as? NSNumber {
                let db = try MailDBConnection()
                let summary = try db.message(rowid: rowid.int64Value)
                let parsed = try readMailFile(db: db, rowid: rowid.int64Value, html: false)
                guard let messageID = parsed.headers["message-id"], !messageID.isEmpty else { throw MailInputError(message: "Cached message has no RFC Message-ID; cannot safely target an action") }
                actionArgs["message_id"] = messageID
                actionArgs["lookup_id"] = rowid.stringValue
                if let mailboxURL = URLComponents(string: summary.mailbox) {
                    if actionArgs["mailbox"] == nil { actionArgs["mailbox"] = mailboxURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                    if actionArgs["account"] == nil, let host = mailboxURL.host { actionArgs["account_id"] = host }
                }
                actionArgs.removeValue(forKey: "rowid")
            }
            printJSON(try MailActions.perform(subcommand, arguments: actionArgs))
        }
    } catch { exitWithError(error.localizedDescription) }
}

private func readMailFile(db: MailDBConnection, rowid: Int64, html: Bool) throws -> MailParsedMessage {
    let file = try db.messageFile(rowid: rowid)
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 64 * 1024 * 1024 else { throw MailInputError(message: "Cached message exceeds the 64 MiB read limit") }
    return try MailParser.parse(Data(contentsOf: file), includeHTML: html)
}

private func mailSummaryJSON(_ message: MailSummary) -> [String: Any] {
    ["rowid": message.rowid, "document_id": message.documentID as Any? ?? NSNull(),
     "subject": message.subject, "sender": message.sender, "mailbox": message.mailbox,
     "date_received": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: message.dateReceived)),
     "read": message.read, "flagged": message.flagged]
}

private func parseMailCLI(spec: MailToolSpec, args: [String]) throws -> [String: Any] {
    var input: [String: Any] = [:]
    var index = 0
    let aliases = ["attach": "attachments", "all": "reply_all", "flag": "flagged", "unflag": "flagged", "unread": "read", "source_mailbox": "mailbox"]
    while index < args.count {
        let token = args[index]
        if token == "--json" { index += 1; continue }
        if !token.hasPrefix("--") {
            let key = spec.action == "search" ? "query" : "rowid"
            guard input[key] == nil else { throw MailInputError(message: "Unexpected positional argument") }
            if key == "rowid" {
                guard let value = Int64(token), value > 0 else { throw MailInputError(message: "Use a positive rowid or --message-id RFC_MESSAGE_ID") }
                input[key] = NSNumber(value: value)
            } else { input[key] = token }
            index += 1; continue
        }
        let raw = String(token.dropFirst(2)).replacingOccurrences(of: "-", with: "_")
        let key = raw == "mailbox" && spec.action == "move" && !args.contains("--target-mailbox")
            ? "target_mailbox" : (aliases[raw] ?? raw)
        guard (spec.strings + spec.arrays + spec.booleans + spec.integers).contains(key) else { throw MailInputError(message: "Unknown option \(token)") }
        if spec.booleans.contains(key) {
            guard input[key] == nil else { throw MailInputError(message: "Conflicting or repeated option \(token)") }
            var value = raw != "unread" && raw != "unflag"
            if index + 1 < args.count, ["true", "false"].contains(args[index + 1]) { index += 1; value = args[index] == "true" }
            input[key] = NSNumber(value: value)
        } else {
            index += 1
            guard index < args.count else { throw MailInputError(message: "\(token) requires a value") }
            if spec.arrays.contains(key) { input[key] = (input[key] as? [String] ?? []) + [args[index]] }
            else {
                guard input[key] == nil else { throw MailInputError(message: "Repeated option \(token)") }
                if spec.integers.contains(key) {
                    guard let value = Int64(args[index]) else { throw MailInputError(message: "\(token) requires an integer") }
                    input[key] = NSNumber(value: value)
                } else { input[key] = args[index] }
            }
        }
        index += 1
    }
    return input
}
