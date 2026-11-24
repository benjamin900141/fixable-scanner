import EventKit
import Foundation

enum CalendarReader {
    static func postAll(token: String, months: Int) async {
        let store = EKEventStore()
        let allowed = await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
        }
        if !allowed { return }
        let now = Date()
        let start = Calendar.current.date(byAdding: .month, value: -months, to: now) ?? now
        let end = Calendar.current.date(byAdding: .day, value: 366, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        for event in store.events(matching: predicate) {
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if title.isEmpty { continue }
            _ = await Poster.calendar(
                token: token,
                chatKey: event.calendar.calendarIdentifier,
                screenId: event.eventIdentifier,
                title: title,
                start: event.startDate.timeIntervalSince1970 * 1000,
                allDay: event.isAllDay
            )
        }
    }
}
