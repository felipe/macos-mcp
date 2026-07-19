import Foundation

// MARK: - Apple Reminders (read-only, via AppleScript)
//
// Lists reminders through the Reminders app with osascript. AppleScript
// Reminders access is slow, so limits stay tight and the shared automation
// timeout kills any run that overstays. Requires the Automation (Apple
// Events) permission for Reminders; fails loudly without it.
//
// AppleScript logic ported from boop-agent (MIT, Chris Raroque):
// https://github.com/raroque/boop-agent

private let maxDueWithinDays = 3650

// MARK: - Script

private let listRemindersScript = appleScriptJSONHelpers + #"""
set listFilter to system attribute "MACOS_MCP_REMINDERS_LIST"
set includeCompletedText to system attribute "MACOS_MCP_REMINDERS_INCLUDE_COMPLETED"
set dueWithinDaysText to system attribute "MACOS_MCP_REMINDERS_DUE_WITHIN_DAYS"
set maxItemsText to system attribute "MACOS_MCP_REMINDERS_LIMIT"
set includeCompleted to includeCompletedText is "true"
set maxItems to maxItemsText as integer
set outputRows to {}
set doneReading to false
set hasDueFilter to dueWithinDaysText is not ""
set dueLimitDate to missing value
if hasDueFilter then
  set dueLimitDate to (current date) + ((dueWithinDaysText as integer) * days)
end if

tell application "Reminders"
  set sourceLists to lists
  repeat with aList in sourceLists
    if doneReading then exit repeat
    set listName to name of aList as text
    set listId to id of aList as text
    if listFilter is "" or listName contains listFilter or listId is listFilter then
      set listReminders to reminders of aList
      repeat with aReminder in listReminders
        if doneReading then exit repeat
        set reminderProps to properties of aReminder
        set reminderCompleted to completed of reminderProps
        if includeCompleted or reminderCompleted is false then
          set dueDateValue to missing value
          try
            set dueDateValue to due date of reminderProps
          end try
          if dueDateValue is missing value then
            try
              set dueDateValue to allday due date of reminderProps
            end try
          end if
          if (hasDueFilter is false) or (dueDateValue is not missing value and dueDateValue is less than or equal to dueLimitDate) then
            set completedJson to "false"
            if reminderCompleted then set completedJson to "true"
            set reminderNotes to body of reminderProps
            set completedDateValue to completion date of reminderProps
            set createdDateValue to creation date of reminderProps
            set modifiedDateValue to modification date of reminderProps
            set rowJson to "{" & ¬
              "\"id\":" & my jsonString(id of reminderProps) & "," & ¬
              "\"list\":" & my jsonString(listName) & "," & ¬
              "\"title\":" & my jsonString(name of reminderProps) & "," & ¬
              "\"notes\":" & my jsonNullableString(reminderNotes) & "," & ¬
              "\"dueAt\":" & my jsonNullableDate(dueDateValue) & "," & ¬
              "\"completed\":" & completedJson & "," & ¬
              "\"completedAt\":" & my jsonNullableDate(completedDateValue) & "," & ¬
              "\"createdAt\":" & my jsonNullableDate(createdDateValue) & "," & ¬
              "\"modifiedAt\":" & my jsonNullableDate(modifiedDateValue) & "," & ¬
              "\"priority\":" & ((priority of reminderProps) as text) & ¬
              "}"
            set end of outputRows to rowJson
            if (count of outputRows) is greater than or equal to maxItems then set doneReading to true
          end if
        end if
      end repeat
    end if
  end repeat
end tell

return "[" & my joinJson(outputRows) & "]"
"""#

// MARK: - Tool

func remindersList(list: String, includeCompleted: Bool, dueWithinDays: Int?, limit: Int?) -> String {
    var dueWithin = ""
    if let days = dueWithinDays {
        dueWithin = String(max(0, min(days, maxDueWithinDays)))
    }

    let (json, error) = runAutomationScript(
        appName: "Reminders",
        script: listRemindersScript,
        extraEnv: [
            "MACOS_MCP_REMINDERS_LIST": list.trimmingCharacters(in: .whitespacesAndNewlines),
            "MACOS_MCP_REMINDERS_INCLUDE_COMPLETED": includeCompleted ? "true" : "false",
            "MACOS_MCP_REMINDERS_DUE_WITHIN_DAYS": dueWithin,
            "MACOS_MCP_REMINDERS_LIMIT": String(clampedLimit(limit, fallback: 20)),
        ]
    )
    if let error = error { return error }
    guard let rows = json as? [[String: Any]] else {
        return errorJSON("Reminders returned unreadable data")
    }
    return serializeJSONObject(["results": rows])
}
