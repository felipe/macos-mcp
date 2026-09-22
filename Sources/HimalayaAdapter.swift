import Foundation

// Inputs and text results follow Data-Wise/himalaya-mcp 2.1.2 at the pinned
// commit in mail_capabilities. This is deliberately a subset, not a CLI shim.
let himalayaSpecs: [MailToolSpec] = [
    MailToolSpec("list", "Himalaya subset: list cached envelopes. folder defaults to INBOX. page starts at 1; page_size is 1..200. account is an indexed ID or configured alias.", strings: ["folder", "account"], integers: ["page_size", "page"], name: "list_emails"),
    MailToolSpec("search", "Himalaya metadata subset: bare subject word, or from/to/subject/flag clauses joined by and; optional order by date desc. Escape spaces with backslash or quotes. Body, date filters, or/not and other sorts are unsupported.", strings: ["query", "folder", "account"], required: ["query"], name: "search_emails"),
    MailToolSpec("read", "Read cached plain text without changing Seen. Use the opaque id from list_emails with the same folder/account.", strings: ["id", "folder", "account"], required: ["id"], name: "read_email"),
    MailToolSpec("read_html", "Read cached HTML without changing Seen. Empty if no HTML body exists.", strings: ["id", "folder", "account"], required: ["id"], name: "read_email_html"),
    MailToolSpec("folders", "List locally indexed folders for an account.", strings: ["account"], name: "list_folders"),
    MailToolSpec("flag", "Himalaya subset: add/remove Seen and Flagged only. Other flags fail without mutation.", strings: ["id", "action", "folder", "account"], arrays: ["flags"], required: ["id", "flags", "action"], name: "flag_email"),
    MailToolSpec("move", "Move an email between indexed folders within the same account.", strings: ["id", "target_folder", "folder", "account"], required: ["id", "target_folder"], name: "move_email"),
    MailToolSpec("compose", "Preview a new plain-text email unless confirm=true. account must resolve to a configured sender. Success means queued, not delivered.", strings: ["to", "subject", "body", "cc", "bcc", "account"], arrays: ["attachments"], booleans: ["confirm"], required: ["to", "subject", "body"], name: "compose_email"),
]
let himalayaToolNames = Set(himalayaSpecs.map(\.name))

enum HimalayaAdapter {
    static func execute(_ tool: String, input: [String: Any], contract: MailContract) throws -> [String: Any] {
        var args = input
        if let folder = args.removeValue(forKey: "folder") { args["mailbox"] = folder }
        let target: String
        switch tool {
        case "list_emails": target = "mail_envelope_list"
        case "search_emails":
            target = "mail_envelope_search"
            let query = args.removeValue(forKey: "query") as! String
            for (key, value) in try searchFilters(query) { args[key] = value }
        case "read_email", "read_email_html":
            target = "mail_message_read"; args["include_html"] = tool == "read_email_html"
        case "list_folders": target = "mail_mailbox_list"
        case "flag_email":
            let action = args.removeValue(forKey: "action") as! String
            guard ["add", "remove"].contains(action) else { throw MailInputError(message: "action must be add or remove") }
            target = action == "add" ? "mail_flag_add" : "mail_flag_remove"
        case "move_email":
            target = "mail_message_move"; args["target_mailbox"] = args.removeValue(forKey: "target_folder")
        case "compose_email":
            target = "mail_message_send"
            for key in ["to", "cc", "bcc"] {
                if let value = args[key] as? String { args[key] = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            }
        default: throw MailInputError(message: "Unsupported Himalaya tool")
        }
        let result = try contract.execute(tool: target, input: args)
        let text: String
        switch tool {
        case "list_emails", "search_emails":
            let envelopes = result["envelopes"] as! [[String: Any]]
            let lines = envelopes.map { item -> String in
                let flags = item["flags"] as! [String]
                let sender = (item["from"] as! [String: String])["addr"]!
                let suffix = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
                return "\(item["id"]!) | \(item["date"]!) | \(sender) | \(item["subject"]!)\(suffix)"
            }.joined(separator: "\n")
            if tool == "list_emails" { text = "Found \(envelopes.count) emails:\n\n\(lines)" }
            else if envelopes.isEmpty { text = "No emails found matching \"\(input["query"]!)\"" }
            else { text = "Found \(envelopes.count) emails matching \"\(input["query"]!)\":\n\n\(lines)" }
        case "read_email", "read_email_html":
            let body = result[tool == "read_email" ? "body" : "html"] as? String ?? ""
            text = body.isEmpty ? "(empty message body)" : body
        case "list_folders":
            let boxes = result["mailboxes"] as! [[String: String]]
            text = boxes.isEmpty ? "No folders found." : boxes.map { "- \($0["name"]!)" }.joined(separator: "\n")
        case "flag_email":
            text = "\(input["action"] as? String == "add" ? "Added" : "Removed") flags [\((input["flags"] as! [String]).joined(separator: ", "))] on email \(input["id"]!)"
        case "move_email": text = "Moved email \(input["id"]!) to \(input["target_folder"]!)"
        case "compose_email":
            if result["status"] as? String == "preview" {
                var headers = ["From: \(result["sender"]!)", "To: \(input["to"]!)"]
                for key in ["cc", "bcc"] { if let value = input[key] as? String { headers.append("\(key.uppercased()): \(value)") } }
                headers.append("Subject: \(input["subject"]!)")
                let attachments = (input["attachments"] as? [String] ?? []).map { "Attachment: \($0)" }.joined(separator: "\n")
                text = "--- EMAIL PREVIEW (not sent) ---\n\n" + headers.joined(separator: "\n") + "\n\n\(input["body"]!)\n\(attachments)\n--- END PREVIEW ---\n\nThis email has NOT been sent. To send, call compose_email again with confirm=true. Ask the user to confirm before sending."
            } else { text = "Email queued for sending to \(input["to"]!). Delivery is not confirmed." }
        default: throw MailInputError(message: "Unsupported Himalaya result")
        }
        return ["text": text]
    }

    static func searchFilters(_ query: String) throws -> [String: Any] {
        var tokens = try tokenize(query)
        if tokens.count >= 4, Array(tokens.suffix(4)) == ["order", "by", "date", "desc"] { tokens.removeLast(4) }
        if tokens.isEmpty { throw MailInputError(message: "Search query is empty") }
        let fields = ["from": "sender", "to": "recipient", "subject": "subject", "flag": "flag"]
        let reserved = Set(["from", "to", "subject", "flag", "body", "date", "before", "after", "and", "or", "not", "order"])
        if tokens.count == 1, !reserved.contains(tokens[0]) { return ["subject": tokens[0]] }
        var result: [String: Any] = [:]
        var index = 0
        while index < tokens.count {
            guard index + 1 < tokens.count, let field = fields[tokens[index]] else { throw MailInputError(message: "Unsupported search clause; supported: from, to, subject, flag joined by and; order by date desc") }
            let value = tokens[index + 1]
            let key: String
            if field == "flag" {
                guard ["Seen", "Flagged"].contains(value) else { throw MailInputError(message: "Unsupported search flag; use Seen or Flagged") }
                key = value == "Seen" ? "read" : "flagged"
            } else { key = field }
            guard result[key] == nil, !value.isEmpty else { throw MailInputError(message: "Repeated search field or empty value is unsupported") }
            if field == "flag" { result[key] = true } else { result[key] = value }
            index += 2
            if index < tokens.count {
                guard tokens[index] == "and", index + 1 < tokens.count else { throw MailInputError(message: "Only explicit and conjunctions are supported") }
                index += 1
            }
        }
        return result
    }

    private static func tokenize(_ query: String) throws -> [String] {
        var tokens: [String] = [], current = ""
        var quote: Character?, escaped = false
        for char in query {
            if escaped { current.append(char); escaped = false }
            else if char == "\\" { escaped = true }
            else if let delimiter = quote {
                if char == delimiter { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" { quote = char }
            else if char.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else { current.append(char) }
        }
        guard !escaped, quote == nil else { throw MailInputError(message: "Unterminated quote or escape in search query") }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
