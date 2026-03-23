import EventKit
import Foundation

// mac-calendar: CLI tool for macOS calendar operations via EventKit
// Reads all visible calendars, writes only to calendars owned by this account.
//
// Build: swiftc -O -o mac-calendar mac-calendar.swift -framework EventKit
//
// Requires: Calendar access permission (TCC prompt on first run)

let store = EKEventStore()

// MARK: - Helpers

func requestAccess() async -> Bool {
    if #available(macOS 14.0, *) {
        return (try? await store.requestFullAccessToEvents()) ?? false
    } else {
        return await withCheckedContinuation { continuation in
            store.requestAccess(to: .event) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
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

func printJSON(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
        exitWithError("Failed to serialize JSON")
    }
    print(json)
}

func parseDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: string) { return date }
    // Try date-only
    let dateOnly = DateFormatter()
    dateOnly.dateFormat = "yyyy-MM-dd"
    dateOnly.timeZone = TimeZone.current
    return dateOnly.date(from: string)
}

func calendarToDict(_ cal: EKCalendar) -> [String: Any] {
    return [
        "id": cal.calendarIdentifier,
        "title": cal.title,
        "type": calendarTypeName(cal.type),
        "source": cal.source?.title ?? "unknown",
        "color": cal.cgColor?.components?.map { $0 } ?? [],
        "allowsModify": cal.allowsContentModifications,
        "isSubscribed": cal.isSubscribed,
        "isImmutable": cal.isImmutable
    ]
}

func eventToDict(_ event: EKEvent) -> [String: Any] {
    var dict: [String: Any] = [
        "id": event.eventIdentifier ?? "",
        "title": event.title ?? "",
        "startDate": ISO8601DateFormatter().string(from: event.startDate),
        "endDate": ISO8601DateFormatter().string(from: event.endDate),
        "isAllDay": event.isAllDay,
        "calendar": event.calendar?.title ?? "",
        "calendarId": event.calendar?.calendarIdentifier ?? ""
    ]
    if let location = event.location { dict["location"] = location }
    if let notes = event.notes { dict["notes"] = notes }
    if let url = event.url { dict["url"] = url.absoluteString }
    if event.hasRecurrenceRules { dict["isRecurring"] = true }
    if let organizer = event.organizer?.name { dict["organizer"] = organizer }
    dict["status"] = switch event.status {
        case .none: "none"
        case .confirmed: "confirmed"
        case .tentative: "tentative"
        case .canceled: "canceled"
        @unknown default: "unknown"
    }
    return dict
}

func calendarTypeName(_ type: EKCalendarType) -> String {
    switch type {
    case .local: return "local"
    case .calDAV: return "caldav"
    case .exchange: return "exchange"
    case .subscription: return "subscription"
    case .birthday: return "birthday"
    @unknown default: return "unknown"
    }
}

// MARK: - Commands

func listCalendars() {
    let calendars = store.calendars(for: .event)
    let result = calendars.map { calendarToDict($0) }
    printJSON(result)
}

func getEvents(calendarId: String?, from: Date, to: Date) {
    var calendars: [EKCalendar]? = nil
    if let calId = calendarId,
       let cal = store.calendar(withIdentifier: calId) {
        calendars = [cal]
    }
    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
    let events = store.events(matching: predicate)
    let result = events.map { eventToDict($0) }
    printJSON(result)
}

func getUpcoming(hours: Int, calendarId: String?) {
    let from = Date()
    let to = Calendar.current.date(byAdding: .hour, value: hours, to: from)!
    getEvents(calendarId: calendarId, from: from, to: to)
}

func searchEvents(query: String, daysBack: Int, calendarId: String?) {
    let to = Date()
    let from = Calendar.current.date(byAdding: .day, value: -daysBack, to: to)!
    var calendars: [EKCalendar]? = nil
    if let calId = calendarId,
       let cal = store.calendar(withIdentifier: calId) {
        calendars = [cal]
    }
    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
    let events = store.events(matching: predicate)
    let filtered = events.filter { event in
        let title = event.title?.lowercased() ?? ""
        let notes = event.notes?.lowercased() ?? ""
        let location = event.location?.lowercased() ?? ""
        let q = query.lowercased()
        return title.contains(q) || notes.contains(q) || location.contains(q)
    }
    let result = filtered.map { eventToDict($0) }
    printJSON(result)
}

func createEvent(calendarId: String, title: String, startDate: Date, endDate: Date,
                 notes: String?, location: String?, allDay: Bool) {
    guard let calendar = store.calendar(withIdentifier: calendarId) else {
        exitWithError("Calendar not found: \(calendarId)")
    }
    guard calendar.allowsContentModifications else {
        exitWithError("Calendar does not allow modifications: \(calendar.title)")
    }

    let event = EKEvent(eventStore: store)
    event.calendar = calendar
    event.title = title
    event.startDate = startDate
    event.endDate = endDate
    event.isAllDay = allDay
    if let notes = notes { event.notes = notes }
    if let location = location { event.location = location }

    do {
        try store.save(event, span: .thisEvent)
        printJSON([
            "created": true,
            "id": event.eventIdentifier ?? "",
            "title": title,
            "calendar": calendar.title
        ])
    } catch {
        exitWithError("Failed to save event: \(error.localizedDescription)")
    }
}

func updateEvent(eventId: String, title: String?, startDate: Date?, endDate: Date?,
                 notes: String?, location: String?) {
    guard let event = store.event(withIdentifier: eventId) else {
        exitWithError("Event not found: \(eventId)")
    }
    guard event.calendar.allowsContentModifications else {
        exitWithError("Calendar does not allow modifications: \(event.calendar.title)")
    }

    if let title = title { event.title = title }
    if let startDate = startDate { event.startDate = startDate }
    if let endDate = endDate { event.endDate = endDate }
    if let notes = notes { event.notes = notes }
    if let location = location { event.location = location }

    do {
        try store.save(event, span: .thisEvent)
        printJSON(["updated": true, "id": eventId])
    } catch {
        exitWithError("Failed to update event: \(error.localizedDescription)")
    }
}

func deleteEvent(eventId: String) {
    guard let event = store.event(withIdentifier: eventId) else {
        exitWithError("Event not found: \(eventId)")
    }
    guard event.calendar.allowsContentModifications else {
        exitWithError("Calendar does not allow modifications: \(event.calendar.title)")
    }

    do {
        try store.remove(event, span: .thisEvent)
        printJSON(["deleted": true, "id": eventId])
    } catch {
        exitWithError("Failed to delete event: \(error.localizedDescription)")
    }
}

// MARK: - CLI

func printUsage() -> Never {
    let usage = """
    mac-calendar — macOS calendar operations via EventKit

    Commands:
      list-calendars                          List all visible calendars
      events --from DATE --to DATE [--cal ID] Get events in date range
      upcoming [--hours N] [--cal ID]         Get upcoming events (default: 24h)
      search QUERY [--days N] [--cal ID]      Search events by title/notes/location
      create --cal ID --title TEXT --start DATE --end DATE [--notes TEXT] [--location TEXT] [--all-day]
      update --id ID [--title TEXT] [--start DATE] [--end DATE] [--notes TEXT] [--location TEXT]
      delete --id ID

    Dates: ISO 8601 (2026-03-23T14:00:00Z) or date-only (2026-03-23)
    Output: JSON to stdout, errors as JSON to stderr
    """
    fputs(usage + "\n", stderr)
    exit(1)
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { printUsage() }

let semaphore = DispatchSemaphore(value: 0)

Task {
    guard await requestAccess() else {
        exitWithError("Calendar access denied. Grant permission in System Settings > Privacy > Calendars.")
    }

    let command = args[0]

    switch command {
    case "list-calendars":
        listCalendars()

    case "events":
        var from: Date?
        var to: Date?
        var calId: String?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--from": i += 1; from = parseDate(args[i])
            case "--to": i += 1; to = parseDate(args[i])
            case "--cal": i += 1; calId = args[i]
            default: break
            }
            i += 1
        }
        guard let from = from, let to = to else {
            exitWithError("events requires --from DATE --to DATE")
        }
        getEvents(calendarId: calId, from: from, to: to)

    case "upcoming":
        var hours = 24
        var calId: String?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--hours": i += 1; hours = Int(args[i]) ?? 24
            case "--cal": i += 1; calId = args[i]
            default: break
            }
            i += 1
        }
        getUpcoming(hours: hours, calendarId: calId)

    case "search":
        guard args.count >= 2 else { exitWithError("search requires a query") }
        let query = args[1]
        var days = 30
        var calId: String?
        var i = 2
        while i < args.count {
            switch args[i] {
            case "--days": i += 1; days = Int(args[i]) ?? 30
            case "--cal": i += 1; calId = args[i]
            default: break
            }
            i += 1
        }
        searchEvents(query: query, daysBack: days, calendarId: calId)

    case "create":
        var calId: String?
        var title: String?
        var startStr: String?
        var endStr: String?
        var notes: String?
        var location: String?
        var allDay = false
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--cal": i += 1; calId = args[i]
            case "--title": i += 1; title = args[i]
            case "--start": i += 1; startStr = args[i]
            case "--end": i += 1; endStr = args[i]
            case "--notes": i += 1; notes = args[i]
            case "--location": i += 1; location = args[i]
            case "--all-day": allDay = true
            default: break
            }
            i += 1
        }
        guard let calId = calId, let title = title,
              let startStr = startStr, let startDate = parseDate(startStr),
              let endStr = endStr, let endDate = parseDate(endStr) else {
            exitWithError("create requires --cal ID --title TEXT --start DATE --end DATE")
        }
        createEvent(calendarId: calId, title: title, startDate: startDate, endDate: endDate,
                    notes: notes, location: location, allDay: allDay)

    case "update":
        var eventId: String?
        var title: String?
        var startStr: String?
        var endStr: String?
        var notes: String?
        var location: String?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--id": i += 1; eventId = args[i]
            case "--title": i += 1; title = args[i]
            case "--start": i += 1; startStr = args[i]
            case "--end": i += 1; endStr = args[i]
            case "--notes": i += 1; notes = args[i]
            case "--location": i += 1; location = args[i]
            default: break
            }
            i += 1
        }
        guard let eventId = eventId else {
            exitWithError("update requires --id ID")
        }
        updateEvent(eventId: eventId, title: title,
                    startDate: startStr.flatMap { parseDate($0) },
                    endDate: endStr.flatMap { parseDate($0) },
                    notes: notes, location: location)

    case "delete":
        var eventId: String?
        var i = 1
        while i < args.count {
            if args[i] == "--id" { i += 1; eventId = args[i] }
            i += 1
        }
        guard let eventId = eventId else {
            exitWithError("delete requires --id ID")
        }
        deleteEvent(eventId: eventId)

    default:
        printUsage()
    }

    semaphore.signal()
}

semaphore.wait()
