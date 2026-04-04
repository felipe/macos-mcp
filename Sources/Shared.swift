import Foundation

// MARK: - Constants

let appVersion = "3.0.0"
let appleEpochOffset: TimeInterval = 978307200

// MARK: - Apple Epoch Conversion

func appleNanosToDate(_ nanos: Int64) -> Date {
    let unix = TimeInterval(nanos) / 1_000_000_000 + appleEpochOffset
    return Date(timeIntervalSince1970: unix)
}

func appleNanosToISO(_ nanos: Int64) -> String {
    return isoFormatter.string(from: appleNanosToDate(nanos))
}

// MARK: - Date Formatting

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone.current
    return f
}()

// MARK: - Date Parsing

func parseDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: string) { return date }
    let dateOnly = DateFormatter()
    dateOnly.dateFormat = "yyyy-MM-dd"
    dateOnly.timeZone = TimeZone.current
    return dateOnly.date(from: string)
}

// MARK: - JSON Output

func printJSON(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
        exitWithError("Failed to serialize JSON")
    }
    print(json)
}

func exitWithError(_ message: String) -> Never {
    let error: [String: Any] = ["error": message]
    if let data = try? JSONSerialization.data(withJSONObject: error),
       let json = String(data: data, encoding: .utf8) {
        fputs(json + "\n", stderr)
    } else {
        fputs("{\"error\":\"\(message)\"}\n", stderr)
    }
    exit(1)
}

// MARK: - Argument Parsing

func requireArgValue(_ args: [String], _ i: inout Int, flag: String) -> String {
    i += 1
    guard i < args.count else {
        exitWithError("\(flag) requires a value")
    }
    return args[i]
}

// MARK: - Process Helpers

@discardableResult
func runProcess(_ executablePath: String, arguments: [String], input: String? = nil, timeout: TimeInterval = 0) -> (stdout: String, stderr: String, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    if let input = input {
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        stdinPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()
    }

    do {
        try process.run()
    } catch {
        return ("", error.localizedDescription, 1)
    }

    if timeout > 0 {
        let deadline = DispatchTime.now() + timeout
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            sem.signal()
        }
        if sem.wait(timeout: deadline) == .timedOut {
            process.terminate()
            // Give it a moment, then force kill
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            return ("", "Process timed out after \(Int(timeout))s", 1)
        }
    } else {
        process.waitUntilExit()
    }

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (stdout, stderr, process.terminationStatus)
}

// MARK: - String Escaping

func escapeForAppleScript(_ string: String) -> String {
    return string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
}
