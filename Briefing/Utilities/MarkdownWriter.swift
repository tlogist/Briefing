import Foundation

// Serializes a TodoDocument back to markdown string.
// Key principle: unmodified sections are written back using their rawLines
// for perfect round-trip fidelity. Only modified sections are reconstructed
// from their parsed data.
enum MarkdownWriter {

    /// Serialize a TodoDocument back to a markdown string.
    static func write(_ document: TodoDocument) -> String {
        var parts: [String] = []

        // Header (title, timestamps, first ---)
        parts.append(document.header)

        for section in document.sections {
            // Separator before each section
            parts.append("---")
            parts.append("")

            // Section heading
            parts.append(section.heading)

            if section.isModified {
                // Reconstruct from parsed data
                parts.append(contentsOf: writeModifiedSection(section))
            } else {
                // Preserve original lines verbatim
                parts.append(contentsOf: section.rawLines)
            }
        }

        // Final separator
        parts.append("---")
        parts.append("")

        return parts.joined(separator: "\n")
    }

    // MARK: - Modified Section Writing

    /// Reconstruct a section from its parsed tasks and projects.
    /// Used only when isModified is true.
    private static func writeModifiedSection(_ section: TodoSection) -> [String] {
        var lines: [String] = []

        // Flat tasks (not under a project)
        for task in section.tasks {
            lines.append(writeTaskLine(task))
        }

        // Projects with their tasks
        for project in section.projects {
            if !lines.isEmpty || !section.tasks.isEmpty {
                lines.append("")  // Blank line before project heading
            }
            lines.append("### \(project.name)")

            if project.tasks.isEmpty {
                // Preserve raw lines for project notes (non-task content like metadata)
                for rawLine in project.rawLines {
                    if MarkdownParser.parseTaskLine(rawLine) == nil {
                        lines.append(rawLine)
                    }
                }
            } else {
                for rawLine in project.rawLines {
                    lines.append(rawLine)
                }
            }
        }

        // Trailing blank line
        lines.append("")
        return lines
    }

    /// Format a single task as a checkbox line.
    static func writeTaskLine(_ task: TodoTask) -> String {
        let checkbox = task.isCompleted ? "- [x] " : "- [ ] "
        var line = checkbox + task.name

        if let meta = task.metadata {
            line += " *(\(meta))*"
        }

        return line
    }

    // MARK: - Targeted Updates

    /// Update the "Last synced" timestamp in the header.
    static func updateSyncTimestamp(in document: inout TodoDocument, date: Date = Date()) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd h:mm a zzz"
        let timestamp = formatter.string(from: date)

        let pattern = #"\*\*Last synced from Things 3:\*\* .+"#
        let replacement = "**Last synced from Things 3:** \(timestamp)"
        document = TodoDocument(
            header: document.header.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            ),
            sections: document.sections,
            trailingSeparators: document.trailingSeparators
        )
    }

    /// Update the "Last AI review" timestamp in the header.
    static func updateReviewTimestamp(in document: inout TodoDocument, date: Date = Date()) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd h:mm a zzz"
        let timestamp = formatter.string(from: date)

        let pattern = #"\*\*Last AI review:\*\* .+"#
        let replacement = "**Last AI review:** \(timestamp)"
        document = TodoDocument(
            header: document.header.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            ),
            sections: document.sections,
            trailingSeparators: document.trailingSeparators
        )
    }

    /// Move a task to the completed section with a completion date.
    static func completeTask(named taskName: String, in document: inout TodoDocument, project: String? = nil) {
        let completionDate = DateFormatting.dayCompact.string(from: Date())

        // Find and remove the task from its current section
        for i in document.sections.indices {
            // Check flat tasks
            if let taskIdx = document.sections[i].tasks.firstIndex(where: { $0.name == taskName && !$0.isCompleted }) {
                let task = document.sections[i].tasks[taskIdx]
                var mutableSection = document.sections[i]
                var tasks = mutableSection.tasks
                tasks.remove(at: taskIdx)
                document.sections[i] = TodoSection(
                    type: mutableSection.type,
                    heading: mutableSection.heading,
                    rawLines: mutableSection.rawLines,
                    tasks: tasks,
                    projects: mutableSection.projects,
                    isModified: true
                )
                addToCompleted(task: task, completionDate: completionDate, project: project, in: &document)
                return
            }

            // Check project tasks
            for j in document.sections[i].projects.indices {
                if let taskIdx = document.sections[i].projects[j].tasks.firstIndex(where: { $0.name == taskName && !$0.isCompleted }) {
                    let task = document.sections[i].projects[j].tasks[taskIdx]
                    let projName = document.sections[i].projects[j].name
                    var mutableSection = document.sections[i]
                    var projects = mutableSection.projects
                    var projTasks = projects[j].tasks
                    var projLines = projects[j].rawLines
                    projTasks.remove(at: taskIdx)
                    // Also remove from rawLines
                    if let rawIdx = projLines.firstIndex(where: { $0.contains(taskName) }) {
                        projLines.remove(at: rawIdx)
                    }
                    projects[j] = TodoProject(name: projects[j].name, rawLines: projLines, tasks: projTasks)
                    document.sections[i] = TodoSection(
                        type: mutableSection.type,
                        heading: mutableSection.heading,
                        rawLines: mutableSection.rawLines,
                        tasks: mutableSection.tasks,
                        projects: projects,
                        isModified: true
                    )
                    addToCompleted(task: task, completionDate: completionDate, project: projName, in: &document)
                    return
                }
            }
        }
    }

    /// Add a completed task entry to the Recently Completed section.
    private static func addToCompleted(task: TodoTask, completionDate: String, project: String?, in document: inout TodoDocument) {
        guard let completedIdx = document.sections.firstIndex(where: { $0.type == .completed }) else { return }

        var meta = completionDate
        if let proj = project ?? task.project {
            meta += ", proj: \(proj)"
        }

        let completedTask = TodoTask(
            rawLine: "- [x] \(task.name) *(\(meta))*",
            name: task.name,
            isCompleted: true,
            metadata: meta,
            project: nil
        )

        var section = document.sections[completedIdx]
        var tasks = section.tasks
        tasks.insert(completedTask, at: 0)  // Most recent first
        var rawLines = section.rawLines
        rawLines.insert(completedTask.rawLine, at: 0)
        document.sections[completedIdx] = TodoSection(
            type: .completed,
            heading: section.heading,
            rawLines: rawLines,
            tasks: tasks,
            projects: section.projects,
            isModified: true
        )
    }
}
