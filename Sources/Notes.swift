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

/// Handlers shared by both Notes scripts: folder and modification date reads
/// that tolerate notes disappearing mid-read.
private let noteMetadataHandlers = #"""
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

"""#

/// Case behavior matches AppleScript's default `contains` (case-insensitive).
/// Snippets are capped at 240 characters.
private let searchNotesScript = appleScriptJSONHelpers + noteMetadataHandlers + #"""
on noteSnippet(bodyText)
  set cleanText to bodyText as text
  if (length of cleanText) > 240 then
    return (text 1 thru 240 of cleanText) & "..."
  end if
  return cleanText
end noteSnippet

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

private let readNoteScript = appleScriptJSONHelpers + noteMetadataHandlers + #"""
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
        return errorJSON("notes_search requires a non-empty query")
    }

    let (json, error) = runAutomationScript(
        appName: "Notes",
        script: searchNotesScript,
        extraEnv: [
            "MACOS_MCP_NOTES_QUERY": trimmed,
            "MACOS_MCP_NOTES_LIMIT": String(clampedLimit(limit, fallback: 10)),
        ]
    )
    if let error = error { return error }
    guard let rows = json as? [[String: Any]] else {
        return errorJSON("Notes returned unreadable data")
    }
    return serializeJSONObject(["query": trimmed, "results": rows])
}

func notesRead(noteId: String) -> String {
    let trimmed = noteId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return errorJSON("notes_read requires a note_id")
    }

    let (json, error) = runAutomationScript(
        appName: "Notes",
        script: readNoteScript,
        extraEnv: ["MACOS_MCP_NOTES_ID": trimmed]
    )
    if let error = error { return error }
    guard var note = json as? [String: Any] else {
        return errorJSON("Notes returned unreadable data")
    }

    if let body = note["body"] as? String, body.count > noteBodyLimit {
        note["body"] = String(body.prefix(noteBodyLimit)) + "\n[truncated]"
        note["truncated"] = true
    }
    return serializeJSONObject(note)
}
