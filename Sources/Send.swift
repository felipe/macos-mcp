import Foundation

// MARK: - AppleScript Helpers

/// Run AppleScript via osascript subprocess (used for Messages.app commands
/// that don't require Accessibility).
private func runAppleScript(_ script: String) -> (output: String, exitCode: Int32) {
    let result = runProcess("/usr/bin/osascript", arguments: ["-e", script])
    let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.exitCode != 0 {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return (err.isEmpty ? output : err, result.exitCode)
    }
    return (output, 0)
}

/// Run AppleScript in-process via NSAppleScript so the macos-mcp binary's
/// own Accessibility TCC grant applies (required for System Events keystrokes).
private func runAppleScriptInProcess(_ script: String) -> (output: String, exitCode: Int32) {
    guard let appleScript = NSAppleScript(source: script) else {
        return ("Failed to compile AppleScript", 1)
    }
    var errorInfo: NSDictionary?
    let result = appleScript.executeAndReturnError(&errorInfo)
    if let error = errorInfo {
        let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        return (msg, 1)
    }
    return (result.stringValue ?? "", 0)
}

// MARK: - Send Message

private func sendMessage(contact: String, text: String) {
    let contactEsc = escapeForAppleScript(contact)
    let messageEsc = escapeForAppleScript(text)

    let script = """
    tell application "Messages"
        try
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant "\(contactEsc)" of targetService
            send "\(messageEsc)" to targetBuddy
            return "sent"
        on error errMsg
            try
                set targetService to 1st account whose service type = SMS
                set targetBuddy to participant "\(contactEsc)" of targetService
                send "\(messageEsc)" to targetBuddy
                return "sent_sms"
            on error errMsg2
                return "error:" & errMsg2
            end try
        end try
    end tell
    """

    let (output, exitCode) = runAppleScript(script)
    if exitCode != 0 || output.hasPrefix("error:") {
        exitWithError("Failed to send message: \(output)")
    }

    let method = output == "sent_sms" ? "SMS" : "iMessage"
    printJSON(["sent": true, "contact": contact, "method": method])
}

// MARK: - Send to Chat

private func sendToChat(chatId: String, text: String) {
    let chatIdEsc = escapeForAppleScript(chatId)
    let messageEsc = escapeForAppleScript(text)

    let script = """
    tell application "Messages"
        try
            set targetService to 1st account whose service type = iMessage
            set targetChat to a reference to text chat id "\(chatIdEsc)" of targetService
            send "\(messageEsc)" to targetChat
            return "sent"
        on error errMsg
            return "error:" & errMsg
        end try
    end tell
    """

    let (output, exitCode) = runAppleScript(script)
    if exitCode != 0 || output.hasPrefix("error:") {
        exitWithError("Failed to send to chat: \(output)")
    }

    printJSON(["sent": true, "chat": chatId])
}

// MARK: - Send File

private func sendFile(contact: String, filePath: String) {
    let fm = FileManager.default

    // Resolve to absolute path
    let absPath: String
    if filePath.hasPrefix("/") {
        absPath = filePath
    } else if filePath.hasPrefix("~") {
        absPath = NSString(string: filePath).expandingTildeInPath
    } else {
        absPath = fm.currentDirectoryPath + "/" + filePath
    }

    guard fm.fileExists(atPath: absPath) else {
        exitWithError("File not found: \(absPath)")
    }

    // Stage file into Messages sandbox to avoid error 25
    let stagingDir = NSString("~/Library/Messages/Attachments/_outgoing").expandingTildeInPath
    try? fm.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)

    let ext = (absPath as NSString).pathExtension
    let tmpName = "staged-\(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)")
    let stagedPath = (stagingDir as NSString).appendingPathComponent(tmpName)

    do {
        try fm.copyItem(atPath: absPath, toPath: stagedPath)
    } catch {
        exitWithError("Failed to stage file: \(error.localizedDescription)")
    }

    let stagedEsc = escapeForAppleScript(stagedPath)
    let contactEsc = escapeForAppleScript(contact)

    let script = """
    set fileToSend to POSIX file "\(stagedEsc)"
    tell application "Messages"
        set targetService to 1st account whose service type = iMessage
        set targetBuddy to participant "\(contactEsc)" of targetService
        send fileToSend to targetBuddy
    end tell
    """

    let (output, exitCode) = runAppleScript(script)
    if exitCode != 0 {
        try? fm.removeItem(atPath: stagedPath)
        exitWithError("Failed to send file: \(output)")
    }

    printJSON(["sent": true, "contact": contact, "file": absPath])
}

// MARK: - Typing Indicator

func runTyping(args: [String]) {
    guard args.count >= 2 else {
        exitWithError("typing requires: <contact> <start|stop|keepalive>")
    }

    let contact = args[0]
    let action = args[1]

    switch action {
    case "start":
        // Open conversation and type a space to trigger indicator
        let script = """
        open location "imessage://" & "\(escapeForAppleScript(contact))"
        delay 0.5
        tell application "System Events"
            tell process "Messages"
                keystroke " "
            end tell
        end tell
        """
        let (output, exitCode) = runAppleScriptInProcess(script)
        if exitCode != 0 {
            exitWithError("Failed to start typing indicator: \(output)")
        }
        printJSON(["typing": "started", "contact": contact])

    case "stop":
        // Clear the input field
        let script = """
        tell application "System Events"
            tell process "Messages"
                keystroke "a" using command down
                delay 0.1
                key code 51
            end tell
        end tell
        """
        let (output, exitCode) = runAppleScriptInProcess(script)
        if exitCode != 0 {
            exitWithError("Failed to stop typing indicator: \(output)")
        }
        printJSON(["typing": "stopped", "contact": contact])

    case "keepalive":
        // Delete space and re-type to refresh the ~60s timeout
        let script = """
        tell application "System Events"
            tell process "Messages"
                key code 51
                delay 0.1
                keystroke " "
            end tell
        end tell
        """
        let (output, exitCode) = runAppleScriptInProcess(script)
        if exitCode != 0 {
            exitWithError("Failed to refresh typing indicator: \(output)")
        }
        printJSON(["typing": "keepalive", "contact": contact])

    default:
        exitWithError("Unknown typing action: \(action). Use start, stop, or keepalive.")
    }
}

// MARK: - Send Entry Point

func runSend(subcommand: String, args: [String]) {
    switch subcommand {
    case "message":
        guard !args.isEmpty else {
            exitWithError("send message requires: <contact> [text]")
        }
        let contact = args[0]
        let text: String
        if args.count >= 2 {
            text = args[1...].joined(separator: " ")
        } else {
            // Read from stdin
            var lines: [String] = []
            while let line = readLine() {
                lines.append(line)
            }
            text = lines.joined(separator: "\n")
            if text.isEmpty {
                exitWithError("No message text provided")
            }
        }
        sendMessage(contact: contact, text: text)

    case "file":
        guard args.count >= 2 else {
            exitWithError("send file requires: <contact> <path>")
        }
        sendFile(contact: args[0], filePath: args[1])

    case "chat":
        guard !args.isEmpty else {
            exitWithError("send chat requires: <chat-id> [text]")
        }
        let chatId = args[0]
        let text: String
        if args.count >= 2 {
            text = args[1...].joined(separator: " ")
        } else {
            var lines: [String] = []
            while let line = readLine() {
                lines.append(line)
            }
            text = lines.joined(separator: "\n")
            if text.isEmpty {
                exitWithError("No message text provided")
            }
        }
        sendToChat(chatId: chatId, text: text)

    default:
        exitWithError("Unknown send subcommand: \(subcommand). Use message, file, or chat.")
    }
}
