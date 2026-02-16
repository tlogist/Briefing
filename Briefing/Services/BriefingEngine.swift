import Foundation

// The orchestrator. Gathers data from all sources in parallel,
// assembles the prompt, calls Claude, and returns a BriefingResult.
// Runs as an actor for thread-safe state management.
actor BriefingEngine {
    private let calendarService: CalendarService
    private let thingsService: ThingsService
    private let taskFileService: TaskFileService
    private let claudeAPIService: ClaudeAPIService
    private let settings: AppSettings

    init(
        calendarService: CalendarService,
        thingsService: ThingsService,
        taskFileService: TaskFileService,
        claudeAPIService: ClaudeAPIService = ClaudeAPIService(),
        settings: AppSettings
    ) {
        self.calendarService = calendarService
        self.thingsService = thingsService
        self.taskFileService = taskFileService
        self.claudeAPIService = claudeAPIService
        self.settings = settings
    }

    // MARK: - Generate Briefing

    /// Run the full briefing pipeline: gather data → build prompt → call Claude.
    /// Scope controls whether we fetch today's events or the full week.
    func generateBriefing(
        scope: BriefingScope = .today,
        onStatusChange: @Sendable (BriefingStatus) -> Void
    ) async throws -> BriefingResult {

        onStatusChange(.gatheringData)

        // Gather all data in parallel — Things 3 is the sole task source
        async let calendarData = gatherCalendarData(scope: scope)
        async let tasksData = gatherTasksData()
        async let logData = gatherLogData()

        let calendar = try await calendarData
        let tasks = await tasksData
        let logTail = await logData

        onStatusChange(.callingClaude)

        // Build the prompt from template + data
        let prompt = buildPrompt(
            scope: scope,
            calendar: calendar,
            tasks: tasks,
            logTail: logTail
        )

        // Call Claude
        let response = try await claudeAPIService.sendMessage(
            prompt: prompt,
            model: settings.claudeModel,
            maxTokens: 4096
        )

        let result = BriefingResult(
            generatedAt: Date(),
            markdownContent: response,
            model: settings.claudeModel,
            promptTokens: nil,
            responseTokens: nil,
            michaelEventCount: calendar.michaelEvents.count,
            nooshEventCount: calendar.nooshEvents.count,
            conflictCount: calendar.conflicts.count,
            freeWindowCount: calendar.freeWindows.count,
            taskCount: tasks.count,
            syncDiffCount: 0,
            // Fingerprint today's tasks only — this is what the popover can compare
            // against to detect staleness (it only has today's tasks loaded)
            taskFingerprint: BriefingResult.fingerprint(
                from: tasks.filter { $0.list == .today }
            )
        )

        onStatusChange(.complete(result))

        // Export current Things 3 tasks to todo.md as an archive/reference copy.
        // This runs after the briefing so it never blocks or feeds stale data
        // back into the prompt — Things 3 is the source of truth.
        let dirPath = settings.taskDirectoryPath
        Task.detached {
            Self.exportTasksToFile(tasks: tasks, directoryPath: dirPath)
        }

        return result
    }

    /// Write a snapshot of Things 3 tasks to todo.md so there's a readable
    /// file on disk. This is a one-way export — the file is never read back
    /// into the briefing prompt.
    private static func exportTasksToFile(
        tasks: [BriefingTask],
        directoryPath: String
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd h:mm a zzz"
        let timestamp = formatter.string(from: Date())

        var lines: [String] = [
            "# Michael's Task System",
            "",
            "> **Exported from Things 3:** \(timestamp)",
            "> This file is auto-generated from Things 3 — do not edit manually.",
            "",
            "---",
            ""
        ]

        // Group tasks by list
        let listOrder: [TaskList] = [.today, .inbox, .upcoming, .anytime, .someday]
        let listEmoji: [TaskList: String] = [
            .today: "🔴", .inbox: "📥", .upcoming: "📆",
            .anytime: "🟡", .someday: "🔵"
        ]

        for list in listOrder {
            let listTasks = tasks.filter { $0.list == list && !$0.isCompleted }
            guard !listTasks.isEmpty else { continue }

            let emoji = listEmoji[list] ?? ""
            lines.append("## \(emoji) \(list.rawValue)")
            lines.append("")

            // Group by project within each list
            let withProject = listTasks.filter { $0.project != nil }
            let withoutProject = listTasks.filter { $0.project == nil }

            for task in withoutProject {
                lines.append(formatExportTask(task))
            }

            let byProject = Dictionary(grouping: withProject) { $0.project! }
            for projectName in byProject.keys.sorted() {
                lines.append("")
                lines.append("### \(projectName)")
                for task in byProject[projectName]! {
                    lines.append(formatExportTask(task))
                }
            }

            lines.append("")
            lines.append("---")
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        let fileURL = URL(fileURLWithPath: directoryPath).appendingPathComponent("todo.md")
        try? content.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    private static func formatExportTask(_ task: BriefingTask) -> String {
        var line = "- [ ] \(task.name)"
        if let due = task.dueDate {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE M/d"
            line += " *(due \(fmt.string(from: due)))*"
        }
        return line
    }

    // MARK: - Data Gathering

    private struct CalendarData {
        let michaelEvents: [CalendarEvent]
        let nooshEvents: [CalendarEvent]
        let conflicts: [ConflictPair]
        let freeWindows: [FreeWindow]
    }

    private func gatherCalendarData(scope: BriefingScope) async throws -> CalendarData {
        let cachePath = settings.taskDirectoryPath
        let allEvents: [CalendarEvent]
        switch scope {
        case .today:
            allEvents = try await calendarService.fetchTodayEventsWithCache(
                cacheDirectoryPath: cachePath
            )
        case .week:
            allEvents = try await calendarService.fetchWeekEventsWithCache(
                daysAhead: settings.calendarDaysAhead,
                cacheDirectoryPath: cachePath
            )
        }
        let michael = allEvents.filter { $0.owner == .michael }
        let noosh = allEvents.filter { $0.owner == .noosh }
        let conflicts = await calendarService.detectConflicts(in: allEvents)
        let freeWindows = await calendarService.findFreeWindows(
            in: allEvents,
            minimumMinutes: settings.minimumFreeWindowMinutes
        )
        return CalendarData(
            michaelEvents: michael,
            nooshEvents: noosh,
            conflicts: conflicts,
            freeWindows: freeWindows
        )
    }

    private func gatherTasksData() async -> [BriefingTask] {
        await thingsService.fetchAllTasksWithCache(
            cacheDirectoryPath: settings.taskDirectoryPath
        )
    }

    /// Only reads the activity log now — tasks come from Things 3 directly.
    private func gatherLogData() async -> String {
        (try? await taskFileService.readLogTail(lines: 50)) ?? ""
    }

    // MARK: - Prompt Assembly

    private func buildPrompt(
        scope: BriefingScope,
        calendar: CalendarData,
        tasks: [BriefingTask],
        logTail: String
    ) -> String {
        // Load the template
        var template: String
        if let url = Bundle.main.url(forResource: "BriefingPrompt", withExtension: "txt"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            template = content
        } else {
            // Fallback if the resource isn't found
            template = fallbackPromptTemplate()
        }

        // Adjust the calendar heading based on scope
        template = template.replacingOccurrences(
            of: "## Calendar Events (Next 7 Days)",
            with: "## \(scope.calendarHeading)"
        )

        // Date
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        template = template.replacingOccurrences(of: "{{DATE}}", with: dateFormatter.string(from: Date()))

        // Michael's events
        template = template.replacingOccurrences(
            of: "{{MICHAEL_EVENTS}}",
            with: formatEvents(calendar.michaelEvents)
        )

        // Noosh's events
        template = template.replacingOccurrences(
            of: "{{NOOSH_EVENTS}}",
            with: calendar.nooshEvents.isEmpty ? "No events" : formatEvents(calendar.nooshEvents)
        )

        // Conflicts
        template = template.replacingOccurrences(
            of: "{{CONFLICTS}}",
            with: calendar.conflicts.isEmpty ? "None" : formatConflicts(calendar.conflicts)
        )

        // Free windows
        template = template.replacingOccurrences(
            of: "{{FREE_WINDOWS}}",
            with: calendar.freeWindows.isEmpty ? "None identified" : formatFreeWindows(calendar.freeWindows)
        )

        // Things 3 tasks — live from the app, grouped by list
        template = template.replacingOccurrences(
            of: "{{THINGS3_TASKS}}",
            with: tasks.isEmpty ? "No tasks (Things 3 may not be running)" : formatTasks(tasks)
        )

        // Recent activity log
        template = template.replacingOccurrences(
            of: "{{RECENT_LOG}}",
            with: logTail.isEmpty ? "No recent log entries." : logTail
        )

        return template
    }

    // MARK: - Formatters

    private func formatTasks(_ tasks: [BriefingTask]) -> String {
        var lines: [String] = []
        let listOrder: [TaskList] = [.today, .inbox, .upcoming, .anytime, .someday]

        for list in listOrder {
            let listTasks = tasks.filter { $0.list == list && !$0.isCompleted }
            guard !listTasks.isEmpty else { continue }

            lines.append("**\(list.rawValue)** (\(listTasks.count) tasks)")

            // Group by project
            let withProject = listTasks.filter { $0.project != nil }
            let withoutProject = listTasks.filter { $0.project == nil }

            for task in withoutProject {
                lines.append(formatSingleTask(task))
            }

            let byProject = Dictionary(grouping: withProject) { $0.project! }
            for projectName in byProject.keys.sorted() {
                lines.append("  *\(projectName):*")
                for task in byProject[projectName]! {
                    lines.append(formatSingleTask(task, indent: true))
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func formatSingleTask(_ task: BriefingTask, indent: Bool = false) -> String {
        let prefix = indent ? "    - " : "- "
        var line = prefix + task.name
        var meta: [String] = []
        if let due = task.dueDate {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE M/d"
            meta.append("due \(fmt.string(from: due))")
        }
        if task.isOverdue {
            meta.append("\(task.daysOverdue)d overdue")
        }
        if let notes = task.notes, !notes.isEmpty {
            // Include first line of notes for context
            let firstLine = notes.components(separatedBy: "\n").first ?? ""
            if !firstLine.isEmpty {
                meta.append("notes: \(firstLine)")
            }
        }
        if !task.tags.isEmpty {
            meta.append("tags: \(task.tags.joined(separator: ", "))")
        }
        if !meta.isEmpty {
            line += " *(\(meta.joined(separator: "; ")))*"
        }
        return line
    }

    private func formatEvents(_ events: [CalendarEvent]) -> String {
        if events.isEmpty { return "No events" }

        // Group by day
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: events) { event in
            calendar.startOfDay(for: event.startDate)
        }

        var lines: [String] = []
        for day in grouped.keys.sorted() {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEEE, MMM d"
            lines.append("**\(dayFormatter.string(from: day))**")

            let dayEvents = grouped[day]!.sorted { $0.startDate < $1.startDate }
            for event in dayEvents {
                if event.isAllDay {
                    lines.append("- ALL DAY: \(event.title) [\(event.calendarName)]")
                } else {
                    let start = DateFormatting.time.string(from: event.startDate)
                    let end = DateFormatting.time.string(from: event.endDate)
                    var line = "- \(start)–\(end): \(event.title) [\(event.calendarName)]"
                    if let loc = event.location, !loc.isEmpty {
                        line += " @ \(loc)"
                    }
                    lines.append(line)
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func formatConflicts(_ conflicts: [ConflictPair]) -> String {
        conflicts.map { conflict in
            let time1 = DateFormatting.time.string(from: conflict.event1.startDate)
            let time2 = DateFormatting.time.string(from: conflict.event2.startDate)
            return "- \(conflict.event1.title) (\(time1)) overlaps with \(conflict.event2.title) (\(time2))"
        }.joined(separator: "\n")
    }

    private func formatFreeWindows(_ windows: [FreeWindow]) -> String {
        windows.map { window in
            let start = DateFormatting.time.string(from: window.startDate)
            let end = DateFormatting.time.string(from: window.endDate)
            return "- \(start)–\(end) (\(window.durationMinutes) min)"
        }.joined(separator: "\n")
    }

    private func fallbackPromptTemplate() -> String {
        """
        Today is {{DATE}}.

        Here are Michael's calendar events for the week:
        {{MICHAEL_EVENTS}}

        Noosh's schedule:
        {{NOOSH_EVENTS}}

        Conflicts: {{CONFLICTS}}
        Free windows: {{FREE_WINDOWS}}

        Current tasks (from Things 3):
        {{THINGS3_TASKS}}

        Recent activity:
        {{RECENT_LOG}}

        Please produce a concise daily briefing covering:
        1. Calendar at a glance
        2. Top 3-5 priorities for today
        3. Waiting-on items
        4. Stale/overdue flags
        5. Capacity assessment given today's calendar
        """
    }
}
