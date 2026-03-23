import EventKit
import Foundation

// MARK: - EventKit Store

private let store = EKEventStore()

// MARK: - Access

private func requestCalendarAccess() async -> Bool {
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

// MARK: - Helpers

private func calendarToDict(_ cal: EKCalendar) -> [String: Any] {
    return [
        "id": cal.calendarIdentifier,
        "title": cal.title,
        "type": calendarTypeName(cal.type),
        "source": cal.source?.title ?? "unknown",
        "color": cal.cgColor?.components?.map { NSNumber(value: $0) } ?? [],
        "allowsModify": NSNumber(value: cal.allowsContentModifications),
        "isSubscribed": NSNumber(value: cal.isSubscribed),
        "isImmutable": NSNumber(value: cal.isImmutable)
    ]
}

private func eventToDict(_ event: EKEvent) -> [String: Any] {
    var dict: [String: Any] = [
        "id": event.eventIdentifier ?? "",
        "title": event.title ?? "",
        "startDate": isoFormatter.string(from: event.startDate),
        "endDate": isoFormatter.string(from: event.endDate),
        "isAllDay": NSNumber(value: event.isAllDay),
        "calendar": event.calendar?.title ?? "",
        "calendarId": event.calendar?.calendarIdentifier ?? ""
    ]
    if let location = event.location { dict["location"] = location }
    if let notes = event.notes { dict["notes"] = notes }
    if let url = event.url { dict["url"] = url.absoluteString }
    if event.hasRecurrenceRules { dict["isRecurring"] = NSNumber(value: true) }
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

private func calendarTypeName(_ type: EKCalendarType) -> String {
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

private func listCalendars() {
    let calendars = store.calendars(for: .event)
    printJSON(calendars.map { calendarToDict($0) })
}

private func getEvents(calendarId: String?, from: Date, to: Date) {
    var calendars: [EKCalendar]? = nil
    if let calId = calendarId, let cal = store.calendar(withIdentifier: calId) {
        calendars = [cal]
    }
    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
    let events = store.events(matching: predicate)
    printJSON(events.map { eventToDict($0) })
}

private func getUpcoming(hours: Int, calendarId: String?) {
    let from = Date()
    guard let to = Calendar.current.date(byAdding: .hour, value: hours, to: from) else {
        exitWithError("Invalid hours value: \(hours)")
    }
    getEvents(calendarId: calendarId, from: from, to: to)
}

private func searchEvents(query: String, daysBack: Int, calendarId: String?) {
    let to = Date()
    guard let from = Calendar.current.date(byAdding: .day, value: -daysBack, to: to) else {
        exitWithError("Invalid days value: \(daysBack)")
    }
    var calendars: [EKCalendar]? = nil
    if let calId = calendarId, let cal = store.calendar(withIdentifier: calId) {
        calendars = [cal]
    }
    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
    let events = store.events(matching: predicate)
    let q = query.lowercased()
    let filtered = events.filter { event in
        let title = event.title?.lowercased() ?? ""
        let notes = event.notes?.lowercased() ?? ""
        let location = event.location?.lowercased() ?? ""
        return title.contains(q) || notes.contains(q) || location.contains(q)
    }
    printJSON(filtered.map { eventToDict($0) })
}

private func createEvent(calendarId: String, title: String, startDate: Date, endDate: Date,
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
    event.isAllDay = allDay

    if allDay {
        let adjustedEnd = max(endDate, Calendar.current.date(byAdding: .day, value: 1, to: startDate) ?? endDate)
        event.endDate = adjustedEnd
    } else {
        event.endDate = endDate
    }

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

private func updateEvent(eventId: String, title: String?, startDate: Date?, endDate: Date?,
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

private func deleteEvent(eventId: String) {
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

// MARK: - Entry Point

func runCalendar(subcommand: String, args: [String]) {
    let semaphore = DispatchSemaphore(value: 0)

    Task {
        guard await requestCalendarAccess() else {
            exitWithError("Calendar access denied. Grant permission in System Settings > Privacy > Calendars.")
        }

        switch subcommand {
        case "list", "list-calendars":
            listCalendars()

        case "events":
            var from: Date?
            var to: Date?
            var calId: String?
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--from": from = parseDate(requireArgValue(args, &i, flag: "--from"))
                case "--to": to = parseDate(requireArgValue(args, &i, flag: "--to"))
                case "--cal": calId = requireArgValue(args, &i, flag: "--cal")
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
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--hours":
                    let val = requireArgValue(args, &i, flag: "--hours")
                    hours = Int(val) ?? 24
                case "--cal": calId = requireArgValue(args, &i, flag: "--cal")
                default: break
                }
                i += 1
            }
            getUpcoming(hours: hours, calendarId: calId)

        case "search":
            guard !args.isEmpty else { exitWithError("search requires a query") }
            let query = args[0]
            var days = 30
            var calId: String?
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--days":
                    let val = requireArgValue(args, &i, flag: "--days")
                    days = Int(val) ?? 30
                case "--cal": calId = requireArgValue(args, &i, flag: "--cal")
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
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--cal": calId = requireArgValue(args, &i, flag: "--cal")
                case "--title": title = requireArgValue(args, &i, flag: "--title")
                case "--start": startStr = requireArgValue(args, &i, flag: "--start")
                case "--end": endStr = requireArgValue(args, &i, flag: "--end")
                case "--notes": notes = requireArgValue(args, &i, flag: "--notes")
                case "--location": location = requireArgValue(args, &i, flag: "--location")
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
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--id": eventId = requireArgValue(args, &i, flag: "--id")
                case "--title": title = requireArgValue(args, &i, flag: "--title")
                case "--start": startStr = requireArgValue(args, &i, flag: "--start")
                case "--end": endStr = requireArgValue(args, &i, flag: "--end")
                case "--notes": notes = requireArgValue(args, &i, flag: "--notes")
                case "--location": location = requireArgValue(args, &i, flag: "--location")
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
            var i = 0
            while i < args.count {
                if args[i] == "--id" { eventId = requireArgValue(args, &i, flag: "--id") }
                i += 1
            }
            guard let eventId = eventId else {
                exitWithError("delete requires --id ID")
            }
            deleteEvent(eventId: eventId)

        default:
            exitWithError("Unknown calendar subcommand: \(subcommand)")
        }

        semaphore.signal()
    }

    semaphore.wait()
}
