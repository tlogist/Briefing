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
                briefingEngine: engine
            )
        }
        .menuBarExtraStyle(.window)

        // Settings window — opened via the standard Cmd+, shortcut
        Settings {
            SettingsView(settings: settings)
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var apiKey: String = ""
    @State private var apiKeySaved = false

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
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 350)
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
