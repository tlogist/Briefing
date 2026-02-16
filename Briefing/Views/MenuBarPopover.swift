import SwiftUI

// The compact popover shown when clicking the menu bar icon.
// Shows today's events, tasks from Things 3, free windows, and conflicts.
struct MenuBarPopover: View {
    let calendarService: CalendarService
    let thingsService: ThingsService
    let settings: AppSettings

    @State private var michaelEvents: [CalendarEvent] = []
    @State private var nooshEvents: [CalendarEvent] = []
    @State private var freeWindows: [FreeWindow] = []
    @State private var conflicts: [ConflictPair] = []
    @State private var todayTasks: [BriefingTask] = []
    @State private var thingsStatus: ThingsStatus = .unknown
    @State private var isLoading = false
    @State private var errorMessage: String?

    // Track whether Things 3 is available separately from calendar errors
    enum ThingsStatus {
        case unknown, available, notRunning, error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !conflicts.isEmpty {
                            conflictsSection
                        }
                        eventsSection
                        if !freeWindows.isEmpty {
                            freeWindowsSection
                        }
                        tasksSection
                        if !nooshEvents.isEmpty {
                            nooshSection
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
            footer
        }
        .frame(width: 360, height: 520)
        .task {
            await loadAll()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Briefing")
                    .font(.headline)
                Text(DateFormatting.dateReadable.string(from: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { Task { await loadAll() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Menu {
                Button("Settings...") {
                    // Open the Settings window via the standard SwiftUI mechanism.
                    // SettingsLink is macOS 14+ and opens the app's Settings scene.
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)

                Divider()

                Button("Quit Briefing") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "gear")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView("Loading...")
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") { Task { await loadAll() } }
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var conflictsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            ForEach(conflicts) { conflict in
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("\(conflict.event1.title) vs \(conflict.event2.title)")
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today's Schedule")
                .font(.subheadline.weight(.semibold))

            if michaelEvents.isEmpty {
                Text("No events today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(michaelEvents) { event in
                    EventRow(event: event)
                }
            }
        }
    }

    private var freeWindowsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Free Windows", systemImage: "clock.badge.checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)

            ForEach(freeWindows) { window in
                HStack {
                    Text(DateFormatting.timeRange(from: window.startDate, to: window.endDate))
                        .font(.caption)
                    Spacer()
                    Text(DateFormatting.duration(minutes: window.durationMinutes))
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Today's Tasks", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                // Show Things 3 status indicator
                switch thingsStatus {
                case .notRunning:
                    Text("Things 3 not running")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .error:
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }

            switch thingsStatus {
            case .notRunning:
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Launch Things 3 to see tasks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            case .error(let msg):
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            case .available, .unknown:
                if todayTasks.isEmpty {
                    Text("No tasks for today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(todayTasks) { task in
                        TaskRow(task: task)
                    }
                }
            }
        }
    }

    private var nooshSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Noosh's Schedule")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.purple)

            ForEach(nooshEvents) { event in
                EventRow(event: event)
            }
        }
    }

    // MARK: - Data Loading

    private func loadAll() async {
        isLoading = true
        errorMessage = nil

        // Load calendar and tasks in parallel
        async let calendarResult: () = loadCalendar()
        async let tasksResult: () = loadTasks()

        await calendarResult
        await tasksResult

        isLoading = false
    }

    private func loadCalendar() async {
        do {
            let allEvents = try await calendarService.fetchTodayEvents()
            michaelEvents = allEvents.filter { $0.owner == .michael }
            nooshEvents = allEvents.filter { $0.owner == .noosh }
            conflicts = await calendarService.detectConflicts(in: allEvents)
            freeWindows = await calendarService.findFreeWindows(
                in: allEvents,
                minimumMinutes: settings.minimumFreeWindowMinutes
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadTasks() async {
        do {
            todayTasks = try await thingsService.fetchTodayTasks()
            thingsStatus = .available
        } catch {
            // Distinguish "Things 3 not running" from other errors
            // so the UI can show a helpful hint instead of a scary error
            if let thingsError = error as? ThingsError,
               case .notRunning = thingsError {
                thingsStatus = .notRunning
            } else {
                thingsStatus = .error(error.localizedDescription)
            }
            todayTasks = []
        }
    }
}

// MARK: - Event Row Component

struct EventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if event.isAllDay {
                Text("ALL DAY")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 65, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(DateFormatting.time.string(from: event.startDate))
                        .font(.caption2)
                    Text(DateFormatting.time.string(from: event.endDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 65, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.caption)
                    .lineLimit(2)

                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(event.calendarName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Task Row Component

struct TaskRow: View {
    let task: BriefingTask

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(task.isCompleted ? .green : .primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.caption)
                    .lineLimit(2)
                    .strikethrough(task.isCompleted)

                HStack(spacing: 6) {
                    if let project = task.project {
                        Text(project)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if task.isOverdue {
                        Text("\(task.daysOverdue)d overdue")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if let due = task.dueDate {
                        Text("due \(DateFormatting.dayCompact.string(from: due))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
