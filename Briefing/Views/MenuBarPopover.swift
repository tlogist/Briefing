import AppKit
import SwiftUI

// The compact popover shown when clicking the menu bar icon.
// Shows today's events, tasks from Things 3, free windows, and conflicts.
struct MenuBarPopover: View {
    let calendarService: CalendarService
    let thingsService: ThingsService
    let settings: AppSettings
    let briefingEngine: BriefingEngine

    @State private var michaelEvents: [CalendarEvent] = []
    @State private var nooshEvents: [CalendarEvent] = []
    @State private var freeWindows: [FreeWindow] = []
    @State private var conflicts: [ConflictPair] = []
    @State private var todayTasks: [BriefingTask] = []
    @State private var thingsStatus: ThingsStatus = .unknown
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var now = Date()
    @State private var briefingStatus: BriefingStatus = .idle
    // Cache generated briefings per scope so repeated clicks don't re-call Claude
    @State private var briefingCache: [BriefingScope: BriefingResult] = [:]
    @State private var currentScope: BriefingScope = .today

    // Tick every 60 seconds so past-event greying stays current
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

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
                        briefingSection
                        Divider()
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
            // Restore any cached briefings from disk
            for scope in [BriefingScope.today, .week] {
                if let cached = BriefingCache.load(for: scope) {
                    briefingCache[scope] = cached
                }
            }
            await loadAll()
        }
        .onReceive(minuteTimer) { _ in
            now = Date()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Briefing")
                    .font(.headline)
                Text("\(DateFormatting.dateReadable.string(from: now))  \(DateFormatting.time.string(from: now))")
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
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("Quit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)

            Spacer()

            Button(action: {
                // Close the popover, then show Settings as a floating panel.
                // Using a custom NSPanel avoids activating the app, which would
                // blank the system menu bar (LSUIElement has no main menu).
                NSApp.keyWindow?.close()
                SettingsWindowController.shared.show(settings: settings)
            }) {
                Label("Settings", systemImage: "gear")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
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

    /// Collapse conflicts: if one event conflicts with 3+ others,
    /// show a single summary line instead of listing every pair.
    private var conflictsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            ForEach(collapsedConflicts, id: \.self) { line in
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(line)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Build display lines from conflict pairs, collapsing when one event
    /// appears in many conflicts (e.g., "Holiday vs 10 other events").
    private var collapsedConflicts: [String] {
        // Count how many times each event title appears in any conflict
        var counts: [String: Int] = [:]
        for c in conflicts {
            counts[c.event1.title, default: 0] += 1
            counts[c.event2.title, default: 0] += 1
        }

        // Events that appear in 3+ conflicts get collapsed
        let threshold = 3
        let collapsed = Set(counts.filter { $0.value >= threshold }.keys)

        // Track which collapsed events we've already emitted a summary for
        var emitted = Set<String>()
        var lines: [String] = []

        for c in conflicts {
            let e1Collapsed = collapsed.contains(c.event1.title)
            let e2Collapsed = collapsed.contains(c.event2.title)

            if e1Collapsed && !emitted.contains(c.event1.title) {
                lines.append("\(c.event1.title) conflicts with \(counts[c.event1.title]!) other events")
                emitted.insert(c.event1.title)
            } else if e2Collapsed && !emitted.contains(c.event2.title) {
                lines.append("\(c.event2.title) conflicts with \(counts[c.event2.title]!) other events")
                emitted.insert(c.event2.title)
            } else if !e1Collapsed && !e2Collapsed {
                // Neither is collapsed — show the normal pair
                lines.append("\(c.event1.title) vs \(c.event2.title)")
            }
        }
        return lines
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
                    EventRow(event: event, now: now)
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

    private var briefingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch briefingStatus {
            case .idle:
                // Two buttons: today's briefing and week's briefing
                // If a cached result exists, show it; otherwise call Claude
                let hasKey = KeychainService.load(key: KeychainService.Key.anthropicAPIKey) != nil
                HStack(spacing: 8) {
                    Button(action: { showOrGenerate(scope: .today) }) {
                        Label("Today's Briefing", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasKey)

                    Button(action: { showOrGenerate(scope: .week) }) {
                        Label("Week's Briefing", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasKey)
                }
                .frame(maxWidth: .infinity)

                if !hasKey {
                    Text("Set your API key in Settings first")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                }

            case .gatheringData:
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Gathering data...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

            case .callingClaude:
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Claude is analyzing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

            case .complete(let result):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Briefing", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))

                        Button(action: { exportToPDF(result, scope: currentScope) }) {
                            Image(systemName: "arrow.down.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Export as PDF")

                        Spacer()
                        Text(DateFormatting.time.string(from: result.generatedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // Toggle between cached scopes; Refresh forces a new Claude call
                    HStack(spacing: 8) {
                        Button(action: { showOrGenerate(scope: .today) }) {
                            Text("Today")
                                .font(.caption)
                                .fontWeight(currentScope == .today ? .semibold : .regular)
                                .foregroundStyle(currentScope == .today ? .primary : .secondary)
                        }
                        .buttonStyle(.borderless)

                        Button(action: { showOrGenerate(scope: .week) }) {
                            Text("Week")
                                .font(.caption)
                                .fontWeight(currentScope == .week ? .semibold : .regular)
                                .foregroundStyle(currentScope == .week ? .primary : .secondary)
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button(action: { generateBriefing(scope: currentScope) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Regenerate with Claude")
                    }

                    // Render briefing content inline
                    Text(LocalizedStringKey(result.markdownContent))
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .error(let message):
                VStack(spacing: 4) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        Button("Retry Today") { generateBriefing(scope: .today) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Button("Retry Week") { generateBriefing(scope: .week) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Export the briefing to PDF via the system print dialog.
    /// The native dialog includes "Save as PDF" — no custom rendering needed.
    private func exportToPDF(_ result: BriefingResult, scope: BriefingScope) {
        // Close the popover so the print dialog isn't blocked
        NSApp.keyWindow?.close()

        // Build a title like "Briefing - February 16, 2026" or "Briefing - Week of February 16, 2026"
        let dateStr = DateFormatting.dateReadable.string(from: result.generatedAt)
        let title: String
        switch scope {
        case .today: title = "Briefing - \(dateStr)"
        case .week:  title = "Briefing - Week of \(dateStr)"
        }

        // Build an attributed string from the markdown content.
        // NSAttributedString(markdown:) (macOS 12+) handles basic formatting.
        let content: NSAttributedString
        if let attrStr = try? NSAttributedString(
            markdown: result.markdownContent,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            // Apply a readable body font — the default from markdown init is tiny
            let styled = NSMutableAttributedString(attributedString: attrStr)
            styled.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: 12),
                range: NSRange(location: 0, length: styled.length)
            )
            content = styled
        } else {
            content = NSAttributedString(
                string: result.markdownContent,
                attributes: [.font: NSFont.systemFont(ofSize: 12)]
            )
        }

        // Create a text view sized to US Letter with margins
        let printInfo = NSPrintInfo()
        printInfo.topMargin = 72
        printInfo.bottomMargin = 72
        printInfo.leftMargin = 72
        printInfo.rightMargin = 72
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.jobDisposition = .spool
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = title

        let contentWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 0))
        textView.isEditable = false
        textView.textStorage?.setAttributedString(content)
        textView.sizeToFit()

        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        printOp.jobTitle = title
        printOp.run()
    }

    /// Show a cached briefing if available, otherwise generate a new one.
    private func showOrGenerate(scope: BriefingScope) {
        currentScope = scope
        if let cached = briefingCache[scope] {
            briefingStatus = .complete(cached)
        } else {
            generateBriefing(scope: scope)
        }
    }

    /// Always call Claude to generate a fresh briefing (used by refresh buttons).
    private func generateBriefing(scope: BriefingScope) {
        let engine = briefingEngine
        Task {
            do {
                let result = try await engine.generateBriefing(scope: scope) { status in
                    Task { @MainActor in
                        briefingStatus = status
                    }
                }
                await MainActor.run {
                    briefingCache[scope] = result
                    BriefingCache.save(result, for: scope)
                }
            } catch {
                await MainActor.run {
                    briefingStatus = .error(error.localizedDescription)
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
                EventRow(event: event, now: now)
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
            michaelEvents = deduplicateAllDayEvents(allEvents.filter { $0.owner == .michael })
            nooshEvents = deduplicateAllDayEvents(allEvents.filter { $0.owner == .noosh })
            conflicts = await calendarService.detectConflicts(in: allEvents)
            freeWindows = await calendarService.findFreeWindows(
                in: allEvents,
                minimumMinutes: settings.minimumFreeWindowMinutes
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deduplicate all-day events with the same title on the same day.
    /// Multiple calendars often have the same holiday — keep one and note the source.
    /// Timed events are always kept as-is.
    private func deduplicateAllDayEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
        let timed = events.filter { !$0.isAllDay }
        let allDay = events.filter { $0.isAllDay }

        // Group all-day events by normalized title + day
        var seen = Set<String>()
        var dedupedAllDay: [CalendarEvent] = []

        for event in allDay {
            let key = normalizeTitle(event.title)
            if seen.contains(key) { continue }
            seen.insert(key)
            dedupedAllDay.append(event)
        }

        return dedupedAllDay + timed
    }

    /// Normalize a title for dedup: lowercase, strip punctuation/apostrophes.
    /// "Presidents' Day" and "President's Day" both become "presidents day".
    private func normalizeTitle(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
    let now: Date

    // An event is past once its end time has passed (all-day events are never greyed out)
    private var isPast: Bool {
        !event.isAllDay && event.endDate < now
    }

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
                    .strikethrough(isPast)

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
        .foregroundStyle(isPast ? .secondary : .primary)
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
