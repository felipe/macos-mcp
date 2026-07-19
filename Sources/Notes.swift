import Foundation

// MARK: - Apple Notes (read-only, via AppleScript)
//
// Searches note names/plaintext and reads single notes through the Notes app
// with osascript. Requires the Automation (Apple Events) permission for
// Notes; without it the tools fail loudly instead of hanging.
//
// AppleScript logic ported from boop-agent (MIT, Chris Raroque):
// https://github.com/raroque/boop-agent

private let noteBodyLimit = 40_000

// MARK: - Scripts

/// Case behavior matches AppleScript's default `contains` (case-insensitive).
/// Snippets are capped at 240 characters.
private let searchNotesScript = appleScriptJSONHelpers + #"""
on noteSnippet(bodyText)
  set cleanText to bodyText as text
  if (length of cleanText) > 240 then
    return (text 1 thru 240 of cleanText) & "..."
  end if
  return cleanText
end noteSnippet

on noteFolderName(aNote)
  try
    tell application "Notes"
      return name of container of aNote as text
    end tell
  on error
    return "Notes"
  end try
end noteFolderName

on noteModifiedAt(aNote)
  try
    tell application "Notes"
      return modification date of aNote as text
    end tell
  on error
    return ""
  end try
end noteModifiedAt

set queryText to system attribute "MACOS_MCP_NOTES_QUERY"
set maxItemsText to system attribute "MACOS_MCP_NOTES_LIMIT"
set maxItems to maxItemsText as integer
set outputRows to {}

tell application "Notes"
  set matchedNotes to every note whose name contains queryText or plaintext contains queryText
  set totalMatches to count of matchedNotes
  if totalMatches > maxItems then
    set totalMatches to maxItems
  end if
  repeat with i from 1 to totalMatches
    set aNote to item i of matchedNotes
    set noteBody to plaintext of aNote as text
    set rowJson to "{" & ¬
      "\"id\":" & my jsonString(id of aNote) & "," & ¬
      "\"name\":" & my jsonString(name of aNote) & "," & ¬
      "\"folder\":" & my jsonString(my noteFolderName(aNote)) & "," & ¬
      "\"modifiedAt\":" & my jsonNullableString(my noteModifiedAt(aNote)) & "," & ¬
      "\"snippet\":" & my jsonString(my noteSnippet(noteBody)) & ¬
      "}"
    set end of outputRows to rowJson
  end repeat
end tell

return "[" & my joinJson(outputRows) & "]"
"""#

private let readNoteScript = appleScriptJSONHelpers + #"""
on noteFolderName(aNote)
  try
    tell application "Notes"
      return name of container of aNote as text
    end tell
  on error
    return "Notes"
  end try
end noteFolderName

on noteModifiedAt(aNote)
  try
    tell application "Notes"
      return modification date of aNote as text
    end tell
  on error
    return ""
  end try
end noteModifiedAt

set targetId to system attribute "MACOS_MCP_NOTES_ID"

tell application "Notes"
  set matchedNotes to every note whose id is targetId
  if (count of matchedNotes) is 0 then
    error "Apple Note was not found."
  end if
  set aNote to item 1 of matchedNotes
  set rowJson to "{" & ¬
    "\"id\":" & my jsonString(id of aNote) & "," & ¬
    "\"name\":" & my jsonString(name of aNote) & "," & ¬
    "\"folder\":" & my jsonString(my noteFolderName(aNote)) & "," & ¬
    "\"modifiedAt\":" & my jsonNullableString(my noteModifiedAt(aNote)) & "," & ¬
    "\"body\":" & my jsonString(plaintext of aNote) & ¬
    "}"
end tell

return rowJson
"""#

// MARK: - Tools

func notesSearch(query: String, limit: Int?) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return automationErrorJSON("notes_search requires a non-empty query")
    }

    let (output, errorJSON) = runAutomationScript(
        appName: "Notes",
        script: searchNotesScript,
        extraEnv: [
            "MACOS_MCP_NOTES_QUERY": trimmed,
            "MACOS_MCP_NOTES_LIMIT": String(clampedLimit(limit, fallback: 10)),
        ]
    )
    if let errorJSON = errorJSON { return errorJSON }
    guard let output = output,
          let data = output.data(using: .utf8),
          let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        return automationErrorJSON("Notes returned unreadable data")
    }
    return serializeJSONObject(["query": trimmed, "results": rows])
}

func notesRead(noteId: String) -> String {
    let trimmed = noteId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return automationErrorJSON("notes_read requires a note_id")
    }

    let (output, errorJSON) = runAutomationScript(
        appName: "Notes",
        script: readNoteScript,
        extraEnv: ["MACOS_MCP_NOTES_ID": trimmed]
    )
    if let errorJSON = errorJSON { return errorJSON }
    guard let output = output,
          let data = output.data(using: .utf8),
          var note = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return automationErrorJSON("Notes returned unreadable data")
    }

    if let body = note["body"] as? String, body.count > noteBodyLimit {
        note["body"] = String(body.prefix(noteBodyLimit)) + "\n[truncated]"
        note["truncated"] = true
    }
    return serializeJSONObject(note)
}
