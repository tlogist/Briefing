import Foundation
import EventKit

// Determines whose calendar an event belongs to, based on the calendar name.
// cal:Home = the joint calendar Michael shares with Noosh — there is no
// separate Noosh calendar (confirmed 2026-09-09). Everything else = Michael's.
enum CalendarOwner: String, Sendable, Codable {
    case michael
    case family
    case other

    static func classify(calendarTitle: String) -> CalendarOwner {
        // "Home" calendar is the shared family calendar — show in its own
        // section rather than merging into Michael's timeline
        if calendarTitle.lowercased() == "home" {
            return .family
        }
        return .michael
    }
}

struct CalendarEvent: Identifiable, Sendable, Codable {
    let id: String               // EKEvent.eventIdentifier
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let calendarName: String     // e.g. "Primary", "Home", "Personal"
    let calendarSource: String   // e.g. "Exchange", "iCloud"
    let owner: CalendarOwner

    // Duration in minutes — useful for timeline layout
    var durationMinutes: Int {
        Int(endDate.timeIntervalSince(startDate) / 60)
    }

    init(from ekEvent: EKEvent) {
        self.id = ekEvent.eventIdentifier ?? UUID().uuidString
        self.title = ekEvent.title ?? "(no title)"
        self.startDate = ekEvent.startDate
        self.endDate = ekEvent.endDate
        self.isAllDay = ekEvent.isAllDay
        self.location = ekEvent.location
        self.notes = ekEvent.notes
        self.calendarName = ekEvent.calendar.title
        self.calendarSource = ekEvent.calendar.source?.title ?? "Unknown"
        self.owner = CalendarOwner.classify(calendarTitle: ekEvent.calendar.title)
    }

    // Memberwise init for decoding the popover snapshot (PopoverDataCache)
    init(
        id: String, title: String, startDate: Date, endDate: Date,
        isAllDay: Bool, location: String?, notes: String?,
        calendarName: String, calendarSource: String, owner: CalendarOwner
    ) {
        self.id = id; self.title = title; self.startDate = startDate
        self.endDate = endDate; self.isAllDay = isAllDay; self.location = location
        self.notes = notes; self.calendarName = calendarName
        self.calendarSource = calendarSource; self.owner = owner
    }
}

// A gap between meetings where actual work could get done
struct FreeWindow: Identifiable, Sendable, Codable {
    let id: UUID
    let startDate: Date
    let endDate: Date

    var durationMinutes: Int {
        Int(endDate.timeIntervalSince(startDate) / 60)
    }

    init(startDate: Date, endDate: Date) {
        self.id = UUID()
        self.startDate = startDate
        self.endDate = endDate
    }
}

// Two events that overlap in time
struct ConflictPair: Identifiable, Sendable, Codable {
    let id: UUID
    let event1: CalendarEvent
    let event2: CalendarEvent

    init(event1: CalendarEvent, event2: CalendarEvent) {
        self.id = UUID()
        self.event1 = event1
        self.event2 = event2
    }
}
