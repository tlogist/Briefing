import Foundation
import EventKit

// Determines whose calendar an event belongs to, based on the calendar name.
// cal:Home = the shared Family Calendar (renamed 2026-08-28; it was previously
// treated as Noosh's personal calendar). Everything else = Michael's.
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

    // Cached events (personal-calendar-cache.json on iCloud Drive, popover
    // snapshot) may have been written by a pre-rename build that encoded
    // "noosh". Map it to .family so cross-machine caches keep decoding while
    // the two Macs are on different builds.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "noosh": self = .family
        default:
            guard let value = CalendarOwner(rawValue: raw) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown CalendarOwner value: \(raw)"
                ))
            }
            self = value
        }
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

    // Memberwise init for decoding from cache
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

// MARK: - Personal Calendar Cache (iCloud Drive)

/// Wraps cached personal (iCloud) calendar events with a timestamp so the
/// consuming Mac can show freshness ("cached 2h ago").
struct CachedCalendarData: Codable {
    let events: [CalendarEvent]
    let cachedAt: Date
}

/// Reads/writes iCloud-sourced personal calendar events to a JSON file in the
/// shared iCloud Drive folder. The personal Mac writes; the work Mac reads.
///
/// Follows the same static-enum pattern as PopoverDataCache / BriefingCache.
enum CalendarCache {
    private static let filename = "personal-calendar-cache.json"

    /// Write personal (iCloud) events to the shared cache file.
    static func save(events: [CalendarEvent], to directoryPath: String) {
        let data = CachedCalendarData(events: events, cachedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let jsonData = try? encoder.encode(data) else { return }

        let fileURL = URL(fileURLWithPath: directoryPath)
            .appendingPathComponent(filename)
        try? jsonData.write(to: fileURL, options: .atomic)
    }

    /// Load cached personal events from the shared cache file.
    /// Returns nil if the file doesn't exist or can't be decoded.
    static func load(from directoryPath: String) -> CachedCalendarData? {
        let fileURL = URL(fileURLWithPath: directoryPath)
            .appendingPathComponent(filename)

        guard let jsonData = try? Data(contentsOf: fileURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedCalendarData.self, from: jsonData)
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
