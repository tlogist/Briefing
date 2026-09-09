import EventKit
import Foundation

// Handles all EventKit interactions: fetching events, detecting conflicts,
// and finding free windows for deep work. This replaces the Swift code that
// ical.py was compiling on-the-fly — now it's native, no compilation step.
//
// Reads are ALWAYS live. There is no cached fallback: this app runs on one
// Mac, and the 2026-09-09 incident showed that a fallback path can only ever
// show wrong data here (see ENGINEERING_INVARIANTS.md, "Single Machine,
// Live Data Only").
//
// Uses actor isolation for thread safety since EventKit's EKEventStore
// is not Sendable but we access it from async contexts.
actor CalendarService {

    // MARK: - Store Lifetime

    /// Build a FRESH EKEventStore for one fetch. Never hold one for the life
    /// of the process: the app once ran six days on a single store, and after
    /// calaccessd (the daemon EventKit talks to, relaunched on demand) had
    /// restarted underneath it, every query returned zero events while a new
    /// store in a shell script saw everything. Nothing was logged. A fresh
    /// store costs a few milliseconds and always has a live daemon connection.
    private func makeStore() async throws -> EKEventStore {
        let store = EKEventStore()

        // Returns immediately once the app has been granted; it only prompts
        // on first use. Full access covers every configured account (iCloud,
        // the MA.com CalDAV account, Google).
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await store.requestFullAccessToEvents()
        } else {
            // Fallback for older macOS — shouldn't hit this with our 14.0 minimum
            granted = try await store.requestAccess(to: .event)
        }
        guard granted else {
            throw CalendarError.accessDenied
        }

        // A healthy Mac always exposes at least the built-in Birthdays and
        // Holidays calendars. Zero calendars means the daemon connection is
        // broken or access was revoked — fail loudly rather than let an empty
        // result pass as "nothing scheduled."
        guard !store.calendars(for: .event).isEmpty else {
            throw CalendarError.noCalendars
        }
        return store
    }

    /// Trigger the system permission dialog early (called at app launch so it
    /// appears before the popover, which would otherwise block the alert).
    /// The store itself is discarded — every fetch builds its own.
    func requestAccess() async throws {
        _ = try await makeStore()
    }

    // MARK: - Fetching Events

    /// Fetch events for a date range from every configured calendar,
    /// sorted chronologically with all-day events first per day.
    func fetchEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEvent] {
        let store = try await makeStore()

        // nil calendars = search ALL calendars across every account
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let ekEvents = store.events(matching: predicate)

        return ekEvents
            .map { CalendarEvent(from: $0) }
            .sorted { lhs, rhs in
                // All-day events sort before timed events on the same day
                if lhs.isAllDay != rhs.isAllDay {
                    return lhs.isAllDay
                }
                return lhs.startDate < rhs.startDate
            }
    }

    /// Fetch today's events.
    func fetchTodayEvents() async throws -> [CalendarEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return try await fetchEvents(from: start, to: end)
    }

    /// Fetch events for the next N days (for weekly briefing).
    func fetchWeekEvents(daysAhead: Int = 7) async throws -> [CalendarEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: daysAhead, to: start)!
        return try await fetchEvents(from: start, to: end)
    }

    // MARK: - Conflict Detection

    /// Find pairs of events that overlap in time.
    /// Excludes all-day events, family-calendar events, holiday calendars, and
    /// "Blocked" time holds (which reserve time for overlapping events,
    /// not compete with them).
    func detectConflicts(in events: [CalendarEvent]) -> [ConflictPair] {
        // Filter to Michael's timed events, excluding holiday/subscription calendars
        // and "Blocked" time holds that protect time rather than represent real meetings
        let timed = events.filter {
            !$0.isAllDay
            && $0.owner == .michael
            && !$0.calendarName.lowercased().contains("holiday")
            && !$0.title.hasPrefix("Blocked")
        }
        var conflicts: [ConflictPair] = []

        for i in 0..<timed.count {
            for j in (i + 1)..<timed.count {
                let a = timed[i]
                let b = timed[j]
                // Two events conflict if one starts before the other ends
                if a.startDate < b.endDate && b.startDate < a.endDate {
                    conflicts.append(ConflictPair(event1: a, event2: b))
                }
            }
        }
        return conflicts
    }

    // MARK: - Free Window Detection

    /// Find gaps between Michael's meetings that are at least `minimumMinutes` long.
    /// Only looks at working hours (7 AM - 7 PM) on each day.
    func findFreeWindows(
        in events: [CalendarEvent],
        minimumMinutes: Int = 45
    ) -> [FreeWindow] {
        let cal = Calendar.current

        // Only Michael's timed events create "busy" blocks
        let busy = events
            .filter { !$0.isAllDay && $0.owner == .michael }
            .sorted { $0.startDate < $1.startDate }

        guard !busy.isEmpty else { return [] }

        // Group events by calendar day
        let grouped = Dictionary(grouping: busy) { event in
            cal.startOfDay(for: event.startDate)
        }

        var windows: [FreeWindow] = []

        for (dayStart, dayEvents) in grouped {
            // Define working hours: 7 AM to 7 PM
            let workStart = cal.date(bySettingHour: 7, minute: 0, second: 0, of: dayStart)!
            let workEnd = cal.date(bySettingHour: 19, minute: 0, second: 0, of: dayStart)!

            // Merge overlapping events into consolidated busy blocks
            let merged = mergeOverlapping(dayEvents)

            // Walk through the day finding gaps
            var cursor = workStart

            for event in merged {
                let eventStart = max(event.startDate, workStart)
                if eventStart > cursor {
                    let gap = FreeWindow(startDate: cursor, endDate: eventStart)
                    if gap.durationMinutes >= minimumMinutes {
                        windows.append(gap)
                    }
                }
                cursor = max(cursor, min(event.endDate, workEnd))
            }

            // Check for a window after the last event
            if cursor < workEnd {
                let gap = FreeWindow(startDate: cursor, endDate: workEnd)
                if gap.durationMinutes >= minimumMinutes {
                    windows.append(gap)
                }
            }
        }

        return windows.sorted { $0.startDate < $1.startDate }
    }

    /// Merge overlapping/adjacent events into continuous busy blocks.
    private func mergeOverlapping(_ events: [CalendarEvent]) -> [(startDate: Date, endDate: Date)] {
        let sorted = events.sorted { $0.startDate < $1.startDate }
        var merged: [(startDate: Date, endDate: Date)] = []

        for event in sorted {
            if let last = merged.last, event.startDate <= last.endDate {
                // Overlaps or is adjacent — extend the current block
                merged[merged.count - 1].endDate = max(last.endDate, event.endDate)
            } else {
                merged.append((startDate: event.startDate, endDate: event.endDate))
            }
        }
        return merged
    }

    // MARK: - List Available Calendars

    /// Returns all calendar names and their sources — useful for settings/debugging.
    func listCalendars() async throws -> [(title: String, source: String)] {
        let store = try await makeStore()
        return store.calendars(for: .event)
            .sorted { $0.source?.title ?? "" < $1.source?.title ?? "" }
            .map { (title: $0.title, source: $0.source?.title ?? "Unknown") }
    }
}

// MARK: - Errors

enum CalendarError: LocalizedError {
    case accessDenied
    case noCalendars

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access denied. Open System Settings > Privacy & Security > Calendars and grant access to Briefing."
        case .noCalendars:
            return "EventKit returned no calendars. Calendar access may have been revoked or the calendar daemon is unavailable — check System Settings > Privacy & Security > Calendars, then retry."
        }
    }
}
