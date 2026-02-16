import Foundation

// Compares Things 3 tasks against todo.md and produces a list of diffs.
// Doesn't apply changes itself — the diffs are presented to the user for
// approval, then applied by the caller using MarkdownWriter and ThingsService.
actor TaskSyncService {
    private let thingsService: ThingsService
    private let taskFileService: TaskFileService

    init(thingsService: ThingsService, taskFileService: TaskFileService) {
        self.thingsService = thingsService
        self.taskFileService = taskFileService
    }

    // MARK: - Diff Generation

    /// Compare Things 3 tasks against todo.md and produce a list of diffs.
    func generateDiffs() async throws -> [TaskDiff] {
        // Fetch both sources in parallel
        async let thingsTasks = thingsService.fetchAllTasks()
        async let todoDocument = taskFileService.readTodoFile()

        let things = try await thingsTasks
        let doc = try await todoDocument
        let fileTasks = doc.allTasks

        var diffs: [TaskDiff] = []

        // 1. Things 3 tasks not in todo.md → suggest adding to file
        let fileTaskNames = Set(fileTasks.map { normalizeForComparison($0.name) })
        for task in things where !task.isCompleted {
            let normalized = normalizeForComparison(task.name)
            if !fileTaskNames.contains(normalized) {
                diffs.append(TaskDiff(
                    action: .addToFile,
                    taskName: task.name,
                    detail: "New in Things 3 (\(task.list.rawValue))" +
                        (task.project != nil ? " — project: \(task.project!)" : ""),
                    thingsTask: task,
                    fileSectionType: sectionType(for: task.list)
                ))
            }
        }

        // 2. todo.md tasks not in Things 3 → suggest adding to Things
        let thingsTaskNames = Set(things.map { normalizeForComparison($0.name) })
        for fileTask in fileTasks where !fileTask.isCompleted {
            let normalized = normalizeForComparison(fileTask.name)
            if !thingsTaskNames.contains(normalized) {
                // Only suggest adding if it's in an active section (not Completed)
                diffs.append(TaskDiff(
                    action: .addToThings,
                    taskName: fileTask.name,
                    detail: "In todo.md but missing from Things 3",
                    thingsTask: nil,
                    fileSectionType: nil
                ))
            }
        }

        // 3. Completion mismatches — completed in one but not the other
        for task in things where task.isCompleted {
            let normalized = normalizeForComparison(task.name)
            // Find matching file task that's still open
            if let fileTask = fileTasks.first(where: { normalizeForComparison($0.name) == normalized && !$0.isCompleted }) {
                diffs.append(TaskDiff(
                    action: .markCompleted,
                    taskName: task.name,
                    detail: "Completed in Things 3 but still open in todo.md",
                    thingsTask: task,
                    fileSectionType: nil
                ))
                _ = fileTask // silence unused warning
            }
        }
        for fileTask in fileTasks where fileTask.isCompleted {
            let normalized = normalizeForComparison(fileTask.name)
            // Find matching Things task that's still open
            if let task = things.first(where: { normalizeForComparison($0.name) == normalized && !$0.isCompleted }) {
                diffs.append(TaskDiff(
                    action: .markCompleted,
                    taskName: fileTask.name,
                    detail: "Completed in todo.md but still open in Things 3",
                    thingsTask: task,
                    fileSectionType: nil
                ))
            }
        }

        // 4. Stale tasks — overdue by more than 7 days
        for task in things where task.isOverdue && task.daysOverdue > 7 {
            diffs.append(TaskDiff(
                action: .flagStale,
                taskName: task.name,
                detail: "\(task.daysOverdue) days overdue",
                thingsTask: task,
                fileSectionType: nil
            ))
        }

        return diffs
    }

    // MARK: - Diff Application

    /// Apply approved diffs. Returns a summary of what was done.
    func applyDiffs(_ diffs: [TaskDiff], document: inout TodoDocument) async -> SyncResult {
        let approved = diffs.filter { $0.isApproved }
        let skipped = diffs.count - approved.count
        var errors: [String] = []
        var applied = 0
        var summaryLines: [String] = []

        for diff in approved {
            do {
                switch diff.action {
                case .addToFile:
                    // Add the task to the appropriate section in todo.md
                    if let sectionType = diff.fileSectionType,
                       let sectionIdx = document.sections.firstIndex(where: { $0.type == sectionType }) {
                        let newLine = "- [ ] \(diff.taskName)"
                        let newTask = TodoTask(
                            rawLine: newLine,
                            name: diff.taskName,
                            isCompleted: false,
                            metadata: nil,
                            project: diff.thingsTask?.project
                        )
                        var section = document.sections[sectionIdx]
                        var tasks = section.tasks
                        tasks.append(newTask)
                        var rawLines = section.rawLines
                        rawLines.append(newLine)
                        document.sections[sectionIdx] = TodoSection(
                            type: section.type,
                            heading: section.heading,
                            rawLines: rawLines,
                            tasks: tasks,
                            projects: section.projects,
                            isModified: true
                        )
                        applied += 1
                        summaryLines.append("- Added to todo.md: \(diff.taskName)")
                    }

                case .addToThings:
                    // Create the task in Things 3 via URL scheme
                    if let task = diff.thingsTask {
                        try await thingsService.createTask(
                            title: diff.taskName,
                            notes: task.notes,
                            list: task.list
                        )
                    } else {
                        try await thingsService.createTask(title: diff.taskName)
                    }
                    applied += 1
                    summaryLines.append("- Added to Things 3: \(diff.taskName)")

                case .markCompleted:
                    if diff.detail.contains("still open in todo.md") {
                        // Mark as completed in the file
                        MarkdownWriter.completeTask(named: diff.taskName, in: &document)
                        applied += 1
                        summaryLines.append("- Completed in todo.md: \(diff.taskName)")
                    } else if let task = diff.thingsTask {
                        // Mark as completed in Things 3
                        try await thingsService.completeTask(id: task.id)
                        applied += 1
                        summaryLines.append("- Completed in Things 3: \(diff.taskName)")
                    }

                case .updateInfo:
                    // Update info diffs are informational for now
                    summaryLines.append("- Info updated: \(diff.taskName) — \(diff.detail)")
                    applied += 1

                case .flagStale:
                    // Stale flags are informational — no automatic action
                    summaryLines.append("- Stale: \(diff.taskName) (\(diff.detail))")
                    applied += 1
                }
            } catch {
                errors.append("\(diff.taskName): \(error.localizedDescription)")
            }
        }

        let summary = summaryLines.isEmpty ? "No changes applied." : summaryLines.joined(separator: "\n")
        return SyncResult(appliedCount: applied, skippedCount: skipped, errors: errors, summary: summary)
    }

    // MARK: - Helpers

    /// Normalize task name for fuzzy matching. Strips markdown links, extra
    /// whitespace, and lowercases for case-insensitive comparison.
    private func normalizeForComparison(_ name: String) -> String {
        var result = name.lowercased()

        // Strip markdown link syntax: [text](url) → text
        let linkPattern = #"\[([^\]]+)\]\([^\)]+\)"#
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // Collapse whitespace
        result = result.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        return result
    }

    /// Map a Things 3 list to the corresponding todo.md section.
    private func sectionType(for list: TaskList) -> SectionType {
        switch list {
        case .inbox, .today: return .today
        case .upcoming, .anytime: return .anytime
        case .someday: return .someday
        }
    }
}
