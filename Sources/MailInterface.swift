import Foundation
import CoreFoundation

struct MailInputError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// A shared contract keeps MCP schemas, validation, and CLI translation together.
struct MailToolSpec {
    let action: String
    let toolName: String?
    let description: String
    let strings: [String]
    let arrays: [String]
    let booleans: [String]
    let integers: [String]
    let required: [String]
    init(_ action: String, _ description: String, strings: [String] = [], arrays: [String] = [],
         booleans: [String] = [], integers: [String] = [], required: [String] = [], name: String? = nil) {
        self.toolName = name
        self.action = action; self.description = description; self.strings = strings
        self.arrays = arrays; self.booleans = booleans; self.integers = integers; self.required = required
    }
    var name: String { toolName ?? (action == "mailboxes" ? "mail_list_mailboxes" : "mail_" + action) }
}

let mailToolSpecs = [
    MailToolSpec("search", "Search locally indexed subject and sender metadata. Body full-text search is not supported. Dates are ISO 8601; mailbox is an exact URL returned by mail_list_mailboxes.", strings: ["query", "sender", "recipient", "subject", "mailbox", "since"], integers: ["limit"]),
    MailToolSpec("read", "Read a locally cached message by rowid or RFC Message-ID. Exactly one identifier is required. Missing cache returns an error.", strings: ["message_id"], booleans: ["include_html"], integers: ["rowid"]),
    MailToolSpec("mailboxes", "List locally indexed mailbox URLs and their IDs."),
    MailToolSpec("send", "Send an email through Mail.app. Success means accepted for sending, not delivered. Never automatically retry an uncertain result.", strings: ["subject", "body", "account"], arrays: ["to", "cc", "bcc", "attachments"], required: ["to", "subject", "body"]),
    MailToolSpec("draft", "Save a draft in Mail.app without sending. Account selects a configured sender email address.", strings: ["subject", "body", "account"], arrays: ["to", "cc", "bcc", "attachments"], required: ["subject", "body"]),
    MailToolSpec("reply", "Send a reply to an existing message, optionally to all recipients. Supply exactly one of rowid or RFC message_id; RFC message_id requires mailbox scope; account can disambiguate.", strings: ["message_id", "body", "account", "mailbox"], booleans: ["reply_all"], integers: ["rowid"], required: ["body"]),
    MailToolSpec("forward", "Forward and send an existing message to recipients. Supply exactly one of rowid or RFC message_id. RFC message_id requires mailbox scope.", strings: ["message_id", "body", "account", "mailbox"], arrays: ["to"], integers: ["rowid"], required: ["to", "body"]),
    MailToolSpec("move", "Move a message through Mail.app. target_mailbox is a mailbox path, not a database ID. Ambiguous matches fail.", strings: ["message_id", "target_mailbox", "account", "mailbox"], integers: ["rowid"], required: ["target_mailbox"]),
    MailToolSpec("flag", "Set read and/or flagged status through Mail.app. Supply exactly one of rowid or RFC message_id. RFC message_id requires mailbox scope.", strings: ["message_id", "account", "mailbox"], booleans: ["read", "flagged"], integers: ["rowid"]),
]

let mailToolDefinitions = mailDefinitions(mailToolSpecs)

func mailDefinitions(_ specs: [MailToolSpec]) -> [[String: Any]] { specs.map { spec in
    var properties: [String: Any] = [:]
    for key in spec.strings { properties[key] = ["type": "string"] }
    for key in spec.arrays { properties[key] = ["type": "array", "items": ["type": "string", "minLength": 1], "minItems": spec.required.contains(key) ? 1 : 0] }
    for key in spec.booleans { properties[key] = ["type": "boolean"] }
    for key in spec.integers {
        properties[key] = ["limit", "page_size"].contains(key) ? ["type": "integer", "minimum": 1, "maximum": 200] : ["type": "integer", "minimum": 1]
    }
    if spec.integers.contains("page") { properties["page"] = ["type": "integer", "minimum": 1, "maximum": 1_000_000] }
    var schema: [String: Any] = ["type": "object", "properties": properties, "required": spec.required, "additionalProperties": false]
    if spec.integers.contains("rowid") { schema["oneOf"] = [["required": ["rowid"], "not": ["required": ["message_id"]]], ["required": ["message_id"], "not": ["required": ["rowid"]]]] }
    if spec.action != "read", spec.integers.contains("rowid") {
        schema["allOf"] = [["if": ["required": ["message_id"]], "then": ["required": ["mailbox"]]]]
    }
    return ["name": spec.name, "description": spec.description, "inputSchema": schema]
}

}

func mailCLIArguments(tool: String, input: [String: Any], specs: [MailToolSpec] = mailToolSpecs) throws -> [String] {
    guard let spec = specs.first(where: { $0.name == tool }) else { throw MailInputError(message: "Unknown Mail tool") }
    let allowed = Set(spec.strings + spec.arrays + spec.booleans + spec.integers)
    guard Set(input.keys).isSubset(of: allowed) else { throw MailInputError(message: "Unknown parameter for \(tool)") }
    for key in spec.required where input[key] == nil { throw MailInputError(message: "\(key) is required") }
    if spec.integers.contains("rowid") {
        guard (input["rowid"] != nil) != (input["message_id"] != nil) else { throw MailInputError(message: "Supply exactly one of rowid or message_id") }
    }
    if spec.action != "read", spec.integers.contains("rowid"), input["message_id"] != nil {
        guard let mailbox = input["mailbox"] as? String, !mailbox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailInputError(message: "message_id actions require mailbox scope") }
    }
    if spec.name == "mail_flag", input["read"] == nil && input["flagged"] == nil { throw MailInputError(message: "Supply read and/or flagged") }
    var args = ["mail", spec.action]
    for key in input.keys.sorted() {
        let flag = "--" + key.replacingOccurrences(of: "_", with: "-")
        if spec.strings.contains(key) {
            guard let value = input[key] as? String, !value.contains("\0") else { throw MailInputError(message: "\(key) must be a string without NUL bytes") }
            if key == "message_id", value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw MailInputError(message: "message_id must not be empty") }
            args += [flag, value]
        } else if spec.arrays.contains(key) {
            guard let values = input[key] as? [String], (!spec.required.contains(key) || !values.isEmpty), values.allSatisfy({ !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0") }) else { throw MailInputError(message: "\(key) must be an array of nonempty single-line strings") }
            for value in values { args += [flag, value] }
        } else if spec.booleans.contains(key) {
            guard let value = input[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw MailInputError(message: "\(key) must be a boolean") }
            args += [flag, value.boolValue ? "true" : "false"]
        } else {
            guard let value = input[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  let integer = Int64(value.stringValue), integer > 0,
                  (!["limit", "page_size"].contains(key) || integer <= 200),
                  (key != "page" || integer <= 1_000_000) else { throw MailInputError(message: "\(key) must be a positive integer\(key == "limit" ? " at most 200" : "")") }
            args += [flag, String(integer)]
        }
    }
    return args
}
