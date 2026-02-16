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

    // Auto-refresh schedule: enabled and time of day
    var scheduleEnabled: Bool {
        didSet { UserDefaults.standard.set(scheduleEnabled, forKey: "scheduleEnabled") }
    }
    var scheduleHour: Int {
        didSet { UserDefaults.standard.set(scheduleHour, forKey: "scheduleHour") }
    }
    var scheduleMinute: Int {
        didSet { UserDefaults.standard.set(scheduleMinute, forKey: "scheduleMinute") }
    }

    init() {
        let defaults = UserDefaults.standard

        // Default to the known iCloud Drive path
        let defaultPath = NSString("~/Library/Mobile Documents/com~apple~CloudDocs/To-Do Briefing")
            .expandingTildeInPath
        self.taskDirectoryPath = defaults.string(forKey: "taskDirectoryPath") ?? defaultPath
        self.claudeModel = defaults.string(forKey: "claudeModel") ?? "claude-sonnet-4-5-20250929"
        self.minimumFreeWindowMinutes = defaults.object(forKey: "minimumFreeWindowMinutes") as? Int ?? 45
        self.calendarDaysAhead = defaults.object(forKey: "calendarDaysAhead") as? Int ?? 7
        self.useOAuth = defaults.bool(forKey: "useOAuth")
        self.scheduleEnabled = defaults.bool(forKey: "scheduleEnabled")
        self.scheduleHour = defaults.object(forKey: "scheduleHour") as? Int ?? 7
        self.scheduleMinute = defaults.object(forKey: "scheduleMinute") as? Int ?? 0
    }
}
