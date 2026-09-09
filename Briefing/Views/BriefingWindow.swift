import AppKit
import SwiftUI

// The full Briefing workbench: a real, resizable window for task engagement,
// opened from the popover's "Open Briefing" button. The popover stays the
// compact glance surface; this window is where you work the system —
// schedule on the left, the task workbench (all lists, quick-add, Tidy Up)
// on the right, with a window-scoped Claude chat below the tasks.
//
// A resizable panel at normal window level — a workbench, not a HUD.
// Unlike SettingsWindowController's panel, this one is ACTIVATING: with
// `.nonactivatingPanel`, macOS refuses to activate the app when the window
// is selected in Exposé/Mission Control, then hands focus back to the
// previously active app — whose window gets re-raised over ours ("comes
// forward, then jumps one back"). Verified empirically 2026-09-02: an AX
// raise leaves the app un-activatable (`frontmost` stays false) while the
// panel is nonactivating. Activation is safe here — SwiftUI's App lifecycle
// gives Briefing a real main menu, so the menu bar shows Briefing's menus
// rather than blanking (see ENGINEERING_INVARIANTS).
private final class WorkbenchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class BriefingWindowController {
    static let shared = BriefingWindowController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var activationObserver: NSObjectProtocol?

    private init() {
        // Fires when the system activates us (Exposé selection, or a click
        // in the workbench). AppKit's own ordering during activation can
        // leave the panel behind the previously frontmost window, so
        // re-assert front on the next runloop tick.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let panel = self?.panel, panel.isVisible else { return }
            DispatchQueue.main.async {
                panel.orderFrontRegardless()
                panel.makeKey()
            }
        }
    }

    func show(
        calendarService: CalendarService,
        thingsService: ThingsService,
        settings: AppSettings,
        briefingEngine: BriefingEngine
    ) {
        if let existing = panel, existing.isVisible {
            existing.orderFrontRegardless()
            return
        }

        let view = BriefingWindowView(
            calendarService: calendarService,
            thingsService: thingsService,
            settings: settings,
            briefingEngine: briefingEngine
        )
        let hostingView = NSHostingView(rootView: AnyView(view))
        self.hostingView = hostingView

        let panel = WorkbenchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Briefing"
        panel.contentView = hostingView
        panel.minSize = NSSize(width: 760, height: 520)
        panel.level = .normal            // workbench, not an always-on-top HUD
        panel.hidesOnDeactivate = false  // panels default to hiding — keep it around
        panel.isReleasedWhenClosed = false
        panel.center()

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
        hostingView = nil
    }
}

// MARK: - Window Content

struct BriefingWindowView: View {
    let calendarService: CalendarService
    let thingsService: ThingsService
    let settings: AppSettings
    let briefingEngine: BriefingEngine

    // Calendar state
    @State private var michaelEvents: [CalendarEvent] = []
    @State private var familyEvents: [CalendarEvent] = []
    @State private var conflicts: [ConflictPair] = []
    @State private var freeWindows: [FreeWindow] = []
    @State private var calendarDayOffset = 0

    // Task workbench state
    @State private var allTasks: [BriefingTask] = []
    @State private var selectedList: TaskList = .today
    @State private var tagNames: [String] = []
    @State private var writesEnabled = false
    @State private var tasksInFlight: Set<String> = []
    @State private var taskActionError: String?
    @State private var newTaskTitle = ""
    @State private var isAddingTask = false
    @State private var showTidyUp = false
    @State private var isRefreshing = false

    // Briefing state (window-scoped view over the same shared iCloud cache)
    @State private var briefingStatus: BriefingStatus = .idle
    @State private var briefingCache: [BriefingScope: BriefingResult] = [:]
    @State private var currentScope: BriefingScope = .today

    // Window-scoped chat conversation (independent of the popover's)
    @State private var chatInput = ""
    @State private var chatMessages: [ChatDisplayMessage] = []
    @State private var chatHistory: [[String: Any]] = []
    @State private var isChatting = false

    @State private var now = Date()
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        HSplitView {
            schedulePane
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            taskPane
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await loadAll() }
        .onReceive(minuteTimer) { _ in now = Date() }
    }

    // MARK: - Left: Briefing + Schedule

    private var schedulePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Briefing")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(DateFormatting.dateReadable.string(from: now))  \(DateFormatting.time.string(from: now))")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                }
                Spacer()
                if isRefreshing {
                    ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
                }
                Button(action: { Task { await loadAll() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh calendars and tasks")
                Button(action: {
                    SettingsWindowController.shared.show(settings: settings)
                }) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    briefingSection
                    Divider()
                    scheduleSection
                    if !freeWindows.isEmpty {
                        freeWindowsSection
                    }
                    if !familyEvents.isEmpty {
                        familySection
                    }
                }
                .padding(12)
            }
        }
    }

    private var briefingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch briefingStatus {
            case .idle:
                let hasKey = KeychainService.load(key: KeychainService.Key.anthropicAPIKey) != nil
                HStack(spacing: 8) {
                    Button(action: { showOrGenerate(scope: .today) }) {
                        Label("Today", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasKey)
                    Button(action: { showOrGenerate(scope: .tomorrow) }) {
                        Label("Tomorrow", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasKey)
                    Button(action: { showOrGenerate(scope: .week) }) {
                        Label("Week", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasKey)
                }
                if !hasKey {
                    Text("Set your API key in Settings first")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }

            case .gatheringData, .callingClaude:
                HStack {
                    ProgressView().scaleEffect(0.6)
                    Text(briefingStatus == .gatheringData ? "Gathering data…" : "Claude is analyzing…")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

            case .complete(let result):
                HStack(spacing: 8) {
                    ForEach([BriefingScope.today, .tomorrow, .week], id: \.self) { scope in
                        Button(action: { showOrGenerate(scope: scope) }) {
                            Text(scopeLabel(scope))
                                .font(.system(size: 14))
                                .fontWeight(currentScope == scope ? .semibold : .regular)
                                .foregroundStyle(currentScope == scope ? .primary : .secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button(action: { generateBriefing(scope: currentScope) }) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .help("Regenerate with Claude")
                }
                Text(LocalizedStringKey(result.markdownContent))
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

            case .error(let message):
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
                Button("Retry") { generateBriefing(scope: currentScope) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 14))
            }
        }
    }

    private func scopeLabel(_ scope: BriefingScope) -> String {
        switch scope {
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .week: return "Week"
        }
    }

    private var scheduleHeading: String {
        switch calendarDayOffset {
        case 0: return "Today's Schedule"
        case 1: return "Tomorrow's Schedule"
        case -1: return "Yesterday's Schedule"
        default:
            let cal = Calendar.current
            let target = cal.date(byAdding: .day, value: calendarDayOffset, to: cal.startOfDay(for: Date()))!
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: target)
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(scheduleHeading)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: {
                    calendarDayOffset -= 1
                    Task { await loadCalendar() }
                }) {
                    Image(systemName: "chevron.left").font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                Button(action: {
                    calendarDayOffset += 1
                    Task { await loadCalendar() }
                }) {
                    Image(systemName: "chevron.right").font(.system(size: 14))
                }
                .buttonStyle(.borderless)
            }

            if !conflicts.isEmpty {
                Label("\(conflicts.count) scheduling conflict\(conflicts.count == 1 ? "" : "s")",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
            }

            if michaelEvents.isEmpty {
                Text("No events")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(michaelEvents) { event in
                    EventRow(event: event, now: now, compact: false)
                }
            }
        }
    }

    private var freeWindowsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Free Windows", systemImage: "clock.badge.checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            ForEach(freeWindows) { window in
                HStack {
                    Text(DateFormatting.timeRange(from: window.startDate, to: window.endDate))
                        .font(.system(size: 14))
                    Spacer()
                    Text(DateFormatting.duration(minutes: window.durationMinutes))
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var familySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Family Calendar")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.purple)
            ForEach(familyEvents) { event in
                EventRow(event: event, now: now, compact: false)
            }
        }
    }

    // MARK: - Right: Task Workbench

    private var tasksInSelectedList: [BriefingTask] {
        allTasks.filter { $0.list == selectedList && !$0.isCompleted }
    }

    private func count(for list: TaskList) -> Int {
        allTasks.filter { $0.list == list && !$0.isCompleted }.count
    }

    private var taskPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Tasks", systemImage: "checkmark.circle")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if writesEnabled && KeychainService.load(key: KeychainService.Key.anthropicAPIKey) != nil {
                    Button(action: { showTidyUp = true }) {
                        Label("Tidy Up", systemImage: "wand.and.stars")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.bordered)
                    .help("Have Claude propose maintenance actions (you approve each)")
                }
            }
            .padding(12)

            Picker("", selection: $selectedList) {
                ForEach(TaskList.allCases, id: \.self) { list in
                    Text("\(list.rawValue) (\(count(for: list)))").tag(list)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if showTidyUp {
                        MaintenanceSection(
                            thingsService: thingsService,
                            settings: settings,
                            tagNames: tagNames,
                            onApplied: { Task { await loadTasks() } },
                            onDismiss: { showTidyUp = false },
                            compact: false
                        )
                        .padding(.bottom, 4)
                    }

                    if let error = taskActionError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }

                    if tasksInSelectedList.isEmpty {
                        Text("No open tasks in \(selectedList.rawValue)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(tasksInSelectedList) { task in
                            TaskRow(
                                task: task,
                                isBusy: tasksInFlight.contains(task.id),
                                onComplete: writesEnabled ? { completeTask(task) } : nil,
                                onAction: writesEnabled ? { performTaskAction($0, on: task) } : nil,
                                availableTags: tagNames,
                                compact: false
                            )
                        }
                    }

                    if writesEnabled {
                        HStack(spacing: 8) {
                            Image(systemName: isAddingTask ? "circle.dotted" : "plus.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                            TextField("Add to \(selectedList.rawValue)…", text: $newTaskTitle)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .onSubmit { addTask() }
                                .disabled(isAddingTask)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(12)
            }

            Divider()
            chatSection
        }
    }

    // MARK: - Chat (window-scoped conversation)

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chatMessages.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(chatMessages) { message in
                            ChatBubble(message: message, compact: false)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .frame(maxHeight: 180)
            }

            HStack(spacing: 4) {
                TextField("Ask Claude…", text: $chatInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .lineLimit(1...4)
                    .onSubmit { sendChatMessage() }
                    .disabled(isChatting)
                if isChatting {
                    ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func sendChatMessage() {
        let input = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        chatInput = ""
        chatMessages.append(ChatDisplayMessage(role: .user, content: input))
        chatHistory.append(["role": "user", "content": input])
        isChatting = true

        let service = ClaudeAPIService()
        let things = thingsService
        let system = buildChatSystemPrompt()
        // Reuse the popover's tool definitions + executor — same Things
        // channel, so anything Claude does here is verified the same way
        let tools = MenuBarPopover.chatTools
        var history = chatHistory
        let model = settings.claudeModel

        Task {
            do {
                var allText: [String] = []
                while true {
                    let response = try await service.sendChat(
                        messages: history,
                        system: system,
                        model: model,
                        maxTokens: 1024,
                        tools: tools
                    )
                    if !response.textContent.isEmpty {
                        allText.append(response.textContent)
                    }
                    history.append(["role": "assistant", "content": response.contentBlocks])

                    if response.stopReason == "tool_use" && !response.toolUses.isEmpty {
                        var toolResults: [[String: Any]] = []
                        for toolUse in response.toolUses {
                            let result = await MenuBarPopover.executeTool(
                                name: toolUse.name,
                                input: toolUse.input,
                                thingsService: things
                            )
                            toolResults.append([
                                "type": "tool_result",
                                "tool_use_id": toolUse.id,
                                "content": result
                            ])
                        }
                        history.append(["role": "user", "content": toolResults])
                        continue
                    }
                    break
                }

                let finalText = allText.joined(separator: "\n\n")
                await MainActor.run {
                    chatHistory = history
                    if !finalText.isEmpty {
                        chatMessages.append(ChatDisplayMessage(role: .assistant, content: finalText))
                    }
                    isChatting = false
                }
                await loadTasks()
            } catch {
                await MainActor.run {
                    chatHistory = history
                    chatMessages.append(ChatDisplayMessage(
                        role: .assistant,
                        content: "Error: \(error.localizedDescription)"
                    ))
                    isChatting = false
                }
            }
        }
    }

    private func buildChatSystemPrompt() -> String {
        var parts: [String] = [
            "You are a concise task management assistant for Michael Ammaturo.",
            "Today is \(DateFormatting.dateReadable.string(from: Date())).",
            "Keep responses brief. Use tools when asked to add or complete tasks."
        ]
        let todayTasks = allTasks.filter { $0.list == .today && !$0.isCompleted }
        if !todayTasks.isEmpty {
            let lines = todayTasks.map { "- \($0.name)" + ($0.project.map { " (\($0))" } ?? "") }
            parts.append("\nToday's tasks:\n" + lines.joined(separator: "\n"))
        }
        if !michaelEvents.isEmpty {
            let lines = michaelEvents.map { event -> String in
                if event.isAllDay { return "- ALL DAY: \(event.title)" }
                return "- \(DateFormatting.time.string(from: event.startDate))–\(DateFormatting.time.string(from: event.endDate)): \(event.title)"
            }
            parts.append("\nToday's calendar:\n" + lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Data Loading

    private func loadAll() async {
        isRefreshing = true
        async let calendarResult: () = loadCalendar()
        async let tasksResult: () = loadTasks()
        await calendarResult
        await tasksResult
        isRefreshing = false

        // Fill briefing slots from the iCloud Drive briefing files (generated
        // by the scheduler or the popover; they persist across relaunches)
        for scope in [BriefingScope.today, .tomorrow, .week] {
            if briefingCache[scope] == nil,
               let cached = BriefingCache.load(for: scope, directoryPath: settings.taskDirectoryPath) {
                briefingCache[scope] = cached
            }
        }
        if case .idle = briefingStatus, let cached = briefingCache[.today] {
            currentScope = .today
            briefingStatus = .complete(cached)
        }
    }

    private func loadCalendar() async {
        do {
            let cal = Calendar.current
            let start = cal.date(byAdding: .day, value: calendarDayOffset, to: cal.startOfDay(for: Date()))!
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            let allEvents = try await calendarService.fetchEvents(from: start, to: end)
            michaelEvents = allEvents.filter { $0.owner == .michael }
            familyEvents = allEvents.filter { $0.owner == .family }
            conflicts = await calendarService.detectConflicts(in: allEvents)
            freeWindows = await calendarService.findFreeWindows(
                in: allEvents,
                minimumMinutes: settings.minimumFreeWindowMinutes
            )
        } catch {
            taskActionError = error.localizedDescription
        }
    }

    private func loadTasks() async {
        // Live read only — a failed read empties the pane and surfaces the
        // error rather than showing a stale snapshot. Writes are enabled only
        // when the live read succeeded, since that proves Things is reachable.
        do {
            allTasks = try await thingsService.fetchAllTasks()
            writesEnabled = true
            tagNames = (try? await thingsService.fetchTagNames()) ?? tagNames
        } catch {
            allTasks = []
            writesEnabled = false
            taskActionError = error.localizedDescription
        }
    }

    // MARK: - Briefing Actions

    private func showOrGenerate(scope: BriefingScope) {
        currentScope = scope
        if let cached = briefingCache[scope] {
            briefingStatus = .complete(cached)
        } else {
            generateBriefing(scope: scope)
        }
    }

    private func generateBriefing(scope: BriefingScope) {
        let engine = briefingEngine
        Task {
            do {
                let result = try await engine.generateBriefing(scope: scope) { status in
                    Task { @MainActor in briefingStatus = status }
                }
                await MainActor.run {
                    briefingCache[scope] = result
                    BriefingCache.save(result, for: scope, directoryPath: settings.taskDirectoryPath)
                }
            } catch {
                await MainActor.run {
                    briefingStatus = .error(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Task Actions (same verified write channel as the popover)

    private func completeTask(_ task: BriefingTask) {
        guard writesEnabled, !tasksInFlight.contains(task.id) else { return }
        tasksInFlight.insert(task.id)
        taskActionError = nil
        let things = thingsService
        Task {
            do {
                try await things.completeTask(id: task.id)
                await MainActor.run {
                    tasksInFlight.remove(task.id)
                    withAnimation { allTasks.removeAll { $0.id == task.id } }
                }
            } catch {
                await MainActor.run {
                    tasksInFlight.remove(task.id)
                    taskActionError = error.localizedDescription
                }
            }
        }
    }

    private func performTaskAction(_ action: TaskRowAction, on task: BriefingTask) {
        guard writesEnabled, !tasksInFlight.contains(task.id) else { return }
        tasksInFlight.insert(task.id)
        taskActionError = nil
        let things = thingsService
        Task {
            do {
                switch action {
                case .rename(let newTitle):
                    try await things.updateTask(id: task.id, title: newTitle)
                case .reschedule(let when):
                    try await things.updateTask(id: task.id, when: when)
                case .setDeadline(let deadline):
                    try await things.updateTask(id: task.id, deadline: deadline)
                case .addTag(let tag):
                    try await things.updateTask(id: task.id, addTags: [tag])
                }
                await loadTasks()
                await MainActor.run { tasksInFlight.remove(task.id) }
            } catch {
                await MainActor.run {
                    tasksInFlight.remove(task.id)
                    taskActionError = error.localizedDescription
                }
            }
        }
    }

    private func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard writesEnabled, !title.isEmpty, !isAddingTask else { return }
        isAddingTask = true
        taskActionError = nil
        let things = thingsService
        let list = selectedList
        Task {
            do {
                try await things.createTask(title: title, list: list)
                try await Task.sleep(nanoseconds: 800_000_000)
                await loadTasks()
                await MainActor.run {
                    newTaskTitle = ""
                    isAddingTask = false
                }
            } catch {
                await MainActor.run {
                    isAddingTask = false
                    taskActionError = error.localizedDescription
                }
            }
        }
    }
}
