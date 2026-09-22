import Foundation

// Version 1 is independent of both Apple's storage schema and Himalaya's CLI.
let mailSharedSpecs: [MailToolSpec] = [
    MailToolSpec("capabilities", "Describe Mail contract v1 and the pinned Himalaya MCP compatibility subset."),
    MailToolSpec("account_list", "List indexed account IDs and configured aliases. No Mail.app automation."),
    MailToolSpec("mailbox_list", "List mailboxes for one account. account is an indexed ID or configured alias.", strings: ["account"]),
    MailToolSpec("envelope_list", "List metadata newest first. mailbox defaults to INBOX; account is required when multiple accounts exist. Pages are 1-based, size 1..200.", strings: ["account", "mailbox"], integers: ["page", "page_size"]),
    MailToolSpec("envelope_search", "Search metadata using literal filters; no body search. Same account/mailbox scope and pagination as envelope_list.", strings: ["account", "mailbox", "sender", "recipient", "subject", "since"], booleans: ["read", "flagged"], integers: ["page", "page_size"]),
    MailToolSpec("message_read", "Read cached content without marking seen. id is opaque and scoped to account/mailbox. Missing cache fails.", strings: ["account", "mailbox", "id"], booleans: ["include_html"], required: ["id"]),
    MailToolSpec("attachment_list", "List cached MIME attachment metadata. Download/export is unsupported.", strings: ["account", "mailbox", "id"], required: ["id"]),
    MailToolSpec("message_draft", "Save a new draft without sending. account selects a configured alias with sender email.", strings: ["account", "subject", "body"], arrays: ["to", "cc", "bcc", "attachments"], required: ["subject", "body"]),
    MailToolSpec("message_send", "Preview a new email unless confirm=true. Confirm only after user approval. Success means queued, not delivered; never retry an uncertain outcome.", strings: ["account", "subject", "body"], arrays: ["to", "cc", "bcc", "attachments"], booleans: ["confirm"], required: ["to", "subject", "body"]),
    MailToolSpec("message_reply", "Preview a reply unless confirm=true. Confirm sends immediately. Preview does not save a draft.", strings: ["account", "mailbox", "id", "body"], booleans: ["confirm", "reply_all"], required: ["id", "body"]),
    MailToolSpec("message_forward", "Preview a forward unless confirm=true. Confirm sends immediately. Preview does not save a draft.", strings: ["account", "mailbox", "id", "body"], arrays: ["to"], booleans: ["confirm"], required: ["id", "to", "body"]),
    MailToolSpec("message_move", "Move within the selected account. target_mailbox uses the same URL/path selector as mailbox discovery.", strings: ["account", "mailbox", "id", "target_mailbox"], required: ["id", "target_mailbox"]),
    MailToolSpec("flag_add", "Set Seen and/or Flagged. Other flags fail before any action.", strings: ["account", "mailbox", "id"], arrays: ["flags"], required: ["id", "flags"]),
    MailToolSpec("flag_remove", "Clear Seen and/or Flagged. Other flags fail before any action.", strings: ["account", "mailbox", "id"], arrays: ["flags"], required: ["id", "flags"]),
]
let mailContractSpecs = mailSharedSpecs + himalayaSpecs
let mailContractDefinitions = mailDefinitions(mailContractSpecs)

func mailContractCLIArguments(tool: String, input: [String: Any]) throws -> [String] {
    _ = try mailCLIArguments(tool: tool, input: input, specs: mailContractSpecs)
    let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
    return ["mail", "api", tool, String(decoding: data, as: UTF8.self)]
}

private struct MailReference: Codable, Equatable {
    let row: Int64
    let messageID: String?
    let mailbox: String
    let document: String?
    let date: Double
    let subject: String
    let sender: String
    init(_ message: MailSummary, messageID: String?) {
        self.messageID = messageID
        row = message.rowid; mailbox = message.mailbox; document = message.documentID
        date = message.dateReceived; subject = message.subject; sender = message.sender
    }
    var token: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(self)
        return "am1." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ token: String) throws -> Self {
        guard token.hasPrefix("am1."), token.utf8.count <= 16384 else { throw MailInputError(message: "Invalid Mail v1 message id") }
        var encoded = String(token.dropFirst(4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let ref = try? JSONDecoder().decode(Self.self, from: data), ref.row > 0 else {
            throw MailInputError(message: "Invalid Mail v1 message id")
        }
        return ref
    }
}

struct MailAccountAlias: Codable {
    let id: String
    let email: String?
}

final class MailContract {
    typealias Action = (String, [String: String]) throws -> [String: Any]
    private let openDatabase: () throws -> MailDBConnection
    private let perform: Action
    private let environment: [String: String]

    init(database: @escaping () throws -> MailDBConnection = { try MailDBConnection() },
         environment: [String: String] = ProcessInfo.processInfo.environment,
         perform: @escaping Action = { try MailActions.perform($0, arguments: $1) }) {
        self.openDatabase = database; self.environment = environment; self.perform = perform
    }

    func execute(tool: String, input: [String: Any]) throws -> [String: Any] {
        _ = try mailContractCLIArguments(tool: tool, input: input)
        if himalayaToolNames.contains(tool) { return try HimalayaAdapter.execute(tool, input: input, contract: self) }
        guard let spec = mailSharedSpecs.first(where: { $0.name == tool }) else { throw MailInputError(message: "Unsupported Mail tool") }
        if spec.action == "capabilities" {
            return ["version": 1, "backend": "apple-mail", "tools": mailSharedSpecs.map(\.name),
                    "compatibility": ["project": "Data-Wise/himalaya-mcp", "version": "2.1.2", "commit": "cc6b9a7e9ed8eee2921d4ce0585a4b7c54852158", "tools": himalayaSpecs.map(\.name)],
                    "flags": ["Seen", "Flagged"], "search_scope": "metadata", "sort": "date_received_desc_rowid_desc",
                    "body_search": false, "attachment_download": false, "raw_mime_send": false,
                    "read_marks_seen": false, "send_requires_confirm": true, "id_lifetime": "local index; invalidated by move or reindex"]
        }
        let db = try openDatabase()
        let boxes = try db.mailboxes()
        let aliases = try accountAliases()
        let accounts = Array(Set(boxes.compactMap { URLComponents(string: $0.url)?.host })).sorted()
        if spec.action == "account_list" {
            return ["accounts": accounts.map { id in
                ["id": id, "aliases": aliases.keys.filter { aliases[$0]?.id == id }.sorted()] as [String: Any]
            }]
        }
        let account = try selectAccount(input["account"] as? String, accounts: accounts, aliases: aliases)
        let scopedBoxes = boxes.filter { URLComponents(string: $0.url)?.host == account }
        if spec.action == "mailbox_list" { return ["account": account, "mailboxes": scopedBoxes.map { ["id": $0.url, "name": Self.mailboxPath($0.url)] }] }

        if ["message_send", "message_draft"].contains(spec.action) {
            var values = actionValues(input)
            values["account"] = try sender(for: input["account"] as? String, id: account, aliases: aliases)
            let action = spec.action == "message_send" ? "send" : "draft"
            _ = try MailActions.buildScript(action: action, arguments: values)
            if action == "send", input["confirm"] as? Bool != true { return preview(action: action, input: input, account: account, sender: values["account"]) }
            return try perform(action, values)
        }

        let mailbox = try selectMailbox(input["mailbox"] as? String ?? "INBOX", boxes: scopedBoxes)
        if spec.action == "envelope_list" || spec.action == "envelope_search" {
            let page = (input["page"] as? NSNumber)?.intValue ?? 1
            let size = (input["page_size"] as? NSNumber)?.intValue ?? 25
            guard page <= 1_000_000, (1...200).contains(size) else { throw MailInputError(message: "page must be 1..1000000 and page_size 1..200") }
            var query = MailSearchQuery(sender: input["sender"] as? String, recipient: input["recipient"] as? String,
                                        subject: input["subject"] as? String, mailbox: mailbox.url, limit: size)
            query.offset = (page - 1) * size
            query.read = input["read"] as? Bool; query.flagged = input["flagged"] as? Bool
            if let value = input["since"] as? String { query.since = try Self.date(value).timeIntervalSince1970 }
            let messages = try db.search(query)
            // Probe the next row, preserving the requested page size even at the 200-row bound.
            query.offset += size; query.limit = 1
            let hasMore = !(try db.search(query)).isEmpty
            return ["account": account, "mailbox": mailbox.url, "envelopes": try messages.map { try envelope($0, db: db) },
                    "page": page, "page_size": size, "has_more": hasMore, "search_scope": "metadata"]
        }
        let reference = try MailReference.decode(input["id"] as! String)
        guard reference.mailbox == mailbox.url else { throw MailInputError(message: "Message id does not belong to the selected account/mailbox") }
        let summary = try db.message(rowid: reference.row)
        guard try MailReference(summary, messageID: db.messageIDHeader(rowid: summary.rowid)) == reference else { throw MailInputError(message: "Stale message id; list the mailbox again") }
        let parsed = try read(summary, db: db, html: input["include_html"] as? Bool ?? false)
        if spec.action == "message_read" || spec.action == "attachment_list" {
            let attachments: [[String: Any]] = parsed.attachments.enumerated().map { index, item in
                ["id": String(index + 1), "filename": item.filename as Any? ?? NSNull(), "content_type": item.contentType, "size": item.size]
            }
            if spec.action == "attachment_list" { return ["id": reference.token, "attachments": attachments, "download_supported": false] }
            var result = try envelope(summary, db: db)
            result["headers"] = parsed.headers; result["body"] = parsed.body
            result["html"] = parsed.html as Any? ?? NSNull(); result["attachments"] = attachments
            return result
        }
        guard let messageID = parsed.headers["message-id"], !messageID.isEmpty else { throw MailInputError(message: "Cached message has no RFC Message-ID; cannot target action") }
        var values = actionValues(input)
        values.removeValue(forKey: "account")
        if let email = try? sender(for: input["account"] as? String, id: account, aliases: aliases) { values["account"] = email }
        else { values["account_id"] = account }
        values["mailbox"] = Self.mailboxPath(mailbox.url)
        values["message_id"] = messageID; values["lookup_id"] = String(summary.rowid)
        let action: String
        switch spec.action {
        case "message_move":
            action = "move"
            let target = try selectMailbox(input["target_mailbox"] as! String, boxes: scopedBoxes)
            values["target_mailbox"] = Self.mailboxPath(target.url)
        case "flag_add", "flag_remove":
            action = "flag"
            let flags = input["flags"] as! [String]
            guard !flags.isEmpty, Set(flags).isSubset(of: ["Seen", "Flagged"]) else { throw MailInputError(message: "Unsupported flags; Apple Mail supports Seen and Flagged only") }
            for flag in flags { values[flag == "Seen" ? "read" : "flagged"] = spec.action == "flag_add" ? "true" : "false" }
        case "message_reply": action = "reply"
        case "message_forward": action = "forward"
        default: throw MailInputError(message: "Unsupported Mail operation")
        }
        _ = try MailActions.buildScript(action: action, arguments: values)
        if ["reply", "forward"].contains(action), input["confirm"] as? Bool != true {
            return preview(action: action, input: input, account: account)
        }
        return try perform(action, values)
    }

    private func accountAliases() throws -> [String: MailAccountAlias] {
        guard let json = environment["MACOS_MAIL_ACCOUNTS_JSON"] else { return [:] }
        guard let aliases = try? JSONDecoder().decode([String: MailAccountAlias].self, from: Data(json.utf8)),
              aliases.allSatisfy({ !$0.key.isEmpty && !$0.value.id.isEmpty }) else { throw MailInputError(message: "Invalid MACOS_MAIL_ACCOUNTS_JSON") }
        return aliases
    }
    private func selectAccount(_ selector: String?, accounts: [String], aliases: [String: MailAccountAlias]) throws -> String {
        if let selector {
            if accounts.contains(selector), let alias = aliases[selector], alias.id != selector { throw MailInputError(message: "Account alias conflicts with indexed account ID") }
            let id = aliases[selector]?.id ?? selector
            guard accounts.contains(id) else { throw MailInputError(message: "Unknown indexed account; use mail_account_list") }
            return id
        }
        guard accounts.count == 1 else { throw MailInputError(message: "Select an account explicitly; use mail_account_list") }
        return accounts[0]
    }
    private func sender(for selector: String?, id: String, aliases: [String: MailAccountAlias]) throws -> String {
        if let selector, let email = aliases[selector]?.email { return email }
        let emails = Set(aliases.values.filter { $0.id == id }.compactMap(\.email))
        guard emails.count == 1, let email = emails.first else { throw MailInputError(message: "Configure one sender email for this account in MACOS_MAIL_ACCOUNTS_JSON, or select an alias with email") }
        return email
    }
    private func selectMailbox(_ selector: String, boxes: [MailMailbox]) throws -> MailMailbox {
        let matches = boxes.filter { $0.url == selector || Self.mailboxPath($0.url) == selector }
        guard matches.count == 1, let box = matches.first else { throw MailInputError(message: "Mailbox missing or ambiguous in selected account; use mail_mailbox_list") }
        return box
    }
    private static func mailboxPath(_ url: String) -> String { URLComponents(string: url)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? url }
    private func read(_ summary: MailSummary, db: MailDBConnection, html: Bool) throws -> MailParsedMessage {
        let url = try db.messageFile(rowid: summary.rowid)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 * 1024 else { throw MailInputError(message: "Cached message exceeds 64 MiB") }
        return try MailParser.parse(Data(contentsOf: url), includeHTML: html)
    }
    private func envelope(_ message: MailSummary, db: MailDBConnection) throws -> [String: Any] {
        ["id": try MailReference(message, messageID: db.messageIDHeader(rowid: message.rowid)).token, "subject": message.subject, "from": ["addr": message.sender],
         "account": URLComponents(string: message.mailbox)?.host ?? "", "mailbox": message.mailbox,
         "date": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: message.dateReceived)),
         "flags": (message.read ? ["Seen"] : []) + (message.flagged ? ["Flagged"] : [])]
    }
    private func actionValues(_ input: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in input {
            if let strings = value as? [String] { result[key] = strings.joined(separator: "\n") }
            else if let string = value as? String { result[key] = string }
        }
        if let value = input["reply_all"] as? Bool { result["reply_all"] = value ? "true" : "false" }
        return result
    }
    private func preview(action: String, input: [String: Any], account: String, sender: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["status": "preview", "action": action, "sent": false, "account": account, "message": input]
        result["sender"] = sender
        return result
    }
    static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withFullDate]
        if value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value { return date }
        throw MailInputError(message: "Expected an ISO 8601 date")
    }
}
