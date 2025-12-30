import EventKit
import Foundation

// MARK: - Calendar Provider

actor CalendarProvider {
    private let eventStore = EKEventStore()
    private var isAuthorized = false

    // MARK: - Authorization

    private func requestAccess() async -> Bool {
        if isAuthorized { return true }

        do {
            if #available(macOS 14.0, *) {
                isAuthorized = try await eventStore.requestFullAccessToEvents()
            } else {
                isAuthorized = try await eventStore.requestAccess(to: .event)
            }
            return isAuthorized
        } catch {
            print("Calendar access error: \(error)")
            return false
        }
    }

    // MARK: - Query Events

    func query(action: String, searchQuery: String?) async -> ToolExecutionResult {
        guard await requestAccess() else {
            return .error("Calendar access denied. Grant access in System Settings > Privacy > Calendars.")
        }

        switch action {
        case "today":
            return await getEventsForToday()
        case "week":
            return await getEventsForWeek()
        case "list":
            return await getEventsForWeek()
        case "search":
            if let query = searchQuery {
                return await searchEvents(query: query)
            }
            return await getEventsForToday()
        default:
            return await getEventsForToday()
        }
    }

    // MARK: - Get Today's Events

    private func getEventsForToday() async -> ToolExecutionResult {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        return await fetchEvents(from: startOfDay, to: endOfDay)
    }

    // MARK: - Get Week's Events

    private func getEventsForWeek() async -> ToolExecutionResult {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfDay)!

        return await fetchEvents(from: startOfDay, to: endOfWeek)
    }

    // MARK: - Search Events

    private func searchEvents(query: String) async -> ToolExecutionResult {
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .month, value: -1, to: Date())!
        let endDate = calendar.date(byAdding: .month, value: 3, to: Date())!

        let events = await fetchEventsRaw(from: startDate, to: endDate)
        let filtered = events.filter { event in
            event.title.localizedCaseInsensitiveContains(query) ||
            (event.location ?? "").localizedCaseInsensitiveContains(query) ||
            (event.notes ?? "").localizedCaseInsensitiveContains(query)
        }

        return .calendarEvents(filtered.prefix(10).map { $0.toCalendarEventInfo() })
    }

    // MARK: - Fetch Events

    private func fetchEvents(from startDate: Date, to endDate: Date) async -> ToolExecutionResult {
        let events = await fetchEventsRaw(from: startDate, to: endDate)
        let eventInfos = events.prefix(10).map { $0.toCalendarEventInfo() }
        return .calendarEvents(Array(eventInfos))
    }

    private func fetchEventsRaw(from startDate: Date, to endDate: Date) async -> [EKEvent] {
        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        return eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }
}

// MARK: - EKEvent Extension

extension EKEvent {
    func toCalendarEventInfo() -> CalendarEventInfo {
        CalendarEventInfo(
            id: eventIdentifier ?? UUID().uuidString,
            title: title ?? "Untitled",
            startDate: startDate,
            endDate: endDate,
            location: location,
            isAllDay: isAllDay
        )
    }
}
