import Foundation
import SwiftUI

// Central place for all user-configurable preferences.
// @Observable (macOS 14+) replaces the older ObservableObject pattern —
// SwiftUI automatically tracks which properties each view reads and only
// re-renders when those specific properties change.
@Observable
final class AppSettings {
    // Path to the iCloud Drive folder containing todo.md, todo-log.md, etc.
    var taskDirectoryPath: String {
        didSet { UserDefaults.standard.set(taskDirectoryPath, forKey: "taskDirectoryPath") }
    }

    // Which Claude model to use for briefing generation
    var claudeModel: String {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "claudeModel") }
    }

    // Minimum gap (minutes) to count as a free work window
    var minimumFreeWindowMinutes: Int {
        didSet { UserDefaults.standard.set(minimumFreeWindowMinutes, forKey: "minimumFreeWindowMinutes") }
    }

    // How many days ahead to fetch calendar events
    var calendarDaysAhead: Int {
        didSet { UserDefaults.standard.set(calendarDaysAhead, forKey: "calendarDaysAhead") }
    }

    // Whether to use OAuth (experimental) instead of API key
    var useOAuth: Bool {
        didSet { UserDefaults.standard.set(useOAuth, forKey: "useOAuth") }
    }

    // --- Daily schedule: generates a "today" briefing each morning ---
    var dailyScheduleEnabled: Bool {
        didSet { UserDefaults.standard.set(dailyScheduleEnabled, forKey: "dailyScheduleEnabled") }
    }
    var dailyScheduleHour: Int {
        didSet { UserDefaults.standard.set(dailyScheduleHour, forKey: "dailyScheduleHour") }
    }
    var dailyScheduleMinute: Int {
        didSet { UserDefaults.standard.set(dailyScheduleMinute, forKey: "dailyScheduleMinute") }
    }

    // --- Weekly schedule: generates a "week" briefing (default: Sunday 3 PM) ---
    var weeklyScheduleEnabled: Bool {
        didSet { UserDefaults.standard.set(weeklyScheduleEnabled, forKey: "weeklyScheduleEnabled") }
    }
    var weeklyScheduleDay: Int {  // 1=Sunday, 2=Monday, ..., 7=Saturday
        didSet { UserDefaults.standard.set(weeklyScheduleDay, forKey: "weeklyScheduleDay") }
    }
    var weeklyScheduleHour: Int {
        didSet { UserDefaults.standard.set(weeklyScheduleHour, forKey: "weeklyScheduleHour") }
    }
    var weeklyScheduleMinute: Int {
        didSet { UserDefaults.standard.set(weeklyScheduleMinute, forKey: "weeklyScheduleMinute") }
    }

    init() {
        let defaults = UserDefaults.standard

        // Default to the known iCloud Drive path
        let defaultPath = NSString("~/Library/Mobile Documents/com~apple~CloudDocs/To-Do Briefing")
            .expandingTildeInPath
        self.taskDirectoryPath = defaults.string(forKey: "taskDirectoryPath") ?? defaultPath
        self.claudeModel = defaults.string(forKey: "claudeModel") ?? "claude-sonnet-4-6"
        self.minimumFreeWindowMinutes = defaults.object(forKey: "minimumFreeWindowMinutes") as? Int ?? 45
        self.calendarDaysAhead = defaults.object(forKey: "calendarDaysAhead") as? Int ?? 7
        self.useOAuth = defaults.bool(forKey: "useOAuth")
        self.dailyScheduleEnabled = defaults.bool(forKey: "dailyScheduleEnabled")
        self.dailyScheduleHour = defaults.object(forKey: "dailyScheduleHour") as? Int ?? 6
        self.dailyScheduleMinute = defaults.object(forKey: "dailyScheduleMinute") as? Int ?? 0
        self.weeklyScheduleEnabled = defaults.bool(forKey: "weeklyScheduleEnabled")
        self.weeklyScheduleDay = defaults.object(forKey: "weeklyScheduleDay") as? Int ?? 1
        self.weeklyScheduleHour = defaults.object(forKey: "weeklyScheduleHour") as? Int ?? 15
        self.weeklyScheduleMinute = defaults.object(forKey: "weeklyScheduleMinute") as? Int ?? 0
    }
}
