import Foundation

/// Mutating Apple Mail operations.  Mail's database is intentionally never
/// written directly: Mail.app owns synchronization with the remote provider.
public enum MailActions {
    public struct RunResult {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public let timedOut: Bool

        public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0, timedOut: Bool = false) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
            self.timedOut = timedOut
        }
    }

    public typealias Runner = (_ script: String, _ timeout: TimeInterval) -> RunResult

    public enum Error: Swift.Error, LocalizedError, Equatable {
        case unsupportedAction(String)
        case missingArgument(String)
        case invalidArgument(String)
        case invalidRecipients(String)
        case missingMessageScope
        case unknownResult(action: String, detail: String)
        case failed(action: String, detail: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedAction(let action): return "Unsupported Mail action: \(action)"
            case .missingArgument(let name): return "Mail action requires \(name)"
            case .invalidArgument(let detail), .invalidRecipients(let detail): return detail
            case .missingMessageScope: return "Message actions require mailbox scope; provide mailbox and an optional account to disambiguate it"
            case .unknownResult(let action, let detail): return "Mail \(action) has an unknown result; do not retry automatically: \(detail)"
            case .failed(let action, let detail): return "Mail \(action) failed: \(detail)"
            }
        }
    }

    /// Performs an action using a bounded `/usr/bin/osascript` subprocess.
    /// A successful send only means Mail accepted the message for its outbox;
    /// it does not claim remote delivery.
    public static func perform(_ action: String, arguments: [String: String]) throws -> [String: Any] {
        try perform(action, arguments: arguments, runner: runOsaScript)
    }

    /// Dependency-injection entry point for tests.  It is also useful to hosts
    /// which need to centralize process execution.
    public static func perform(
        _ action: String,
        arguments: [String: String],
        runner: Runner,
        timeout: TimeInterval = 12
    ) throws -> [String: Any] {
        let normalizedAction = try normalize(action)
        let normalizedArguments = try validate(arguments, for: normalizedAction, checkAttachmentFiles: true)
        let result = runner(try buildScript(action: normalizedAction, arguments: normalizedArguments), timeout)

        if result.timedOut {
            // `send` may already have reached Mail when osascript times out.
            // Treat every timeout as unknown, rather than encouraging a retry.
            throw Error.unknownResult(action: normalizedAction, detail: "osascript timed out after \(Int(timeout))s")
        }
        guard result.exitCode == 0 else {
            let detail = firstNonEmpty(result.stderr, result.stdout, "osascript exited \(result.exitCode)")
            if ["send", "reply", "forward", "draft"].contains(normalizedAction) {
                throw Error.unknownResult(action: normalizedAction, detail: detail)
            }
            throw Error.failed(action: normalizedAction, detail: detail)
        }

        let expectedToken: String = normalizedAction == "draft" ? "draft_saved" : normalizedAction == "send" || normalizedAction == "reply" || normalizedAction == "forward" ? "queued" : "completed"
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output == expectedToken else {
            let detail = firstNonEmpty(result.stderr, result.stdout, "osascript returned an unexpected success result")
            if ["send", "reply", "forward", "draft"].contains(normalizedAction) {
                throw Error.unknownResult(action: normalizedAction, detail: detail)
            }
            throw Error.failed(action: normalizedAction, detail: detail)
        }

        switch normalizedAction {
        case "send", "reply", "forward":
            return ["action": normalizedAction, "status": "queued", "delivered": false]
        case "draft":
            return ["action": normalizedAction, "status": "draft_saved"]
        default:
            return ["action": normalizedAction, "status": "completed"]
        }
    }

    /// Builds a complete, compilable AppleScript without running it.  Inputs
    /// are emitted only as escaped AppleScript string literals.
    public static func buildScript(action: String, arguments: [String: String]) throws -> String {
        let normalizedAction = try normalize(action)
        let values = try validate(arguments, for: normalizedAction, checkAttachmentFiles: false)
        switch normalizedAction {
        case "send", "draft": return composeScript(action: normalizedAction, values: values)
        case "reply": return replyScript(values: values)
        case "forward": return forwardScript(values: values)
        case "move": return moveScript(values: values)
        case "flag", "mark_read": return flagScript(values: values)
        default: throw Error.unsupportedAction(action)
        }
    }

    private static func normalize(_ action: String) throws -> String {
        let value = action.lowercased().replacingOccurrences(of: "-", with: "_")
        switch value {
        case "send", "draft", "reply", "forward", "move", "flag", "mark_read": return value
        default: throw Error.unsupportedAction(action)
        }
    }

    private static func validate(_ arguments: [String: String], for action: String, checkAttachmentFiles: Bool) throws -> [String: String] {
        for (key, value) in arguments where value.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw Error.invalidArgument("\(key) must not contain a NUL character")
        }
        var values = arguments
        switch action {
        case "send", "draft":
            if action == "send" {
                let to = try required("to", in: values)
                try validateRecipients(to, field: "to")
            } else if let to = values["to"], !to.isEmpty {
                try validateRecipients(to, field: "to")
            }
            if let cc = values["cc"], !cc.isEmpty { try validateRecipients(cc, field: "cc") }
            if let bcc = values["bcc"], !bcc.isEmpty { try validateRecipients(bcc, field: "bcc") }
            _ = try required("subject", in: values)
            _ = try required("body", in: values)
            if let sender = values["account"], !sender.isEmpty { try validateEmail(sender, field: "account") }
        case "forward":
            try validateMessageScope(values)
            let to = try required("to", in: values)
            try validateRecipients(to, field: "to")
        case "reply":
            try validateMessageScope(values)
            if let replyAll = values["reply_all"] { _ = try bool(replyAll, field: "reply_all") }
        case "move":
            try validateMessageScope(values)
            _ = try required("target_mailbox", in: values)
        case "flag", "mark_read":
            try validateMessageScope(values)
            if action == "flag", values["flagged"] == nil, values["read"] == nil {
                throw Error.missingArgument("flagged or read")
            }
            if let flagged = values["flagged"] { _ = try bool(flagged, field: "flagged") }
            if let read = values["read"] { _ = try bool(read, field: "read") }
            if action == "mark_read", values["read"] == nil { values["read"] = "true" }
        default: break
        }

        // `account` is an email selector, not Mail's numeric id or a database
        // rowid.  Mail validates it against each account's `email addresses`.
        if let account = values["account"], !account.isEmpty, action != "send", action != "draft" {
            try validateEmail(account, field: "account")
        }
        if let accountID = values["account_id"], accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Error.invalidArgument("account_id must not be empty")
        }
        if let targetAccount = values["target_account"], !targetAccount.isEmpty {
            try validateEmail(targetAccount, field: "target_account")
        }
        if let targetAccountID = values["target_account_id"], targetAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Error.invalidArgument("target_account_id must not be empty")
        }

        if let attachments = values["attachments"], !attachments.isEmpty {
            let paths = newlineValues(attachments)
            guard !paths.isEmpty else { throw Error.invalidArgument("attachments must contain at least one path") }
            let normalized = try paths.map { path -> String in
                let absolute = absolutePath(path)
                if checkAttachmentFiles {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: absolute)
                    let isRegularFile = attributes?[.type] as? FileAttributeType == .typeRegular
                    guard isRegularFile, FileManager.default.isReadableFile(atPath: absolute) else {
                        throw Error.invalidArgument("Attachment must be a readable regular file: \(absolute)")
                    }
                }
                return absolute
            }
            values["attachments"] = normalized.joined(separator: "\n")
        }
        return values
    }

    private static func validateMessageScope(_ values: [String: String]) throws {
        let messageID = try required("message_id", in: values)
        guard !messageID.contains("\n"), !messageID.contains("\r") else {
            throw Error.invalidArgument("message_id must be a single-line RFC Message-ID")
        }
        guard let mailbox = values["mailbox"], !mailbox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.missingMessageScope
        }
    }

    private static func composeScript(action: String, values: [String: String]) -> String {
        let recipients = recipientLines(values)
        let sender = values["account"].flatMap { $0.isEmpty ? nil : $0 }
        let senderSetup: String
        if let sender {
            senderSetup = """
                set matchingAccounts to every account whose email addresses contains \(asString(sender))
                if (count of matchingAccounts) is not 1 then error "No unique Mail account has that sender email address"
                set sender of newMessage to \(asString(sender))
            """
        } else {
            senderSetup = ""
        }
        let attachments = newlineValues(values["attachments"] ?? "").map { path in
            "make new attachment with properties {file name:(POSIX file \(asString(path)))} at after the last paragraph"
        }.joined(separator: "\n        ")
        let terminal = action == "send" ? "if not (send newMessage) then error \"Mail declined to queue the message\"\n    return \"queued\"" : "save newMessage\n    return \"draft_saved\""
        return """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:\(asString(values["subject"] ?? "")), content:\(asString(values["body"] ?? "")) & return & return, visible:false}
            \(senderSetup)
            tell newMessage
                \(recipients)
                \(attachments)
            end tell
            \(terminal)
        end tell
        """
    }

    private static func replyScript(values: [String: String]) -> String {
        let body = values["body"] ?? ""
        let replyAll = (try? bool(values["reply_all"] ?? "false", field: "reply_all")) ?? false
        return """
        tell application "Mail"
            \(messageLookup(values))
            set outgoingMessage to reply targetMessage opening window false reply to all \(replyAll ? "true" : "false")
            set content of outgoingMessage to \(asString(body)) & return & return & content of outgoingMessage
            if not (send outgoingMessage) then error "Mail declined to queue the reply"
            return "queued"
        end tell
        """
    }

    private static func forwardScript(values: [String: String]) -> String {
        let body = values["body"] ?? ""
        let recipients = recipientLines(["to": values["to"] ?? ""])
        return """
        tell application "Mail"
            \(messageLookup(values))
            set outgoingMessage to forward targetMessage opening window false
            tell outgoingMessage
                \(recipients)
                set content to \(asString(body)) & return & return & content
            end tell
            if not (send outgoingMessage) then error "Mail declined to queue the forward"
            return "queued"
        end tell
        """
    }

    private static func moveScript(values: [String: String]) -> String {
        return """
        tell application "Mail"
            \(messageLookup(values))
            \(mailboxLookup(name: values["target_mailbox"] ?? "", account: values["target_account"] ?? values["account"], accountID: values["target_account_id"] ?? values["account_id"], result: "targetMailbox"))
            move targetMessage to targetMailbox
            return "completed"
        end tell
        """
    }

    private static func flagScript(values: [String: String]) -> String {
        var changes: [String] = []
        if let flagged = values["flagged"], let value = try? bool(flagged, field: "flagged") { changes.append("set flagged status of targetMessage to \(value ? "true" : "false")") }
        if let read = values["read"], let value = try? bool(read, field: "read") { changes.append("set read status of targetMessage to \(value ? "true" : "false")") }
        return """
        tell application "Mail"
            \(messageLookup(values))
            \(changes.joined(separator: "\n    "))
            return "completed"
        end tell
        """
    }

    /// Resolves by RFC Message-ID only.  AppleScript `id` is a distinct,
    /// implementation-specific integer and must never receive a DB rowid.
    private static func messageLookup(_ values: [String: String]) -> String {
        let rawMessageID = values["message_id"] ?? ""
        let normalizedMessageID = messageIDWithoutBrackets(rawMessageID)
        let bracketedMessageID = "<\(normalizedMessageID)>"
        return """
        \(mailboxLookup(name: values["mailbox"] ?? "", account: values["account"], accountID: values["account_id"], result: "sourceMailbox"))
        set originalMessageID to \(asString(bracketedMessageID))
        set normalizedMessageID to \(asString(normalizedMessageID))
        set matchingMessages to every message of sourceMailbox whose (message id is normalizedMessageID or message id is originalMessageID)
        if (count of matchingMessages) is 0 then error "No message matches message_id in the scoped mailbox"
        if (count of matchingMessages) is not 1 then error "message_id is ambiguous in the scoped mailbox"
        set targetMessage to item 1 of matchingMessages
        """
    }

    private static func mailboxLookup(name: String, account: String?, accountID: String? = nil, result: String) -> String {
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // Validation has already required a nonempty mailbox.  Empty path
        // components are rejected here as well so generated scripts never
        // reinterpret a malformed path.
        guard !components.isEmpty, !components.contains(where: { $0.isEmpty }) else {
            return "error \"Mailbox must be a non-empty slash-delimited path\""
        }
        let first = components[0]
        let descendants = components.dropFirst().map { component in
            """
            set matchingMailboxes to every mailbox of currentMailbox whose name is \(asString(component))
            if (count of matchingMailboxes) is 0 then error "No mailbox matches the supplied path"
            if (count of matchingMailboxes) is not 1 then error "Mailbox path is ambiguous"
            set currentMailbox to item 1 of matchingMailboxes
            """
        }.joined(separator: "\n        ")
        if let accountID, !accountID.isEmpty {
            return """
            set matchingAccounts to every account whose id is \(asString(accountID))
            if (count of matchingAccounts) is not 1 then error "No Mail account matches account_id; provide explicit account email instead"
            set scopedAccount to item 1 of matchingAccounts
            set matchingMailboxes to every mailbox of scopedAccount whose name is \(asString(first))
            if (count of matchingMailboxes) is 0 then error "No mailbox matches the supplied name and account scope"
            if (count of matchingMailboxes) is not 1 then error "Mailbox scope is ambiguous"
            set currentMailbox to item 1 of matchingMailboxes
            \(descendants)
            set \(result) to currentMailbox
            """
        }
        if let account, !account.isEmpty {
            return """
            set matchingAccounts to every account whose email addresses contains \(asString(account))
            if (count of matchingAccounts) is not 1 then error "No unique Mail account matches the supplied account scope"
            set scopedAccount to item 1 of matchingAccounts
            set matchingMailboxes to every mailbox of scopedAccount whose name is \(asString(first))
            if (count of matchingMailboxes) is 0 then error "No mailbox matches the supplied name and account scope"
            if (count of matchingMailboxes) is not 1 then error "Mailbox scope is ambiguous"
            set currentMailbox to item 1 of matchingMailboxes
            \(descendants)
            set \(result) to currentMailbox
            """
        }
        return """
        set matchingMailboxes to {}
        repeat with candidateAccount in every account
            set accountMailboxes to every mailbox of candidateAccount whose name is \(asString(first))
            repeat with candidateMailbox in accountMailboxes
                set end of matchingMailboxes to candidateMailbox
            end repeat
        end repeat
        set localMailboxes to every mailbox whose name is \(asString(first))
        repeat with candidateMailbox in localMailboxes
            set end of matchingMailboxes to candidateMailbox
        end repeat
        if (count of matchingMailboxes) is 0 then error "No mailbox matches the supplied name"
        if (count of matchingMailboxes) is not 1 then error "Mailbox scope is ambiguous; provide account"
        set currentMailbox to item 1 of matchingMailboxes
        \(descendants)
        set \(result) to currentMailbox
        """
    }

    private static func recipientLines(_ values: [String: String]) -> String {
        [("to", "to recipient", "to recipients"), ("cc", "cc recipient", "cc recipients"), ("bcc", "bcc recipient", "bcc recipients")]
            .flatMap { key, kind, collection in
                newlineValues(values[key] ?? "").map { address in
                    "make new \(kind) at end of \(collection) with properties {address:\(asString(address))}"
                }
            }
            .joined(separator: "\n        ")
    }

    private static func required(_ name: String, in values: [String: String]) throws -> String {
        guard let value = values[name], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Error.missingArgument(name) }
        return value
    }

    private static func newlineValues(_ value: String) -> [String] {
        value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func validateRecipients(_ value: String, field: String) throws {
        let recipients = newlineValues(value)
        guard !recipients.isEmpty else { throw Error.invalidRecipients("\(field) must contain at least one email address") }
        for recipient in recipients { try validateEmail(recipient, field: field) }
    }

    private static func validateEmail(_ value: String, field: String) throws {
        let pattern = "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$"
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw Error.invalidRecipients("\(field) contains an invalid email address: \(value)")
        }
    }

    private static func bool(_ value: String, field: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: throw Error.invalidArgument("\(field) must be true or false")
        }
    }

    private static func absolutePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    }

    private static func messageIDWithoutBrackets(_ value: String) -> String {
        guard value.count >= 2, value.first == "<", value.last == ">" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func asString(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            .joined(separator: " & return & ")
    }

    private static func firstNonEmpty(_ values: String...) -> String { values.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "Unknown osascript failure" }

    private static func runOsaScript(script: String, timeout: TimeInterval) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return RunResult(stderr: error.localizedDescription, exitCode: 1) }
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); completed.signal() }
        guard completed.wait(timeout: .now() + timeout) != .timedOut else {
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return RunResult(stderr: "osascript timed out", exitCode: 1, timedOut: true)
        }
        return RunResult(
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }
}
