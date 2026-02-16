import SwiftUI

// @main entry point. Uses MenuBarExtra with .window style (macOS 14+) to show
// a popover when the user clicks the menu bar icon. LSUIElement=YES in Info.plist
// keeps the app out of the Dock — it lives exclusively in the menu bar.
@main
struct BriefingApp: App {
    // Shared services — created once, passed to views that need them
    @State private var settings = AppSettings()
    @State private var calendarService = CalendarService()
    @State private var thingsService = ThingsService()

    // Request calendar permission at launch so the system dialog appears
    // before the popover — avoids the popover blocking the permission alert.
    init() {
        let service = calendarService
        Task {
            try? await service.requestAccess()
        }
    }

    var body: some Scene {
        // Menu bar icon + popover. The .window style gives us a proper
        // floating panel instead of a cramped NSMenu.
        MenuBarExtra("Briefing", systemImage: "calendar.badge.clock") {
            MenuBarPopover(
                calendarService: calendarService,
                thingsService: thingsService,
                settings: settings
            )
        }
        .menuBarExtraStyle(.window)

        // Settings window — opened via the standard Cmd+, shortcut
        Settings {
            SettingsPlaceholderView(settings: settings)
        }
    }
}

// Minimal settings view for Phase 1 — just the task directory path.
// Will be expanded in Phase 4 with API key, calendar filtering, schedule, etc.
struct SettingsPlaceholderView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Task System") {
                TextField("Task directory path", text: $settings.taskDirectoryPath)
                    .help("Path to iCloud Drive folder containing todo.md")
            }

            Section("Calendar") {
                Stepper(
                    "Minimum free window: \(settings.minimumFreeWindowMinutes) min",
                    value: $settings.minimumFreeWindowMinutes,
                    in: 15...120,
                    step: 15
                )

                Stepper(
                    "Days ahead: \(settings.calendarDaysAhead)",
                    value: $settings.calendarDaysAhead,
                    in: 1...14
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 250)
    }
}
