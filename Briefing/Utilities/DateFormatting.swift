import Foundation

// Shared date formatters. Creating DateFormatter instances is expensive,
// so we cache them as statics. These are thread-safe by default.
enum DateFormatting {
    /// "7:30 AM"
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// "7:30"  (compact, no AM/PM — for tight layouts)
    static let timeCompact: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()

    /// "Monday 02/17"
    static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE MM/dd"
        return f
    }()

    /// "Mon 2/17"
    static let dayCompact: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE M/d"
        return f
    }()

    /// "Feb 17, 2026"
    static let dateReadable: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// "2026-02-17T07:30:00"
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Formats a time range like "7:30 AM - 8:00 AM"
    static func timeRange(from start: Date, to end: Date) -> String {
        "\(time.string(from: start)) – \(time.string(from: end))"
    }

    /// Formats duration in human-readable form: "1h 30m", "45m", "2h"
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 && mins > 0 {
            return "\(hours)h \(mins)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            return "\(mins)m"
        }
    }
}
