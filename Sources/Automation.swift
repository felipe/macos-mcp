import Foundation

// MARK: - AppleScript Automation Runner
//
// Shared runner for read-only AppleScript access to Apple apps (Notes,
// Reminders) via /usr/bin/osascript. Inputs are passed as environment
// variables and read with AppleScript's `system attribute`, so user text is
// never interpolated into script source (no AppleScript injection).
//
// Access pattern and error mapping based on boop-agent (MIT, Chris Raroque):
// https://github.com/raroque/boop-agent

private let osascriptBin = "/usr/bin/osascript"
let automationScriptTimeout: TimeInterval = 20

// MARK: - AppleScript JSON helpers

/// AppleScript handlers shared by the Notes and Reminders scripts: JSON string
/// escaping, nullable fields, local ISO dates, and array joining.
/// Ported from boop-agent (MIT, Chris Raroque).
let appleScriptJSONHelpers = #"""
on replaceText(findText, replaceText, sourceText)
  set AppleScript's text item delimiters to findText
  set textItems to every text item of sourceText
  set AppleScript's text item delimiters to replaceText
  set resultText to textItems as text
  set AppleScript's text item delimiters to ""
  return resultText
end replaceText

on jsonString(sourceValue)
  set sourceText to sourceValue as text
  set sourceText to my replaceText("\\", "\\\\", sourceText)
  set sourceText to my replaceText("\"", "\\\"", sourceText)
  set sourceText to my replaceText(return, "\\n", sourceText)
  set sourceText to my replaceText(linefeed, "\\n", sourceText)
  set sourceText to my replaceText(tab, "\\t", sourceText)
  return "\"" & sourceText & "\""
end jsonString

on jsonNullableString(sourceValue)
  if sourceValue is missing value then return "null"
  if sourceValue is "" then return "null"
  return my jsonString(sourceValue)
end jsonNullableString

on pad2(numberValue)
  set textValue to numberValue as integer as text
  if (count of characters of textValue) is 1 then return "0" & textValue
  return textValue
end pad2

on localIsoDate(dateValue)
  if dateValue is missing value then return ""
  return ((year of dateValue as integer) as text) & "-" & my pad2(month of dateValue as integer) & "-" & my pad2(day of dateValue as integer) & "T" & my pad2(hours of dateValue as integer) & ":" & my pad2(minutes of dateValue as integer) & ":" & my pad2(seconds of dateValue as integer)
end localIsoDate

on jsonNullableDate(dateValue)
  if dateValue is missing value then return "null"
  return my jsonString(my localIsoDate(dateValue))
end jsonNullableDate

on joinJson(jsonItems)
  set AppleScript's text item delimiters to ","
  set resultText to jsonItems as text
  set AppleScript's text item delimiters to ""
  return resultText
end joinJson

"""#

// MARK: - Error Mapping

func automationDeniedMessage(_ appName: String) -> String {
    return "Automation permission not granted for \(appName) — grant macos-mcp access to \(appName) in System Settings > Privacy & Security > Automation."
}

private func isAutomationDenied(_ text: String) -> Bool {
    let lower = text.lowercased()
    return text.contains("-1743")
        || text.contains("-1744")
        || lower.contains("not authorized to send apple events")
        || lower.contains("not allowed to send apple events")
        || lower.contains("user canceled")
        || lower.contains("operation not permitted")
}

func automationErrorJSON(_ message: String) -> String {
    return serializeJSONObject(["error": message])
}

// MARK: - Runner

/// Run an AppleScript against `appName`, returning its stdout (expected to be
/// a JSON document) on success or a `{"error": ...}` JSON string on failure.
/// The osascript child is bounded by `automationScriptTimeout` and killed on
/// expiry, so a hung Apple Event can never leak a subprocess.
func runAutomationScript(appName: String, script: String, extraEnv: [String: String]) -> (output: String?, errorJSON: String?) {
    guard FileManager.default.fileExists(atPath: osascriptBin) else {
        return (nil, automationErrorJSON("osascript not found at \(osascriptBin)"))
    }

    let result = runProcess(
        osascriptBin,
        arguments: ["-e", script],
        timeout: automationScriptTimeout,
        extraEnv: extraEnv
    )

    let stderrText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

    if result.exitCode != 0 {
        if isAutomationDenied(stderrText) {
            return (nil, automationErrorJSON(automationDeniedMessage(appName)))
        }
        if stderrText.contains("timed out") {
            return (nil, automationErrorJSON("\(appName) did not respond within \(Int(automationScriptTimeout))s. Try again with a smaller limit."))
        }
        let detail = stderrText.isEmpty ? "exit code \(result.exitCode)" : stderrText
        return (nil, automationErrorJSON("\(appName) AppleScript failed: \(detail)"))
    }

    let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else {
        return (nil, automationErrorJSON("\(appName) returned an empty response"))
    }
    guard let data = output.data(using: .utf8),
          (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
        return (nil, automationErrorJSON("\(appName) returned unreadable data"))
    }
    return (output, nil)
}

// MARK: - Limits

func clampedLimit(_ value: Int?, fallback: Int, max maxValue: Int = 50) -> Int {
    guard let value = value else { return fallback }
    return Swift.max(1, Swift.min(value, maxValue))
}
