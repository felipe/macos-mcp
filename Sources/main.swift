import Foundation

let args = Array(CommandLine.arguments.dropFirst())

guard let command = args.first else {
    printUsage()
}

switch command {
case "launch":
    runLaunch(args: Array(args.dropFirst()))

case "calendar":
    guard args.count >= 2 else {
        exitWithError("calendar requires a subcommand: list|events|upcoming|search|create|update|delete")
    }
    runCalendar(subcommand: args[1], args: Array(args.dropFirst(2)))

case "messages":
    guard args.count >= 2 else {
        exitWithError("messages requires a subcommand: check|read|list-conversations|attachments")
    }
    runMessages(subcommand: args[1], args: Array(args.dropFirst(2)))

case "send":
    guard args.count >= 2 else {
        exitWithError("send requires a subcommand: message|file|chat")
    }
    runSend(subcommand: args[1], args: Array(args.dropFirst(2)))

case "typing":
    runTyping(args: Array(args.dropFirst()))

case "--version", "version":
    printJSON(["version": appVersion, "name": "macos-mcp"])
    exit(0)

case "--help", "help":
    printUsage()

default:
    exitWithError("Unknown command: \(command). Run 'macos-mcp help' for usage.")
}

func printUsage() -> Never {
    let usage = """
    macos-mcp — macOS system services for AI tools

    Usage: macos-mcp <command> [args...]

    Commands:
      launch <command> [args...]              Run command with inherited FDA permissions
      calendar <subcommand> [args...]         Calendar operations via EventKit
      messages <subcommand> [args...]         iMessage database operations
      send <subcommand> [args...]             Send messages via AppleScript
      typing <contact> <start|stop|keepalive> iMessage typing indicator

    Calendar subcommands:
      list                                    List all visible calendars
      events --from DATE --to DATE [--cal ID] Get events in date range
      upcoming [--hours N] [--cal ID]         Get upcoming events (default: 24h)
      search QUERY [--days N] [--cal ID]      Search events by title/notes/location
      create --cal ID --title TEXT --start DATE --end DATE [--notes TEXT] [--location TEXT] [--all-day]
      update --id ID [--title TEXT] [--start DATE] [--end DATE] [--notes TEXT] [--location TEXT]
      delete --id ID                          Delete an event

    Messages subcommands:
      check [--phone PHONE] [--since MIN]     Poll recent incoming messages
      read [--phone PHONE] [--limit N]        Read conversation history
      list-conversations [--limit N]          List recent conversations
      attachments --rowid N [--convert-heic]  Get message attachments

    Send subcommands:
      message <contact> [text]                Send iMessage (falls back to SMS)
      file <contact> <path>                   Send file attachment
      chat <chat-id> [text]                   Send to group chat

    Dates: ISO 8601 (2026-03-23T14:00:00Z) or date-only (2026-03-23)
    Output: JSON to stdout, errors as JSON to stderr
    """
    fputs(usage + "\n", stderr)
    exit(1)
}
