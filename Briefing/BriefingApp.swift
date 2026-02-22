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
    @State private var scheduler: BriefingScheduler?

    // Request calendar permission at launch so the system dialog appears
    // before the popover — avoids the popover blocking the permission alert.
    init() {
        let service = calendarService
        Task {
            try? await service.requestAccess()
        }
    }

    /// Build the briefing engine from current services. Creates a new
    /// TaskFileService each time since it captures the current settings path.
    private var engine: BriefingEngine {
        BriefingEngine(
            calendarService: calendarService,
            thingsService: thingsService,
            taskFileService: TaskFileService(settings: settings),
            settings: settings
        )
    }

    var body: some Scene {
        // Menu bar icon + popover. The .window style gives us a proper
        // floating panel instead of a cramped NSMenu.
        MenuBarExtra("Briefing", systemImage: "calendar.badge.clock") {
            MenuBarPopover(
                calendarService: calendarService,
                thingsService: thingsService,
                settings: settings,
                briefingEngine: engine,
                scheduler: scheduler
            )
            .task {
                // Start the scheduler once when the app launches.
                // Menu bar apps stay alive indefinitely so this runs for
                // the entire app lifetime.
                if scheduler == nil {
                    let s = BriefingScheduler(
                        settings: settings,
                        calendarService: calendarService,
                        thingsService: thingsService
                    )
                    s.start()
                    scheduler = s
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var scheduler: BriefingScheduler?
    @State private var apiKey: String = ""
    @State private var apiKeySaved = false

    // Bridge Int hour/minute in AppSettings to a Date for DatePicker.
    // DatePicker's .hourAndMinute mode only cares about the time components,
    // so we anchor to an arbitrary reference date (today at midnight).
    private func timeBinding(hour: Binding<Int>, minute: Binding<Int>) -> Binding<Date> {
        Binding<Date>(
            get: {
                Calendar.current.date(
                    bySettingHour: hour.wrappedValue,
                    minute: minute.wrappedValue,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                hour.wrappedValue = components.hour ?? 0
                minute.wrappedValue = components.minute ?? 0
            }
        )
    }

    var body: some View {
        Form {
            Section("Claude API") {
                SecureField("API Key", text: $apiKey, prompt: Text("sk-ant-api03-..."))
                    .help("Your Anthropic API key from console.anthropic.com")
                    .onSubmit { saveAPIKey() }

                HStack {
                    if apiKeySaved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if KeychainService.load(key: KeychainService.Key.anthropicAPIKey) != nil {
                        Label("Key stored in Keychain", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("No key configured", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Save Key") { saveAPIKey() }
                        .disabled(apiKey.isEmpty)
                    if KeychainService.load(key: KeychainService.Key.anthropicAPIKey) != nil {
                        Button("Remove") {
                            KeychainService.delete(key: KeychainService.Key.anthropicAPIKey)
                            apiKey = ""
                            apiKeySaved = false
                        }
                        .foregroundStyle(.red)
                    }
                }

                Picker("Model", selection: $settings.claudeModel) {
                    Text("Claude Sonnet 4.5").tag("claude-sonnet-4-5-20250929")
                    Text("Claude Haiku 4.5").tag("claude-haiku-4-5-20251001")
                    Text("Claude Opus 4.6").tag("claude-opus-4-6")
                }
                .help("Sonnet is recommended — best balance of quality, speed, and cost (~$0.06/briefing)")
            }

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

            Section("Schedule") {
                // --- Daily briefing ---
                Toggle("Daily briefing", isOn: $settings.dailyScheduleEnabled)
                    .onChange(of: settings.dailyScheduleEnabled) {
                        scheduler?.rescheduleDaily()
                    }

                if settings.dailyScheduleEnabled {
                    DatePicker(
                        "Generate at",
                        selection: timeBinding(
                            hour: $settings.dailyScheduleHour,
                            minute: $settings.dailyScheduleMinute
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .onChange(of: settings.dailyScheduleHour) { scheduler?.rescheduleDaily() }
                    .onChange(of: settings.dailyScheduleMinute) { scheduler?.rescheduleDaily() }

                    Text("Generates today's briefing each morning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // --- Weekly briefing ---
                Toggle("Weekly briefing", isOn: $settings.weeklyScheduleEnabled)
                    .onChange(of: settings.weeklyScheduleEnabled) {
                        scheduler?.rescheduleWeekly()
                    }

                if settings.weeklyScheduleEnabled {
                    Picker("Day", selection: $settings.weeklyScheduleDay) {
                        Text("Sunday").tag(1)
                        Text("Monday").tag(2)
                        Text("Tuesday").tag(3)
                        Text("Wednesday").tag(4)
                        Text("Thursday").tag(5)
                        Text("Friday").tag(6)
                        Text("Saturday").tag(7)
                    }
                    .onChange(of: settings.weeklyScheduleDay) { scheduler?.rescheduleWeekly() }

                    DatePicker(
                        "Generate at",
                        selection: timeBinding(
                            hour: $settings.weeklyScheduleHour,
                            minute: $settings.weeklyScheduleMinute
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .onChange(of: settings.weeklyScheduleHour) { scheduler?.rescheduleWeekly() }
                    .onChange(of: settings.weeklyScheduleMinute) { scheduler?.rescheduleWeekly() }

                    Text("Generates the week-ahead briefing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 500)
    }

    private func saveAPIKey() {
        guard !apiKey.isEmpty else { return }
        try? KeychainService.save(key: KeychainService.Key.anthropicAPIKey, value: apiKey)
        apiKeySaved = true
        // Clear the field after saving — the key is in the Keychain now
        apiKey = ""
        // Reset the saved indicator after a moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            apiKeySaved = false
        }
    }
}
