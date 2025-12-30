import EventKit
import Foundation

// MARK: - Reminders Provider

actor RemindersProvider {
    private let eventStore = EKEventStore()
    private var isAuthorized = false

    // MARK: - Authorization

    private func requestAccess() async -> Bool {
        if isAuthorized { return true }

        do {
            if #available(macOS 14.0, *) {
                isAuthorized = try await eventStore.requestFullAccessToReminders()
            } else {
                isAuthorized = try await eventStore.requestAccess(to: .reminder)
            }
            return isAuthorized
        } catch {
            print("Reminders access error: \(error)")
            return false
        }
    }

    // MARK: - Query Reminders

    func query(action: String, listName: String?, query: String?) async -> ToolExecutionResult {
        guard await requestAccess() else {
            return .error("Reminders access denied. Grant access in System Settings > Privacy > Reminders.")
        }

        switch action {
        case "list":
            return await getReminders(listName: listName, includeCompleted: false)
        case "all":
            return await getReminders(listName: listName, includeCompleted: true)
        case "today":
            return await getTodayReminders()
        case "overdue":
            return await getOverdueReminders()
        case "search":
            if let query = query {
                return await searchReminders(query: query)
            }
            return await getReminders(listName: nil, includeCompleted: false)
        case "lists":
            return await getReminderLists()
        case "create":
            if let title = query {
                return await createReminder(title: title, listName: listName)
            }
            return .error("Please provide a reminder title")
        case "complete":
            if let title = query {
                return await completeReminder(title: title)
            }
            return .error("Please specify which reminder to complete")
        default:
            return await getReminders(listName: nil, includeCompleted: false)
        }
    }

    // MARK: - Get Reminders

    private func getReminders(listName: String?, includeCompleted: Bool) async -> ToolExecutionResult {
        let calendars: [EKCalendar]?

        if let listName = listName {
            let allCalendars = eventStore.calendars(for: .reminder)
            calendars = allCalendars.filter { $0.title.localizedCaseInsensitiveContains(listName) }
            if calendars?.isEmpty == true {
                return .error("No reminder list found matching '\(listName)'")
            }
        } else {
            calendars = eventStore.calendars(for: .reminder)
        }

        let predicate = eventStore.predicateForReminders(in: calendars)

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let filtered = (reminders ?? [])
                    .filter { includeCompleted || !$0.isCompleted }
                    .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                    .prefix(15)
                    .map { $0.toReminderInfo() }

                continuation.resume(returning: .reminders(Array(filtered)))
            }
        }
    }

    // MARK: - Today's Reminders

    private func getTodayReminders() async -> ToolExecutionResult {
        let calendars = eventStore.calendars(for: .reminder)
        let predicate = eventStore.predicateForReminders(in: calendars)

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let filtered = (reminders ?? [])
                    .filter { reminder in
                        guard !reminder.isCompleted else { return false }
                        guard let dueDate = reminder.dueDateComponents?.date else { return false }
                        return dueDate >= startOfDay && dueDate < endOfDay
                    }
                    .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                    .map { $0.toReminderInfo() }

                continuation.resume(returning: .reminders(filtered))
            }
        }
    }

    // MARK: - Overdue Reminders

    private func getOverdueReminders() async -> ToolExecutionResult {
        let calendars = eventStore.calendars(for: .reminder)
        let predicate = eventStore.predicateForReminders(in: calendars)
        let now = Date()

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let filtered = (reminders ?? [])
                    .filter { reminder in
                        guard !reminder.isCompleted else { return false }
                        guard let dueDate = reminder.dueDateComponents?.date else { return false }
                        return dueDate < now
                    }
                    .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                    .map { $0.toReminderInfo() }

                continuation.resume(returning: .reminders(filtered))
            }
        }
    }

    // MARK: - Search Reminders

    private func searchReminders(query: String) async -> ToolExecutionResult {
        let calendars = eventStore.calendars(for: .reminder)
        let predicate = eventStore.predicateForReminders(in: calendars)

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let filtered = (reminders ?? [])
                    .filter { reminder in
                        reminder.title?.localizedCaseInsensitiveContains(query) == true ||
                        reminder.notes?.localizedCaseInsensitiveContains(query) == true
                    }
                    .prefix(15)
                    .map { $0.toReminderInfo() }

                continuation.resume(returning: .reminders(Array(filtered)))
            }
        }
    }

    // MARK: - Get Reminder Lists

    private func getReminderLists() async -> ToolExecutionResult {
        let calendars = eventStore.calendars(for: .reminder)
        let listNames = calendars.map { $0.title }
        return .text("Reminder lists: \(listNames.joined(separator: ", "))")
    }

    // MARK: - Create Reminder

    private func createReminder(title: String, listName: String?) async -> ToolExecutionResult {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title

        // Find the target list
        if let listName = listName {
            let calendars = eventStore.calendars(for: .reminder)
            if let calendar = calendars.first(where: { $0.title.localizedCaseInsensitiveContains(listName) }) {
                reminder.calendar = calendar
            } else {
                reminder.calendar = eventStore.defaultCalendarForNewReminders()
            }
        } else {
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
        }

        do {
            try eventStore.save(reminder, commit: true)
            let listTitle = reminder.calendar?.title ?? "Reminders"
            return .text("Created reminder '\(title)' in \(listTitle)")
        } catch {
            return .error("Failed to create reminder: \(error.localizedDescription)")
        }
    }

    // MARK: - Complete Reminder

    private func completeReminder(title: String) async -> ToolExecutionResult {
        let calendars = eventStore.calendars(for: .reminder)
        let predicate = eventStore.predicateForReminders(in: calendars)
        let store = eventStore  // Capture for use in closure

        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let matching = (reminders ?? []).filter {
                    !$0.isCompleted && $0.title?.localizedCaseInsensitiveContains(title) == true
                }

                if let reminder = matching.first {
                    reminder.isCompleted = true
                    reminder.completionDate = Date()

                    do {
                        try store.save(reminder, commit: true)
                        continuation.resume(returning: .text("Completed: \(reminder.title ?? title)"))
                    } catch {
                        continuation.resume(returning: .error("Failed to complete reminder: \(error.localizedDescription)"))
                    }
                } else {
                    continuation.resume(returning: .error("No incomplete reminder found matching '\(title)'"))
                }
            }
        }
    }
}

// MARK: - EKReminder Extension

extension EKReminder {
    func toReminderInfo() -> ReminderInfo {
        let dueDate: Date? = dueDateComponents?.date

        return ReminderInfo(
            id: calendarItemIdentifier,
            title: title ?? "Untitled",
            notes: notes,
            dueDate: dueDate,
            isCompleted: isCompleted,
            priority: priority,
            listName: calendar?.title ?? "Reminders"
        )
    }
}

// MARK: - Reminder Info Model

struct ReminderInfo: Identifiable {
    let id: String
    let title: String
    let notes: String?
    let dueDate: Date?
    let isCompleted: Bool
    let priority: Int
    let listName: String

    var priorityText: String {
        switch priority {
        case 1: return "High"
        case 5: return "Medium"
        case 9: return "Low"
        default: return ""
        }
    }

    var dueDateText: String? {
        guard let dueDate = dueDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: dueDate)
    }
}
