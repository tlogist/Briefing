import EventKit
import Foundation

// Handles all EventKit interactions: fetching events, detecting conflicts,
// and finding free windows for deep work. This replaces the Swift code that
// ical.py was compiling on-the-fly — now it's native, no compilation step.
//
// Uses actor isolation for thread safety since EventKit's EKEventStore
// is not Sendable but we access it from async contexts.
actor CalendarService {
    private let store = EKEventStore()
    private var accessGranted = false

    /// Non-nil when the last fetch used cached personal events (i.e., this Mac
    /// has no active iCloud calendar events). The UI reads this to show freshness.
    private(set) var lastPersonalCalCacheDate: Date?

    // MARK: - Authorization

    /// Request calendar access. On macOS 14+ this uses requestFullAccessToEvents
    /// which grants read access to ALL calendars (iCloud + synced Exchange/Google).
    func requestAccess() async throws {
        if accessGranted { return }

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
        accessGranted = true
    }

    // MARK: - Fetching Events

    /// Fetch events for a date range, classified by calendar owner.
    /// Returns events sorted chronologically with all-day events first per day.
    func fetchEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEvent] {
        try await requestAccess()

        // nil calendars = search ALL calendars (iCloud personal + synced work)
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

    // MARK: - Personal Calendar Cache

    /// Calendar sources that only exist on the personal Mac. Events from these
    /// sources get cached to iCloud Drive so the work Mac can display them.
    /// Add new personal-only sources here as needed.
    private static let personalSources: Set<String> = [
        "iCloud",
        "Bendicoot",
        "Planning Board"
    ]

    /// Fetch events with transparent personal calendar caching.
    ///
    /// Detection is EVENT-BASED, not source-based. Both Macs may have iCloud
    /// configured in Apple Calendar, but only the personal Mac has actual events
    /// in personal-only sources (iCloud, Bendicoot, Planning Board). We scan a
    /// 14-day window for events from any personal source:
    ///
    ///   - If personal events exist → write cache
    ///   - If no personal events    → read cache and merge
    func fetchEventsWithPersonalCache(
        from start: Date,
        to end: Date,
        cacheDirectoryPath: String
    ) async throws -> [CalendarEvent] {
        let liveEvents = try await fetchEvents(from: start, to: end)

        // Check the full 14-day window for events from personal-only sources.
        // This is the reliable signal — store.sources can't distinguish
        // "iCloud configured with events" from "iCloud configured but blank."
        let cal = Calendar.current
        let cacheStart = cal.startOfDay(for: Date())
        let cacheEnd = cal.date(byAdding: .day, value: 14, to: cacheStart)!
        let windowEvents = try await fetchEvents(from: cacheStart, to: cacheEnd)
        let personalEvents = windowEvents.filter {
            Self.personalSources.contains($0.calendarSource)
        }

        if !personalEvents.isEmpty {
            // This Mac has active personal calendars — write cache
            CalendarCache.save(events: personalEvents, to: cacheDirectoryPath)
            lastPersonalCalCacheDate = nil
            return liveEvents
        } else {
            // No active iCloud events — read cache and merge
            guard let cached = CalendarCache.load(from: cacheDirectoryPath) else {
                lastPersonalCalCacheDate = nil
                return liveEvents
            }

            lastPersonalCalCacheDate = cached.cachedAt

            // Filter cached events to the requested date range
            let relevantCached = cached.events.filter {
                $0.startDate >= start && $0.startDate < end
            }

            // Merge and sort: all-day first, then chronologically
            return (liveEvents + relevantCached).sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay {
                    return lhs.isAllDay
                }
                return lhs.startDate < rhs.startDate
            }
        }
    }

    /// Convenience: fetch today's events with personal calendar cache.
    func fetchTodayEventsWithCache(
        cacheDirectoryPath: String
    ) async throws -> [CalendarEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return try await fetchEventsWithPersonalCache(
            from: start, to: end, cacheDirectoryPath: cacheDirectoryPath
        )
    }

    /// Convenience: fetch week events with personal calendar cache.
    func fetchWeekEventsWithCache(
        daysAhead: Int = 7,
        cacheDirectoryPath: String
    ) async throws -> [CalendarEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: daysAhead, to: start)!
        return try await fetchEventsWithPersonalCache(
            from: start, to: end, cacheDirectoryPath: cacheDirectoryPath
        )
    }

    // MARK: - Conflict Detection

    /// Find pairs of events that overlap in time.
    /// Excludes all-day events, Noosh's events, and holiday calendars.
    func detectConflicts(in events: [CalendarEvent]) -> [ConflictPair] {
        // Filter to Michael's timed events, excluding holiday/subscription calendars
        let timed = events.filter {
            !$0.isAllDay
            && $0.owner == .michael
            && !$0.calendarName.lowercased().contains("holiday")
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
        try await requestAccess()
        return store.calendars(for: .event)
            .sorted { $0.source?.title ?? "" < $1.source?.title ?? "" }
            .map { (title: $0.title, source: $0.source?.title ?? "Unknown") }
    }
}

// MARK: - Errors

enum CalendarError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access denied. Open System Settings > Privacy & Security > Calendars and grant access to Briefing."
        }
    }
}
