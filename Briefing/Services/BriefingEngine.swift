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

        // Gather all data in parallel
        async let calendarData = gatherCalendarData(scope: scope)
        async let tasksData = gatherTasksData()
        async let fileData = gatherFileData()

        let calendar = try await calendarData
        let tasks = await tasksData
        let files = try await fileData

        onStatusChange(.callingClaude)

        // Build the prompt from template + data
        let prompt = buildPrompt(
            scope: scope,
            calendar: calendar,
            tasks: tasks,
            files: files
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
        return result
    }

    // MARK: - Data Gathering

    private struct CalendarData {
        let michaelEvents: [CalendarEvent]
        let nooshEvents: [CalendarEvent]
        let conflicts: [ConflictPair]
        let freeWindows: [FreeWindow]
    }

    private func gatherCalendarData(scope: BriefingScope) async throws -> CalendarData {
        let allEvents: [CalendarEvent]
        switch scope {
        case .today:
            allEvents = try await calendarService.fetchTodayEvents()
        case .week:
            allEvents = try await calendarService.fetchWeekEvents(
                daysAhead: settings.calendarDaysAhead
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
        do {
            return try await thingsService.fetchAllTasks()
        } catch {
            // Things 3 not running is expected — don't fail the whole briefing
            return []
        }
    }

    private struct FileData {
        let todoContent: String
        let logTail: String
    }

    private func gatherFileData() async throws -> FileData {
        let todoDoc = try await taskFileService.readTodoFile()
        let todoContent = MarkdownWriter.write(todoDoc)
        let logTail = (try? await taskFileService.readLogTail(lines: 50)) ?? ""
        return FileData(todoContent: todoContent, logTail: logTail)
    }

    // MARK: - Prompt Assembly

    private func buildPrompt(
        scope: BriefingScope,
        calendar: CalendarData,
        tasks: [BriefingTask],
        files: FileData
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

        // todo.md content
        template = template.replacingOccurrences(
            of: "{{TODO_MD}}",
            with: files.todoContent
        )

        // Sync diff (placeholder — will be populated when sync runs before briefing)
        template = template.replacingOccurrences(
            of: "{{SYNC_DIFF}}",
            with: "Sync not run for this briefing."
        )

        // Recent log
        template = template.replacingOccurrences(
            of: "{{RECENT_LOG}}",
            with: files.logTail.isEmpty ? "No recent log entries." : files.logTail
        )

        return template
    }

    // MARK: - Formatters

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

        Current tasks (todo.md):
        {{TODO_MD}}

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
