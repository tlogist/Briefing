import Foundation

// Which section of todo.md we're in, identified by the emoji prefix.
enum SectionType: String, CaseIterable {
    case today      = "🔴"
    case projects   = "📋"
    case personal   = "🟠"
    case anytime    = "🟡"
    case someday    = "🔵"
    case completed  = "✅"

    /// Match a heading line like "## 🔴 Today" to a section type.
    static func from(heading: String) -> SectionType? {
        for type in allCases {
            if heading.contains(type.rawValue) { return type }
        }
        return nil
    }
}

// A single task line parsed from todo.md.
struct TodoTask {
    let rawLine: String          // Original line for round-trip fidelity
    let name: String             // Task text without checkbox/metadata
    let isCompleted: Bool        // [x] vs [ ]
    let metadata: String?        // Italic text in *(...)*  at end
    var project: String?         // Set when task is under a ### heading
}

// A project sub-heading (### level) with its tasks and any non-task content.
struct TodoProject {
    let name: String             // The ### heading text
    let rawLines: [String]       // All lines under this heading (for round-trip)
    let tasks: [TodoTask]        // Parsed tasks from those lines
}

// A ## section of the document.
struct TodoSection {
    let type: SectionType
    let heading: String          // The full "## 🔴 Today" line
    let rawLines: [String]       // All lines in this section (after heading, before next section/---)
    let tasks: [TodoTask]        // Flat tasks (not under a project sub-heading)
    let projects: [TodoProject]  // Project sub-headings (only in Projects/Someday)
    var isModified: Bool = false // Track if we've changed this section
}

// The complete parsed todo.md document.
struct TodoDocument {
    let header: String           // Everything before the first ## section (title, timestamps, ---)
    var sections: [TodoSection]
    let trailingSeparators: [String] // --- lines between/after sections, keyed by position

    /// Extract the "Last synced" timestamp from the header.
    var lastSyncedTimestamp: String? {
        let pattern = #"\*\*Last synced from Things 3:\*\* (.+)"#
        guard let match = header.range(of: pattern, options: .regularExpression) else { return nil }
        let line = String(header[match])
        return line.replacingOccurrences(of: "**Last synced from Things 3:** ", with: "")
    }

    /// Get all tasks across all sections (flat list).
    var allTasks: [TodoTask] {
        sections.flatMap { section in
            var tasks = section.tasks
            for project in section.projects {
                tasks.append(contentsOf: project.tasks)
            }
            return tasks
        }
    }

    /// Get tasks for a specific section type.
    func tasks(in sectionType: SectionType) -> [TodoTask] {
        guard let section = sections.first(where: { $0.type == sectionType }) else { return [] }
        var tasks = section.tasks
        for project in section.projects {
            tasks.append(contentsOf: project.tasks)
        }
        return tasks
    }
}

// MARK: - Parser

enum MarkdownParser {

    /// Parse a todo.md string into a structured TodoDocument.
    static func parse(_ content: String) -> TodoDocument {
        let lines = content.components(separatedBy: "\n")

        var headerLines: [String] = []
        var sectionChunks: [(heading: String, lines: [String])] = []
        var currentHeading: String?
        var currentLines: [String] = []
        var foundFirstSection = false

        for line in lines {
            if line.hasPrefix("## ") {
                // Start of a new section
                if let heading = currentHeading {
                    sectionChunks.append((heading: heading, lines: currentLines))
                }
                currentHeading = line
                currentLines = []
                foundFirstSection = true
            } else if !foundFirstSection {
                headerLines.append(line)
            } else {
                currentLines.append(line)
            }
        }

        // Don't forget the last section
        if let heading = currentHeading {
            sectionChunks.append((heading: heading, lines: currentLines))
        }

        // Parse each section chunk
        var sections: [TodoSection] = []
        for chunk in sectionChunks {
            guard let type = SectionType.from(heading: chunk.heading) else { continue }
            let section = parseSection(type: type, heading: chunk.heading, lines: chunk.lines)
            sections.append(section)
        }

        let header = headerLines.joined(separator: "\n")
        return TodoDocument(header: header, sections: sections, trailingSeparators: [])
    }

    // MARK: - Section Parsing

    private static func parseSection(type: SectionType, heading: String, lines: [String]) -> TodoSection {
        // Sections with project sub-headings: Projects and Someday
        let hasProjects = (type == .projects || type == .someday)

        if hasProjects {
            return parseSectionWithProjects(type: type, heading: heading, lines: lines)
        } else {
            let tasks = lines.compactMap { parseTaskLine($0) }
            return TodoSection(
                type: type,
                heading: heading,
                rawLines: lines,
                tasks: tasks,
                projects: []
            )
        }
    }

    private static func parseSectionWithProjects(type: SectionType, heading: String, lines: [String]) -> TodoSection {
        var projects: [TodoProject] = []
        var looseTasks: [TodoTask] = []    // Tasks not under any ### heading
        var currentProjectName: String?
        var currentProjectLines: [String] = []

        for line in lines {
            if line.hasPrefix("### ") {
                // Flush previous project
                if let projName = currentProjectName {
                    let tasks = currentProjectLines.compactMap { parseTaskLine($0, project: projName) }
                    projects.append(TodoProject(name: projName, rawLines: currentProjectLines, tasks: tasks))
                }
                currentProjectName = String(line.dropFirst(4))
                currentProjectLines = []
            } else if currentProjectName != nil {
                currentProjectLines.append(line)
            } else {
                // Lines before any ### heading — could be loose tasks or separators
                if let task = parseTaskLine(line) {
                    looseTasks.append(task)
                }
            }
        }

        // Flush final project
        if let projName = currentProjectName {
            let tasks = currentProjectLines.compactMap { parseTaskLine($0, project: projName) }
            projects.append(TodoProject(name: projName, rawLines: currentProjectLines, tasks: tasks))
        }

        return TodoSection(
            type: type,
            heading: heading,
            rawLines: lines,
            tasks: looseTasks,
            projects: projects
        )
    }

    // MARK: - Task Line Parsing

    /// Parse a single line into a TodoTask if it matches checkbox syntax.
    /// Returns nil for blank lines, separators, non-task content.
    static func parseTaskLine(_ line: String, project: String? = nil) -> TodoTask? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Must start with "- [ ]" or "- [x]" (case insensitive x)
        guard trimmed.hasPrefix("- [") else { return nil }

        let isCompleted: Bool
        let afterCheckbox: String

        if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
            isCompleted = true
            afterCheckbox = String(trimmed.dropFirst(6))
        } else if trimmed.hasPrefix("- [ ] ") {
            isCompleted = false
            afterCheckbox = String(trimmed.dropFirst(6))
        } else {
            return nil
        }

        // Extract trailing metadata in italics: *(...)*
        let (name, metadata) = extractMetadata(from: afterCheckbox)

        return TodoTask(
            rawLine: line,
            name: name.trimmingCharacters(in: .whitespaces),
            isCompleted: isCompleted,
            metadata: metadata,
            project: project
        )
    }

    /// Split "Task name *(some metadata)*" into ("Task name", "some metadata").
    /// Handles nested markdown links inside metadata.
    private static func extractMetadata(from text: String) -> (name: String, metadata: String?) {
        // Look for trailing *(...)*  — the metadata is typically at the end
        // Pattern: text followed by space then *(...)*
        // Need to handle nested parens and markdown links inside
        guard let lastStar = text.lastIndex(of: "*") else {
            return (text, nil)
        }

        // Walk backward to find the opening *( pattern
        let beforeLastStar = text[text.startIndex..<lastStar]
        guard let openingStar = beforeLastStar.lastIndex(of: "*") else {
            return (text, nil)
        }

        // Check that the opening * is followed by (
        let afterOpening = text.index(after: openingStar)
        guard afterOpening < lastStar,
              text[afterOpening] == "(" else {
            return (text, nil)
        }

        // Check that the closing * is preceded by )
        let beforeClosing = text.index(before: lastStar)
        guard beforeClosing > openingStar,
              text[beforeClosing] == ")" else {
            return (text, nil)
        }

        let nameEnd = openingStar
        let name = String(text[text.startIndex..<nameEnd]).trimmingCharacters(in: .whitespaces)
        // Extract content between *( and )*
        let metaStart = text.index(afterOpening, offsetBy: 1) // skip the (
        let metaEnd = beforeClosing // before the )
        let metadata = metaStart < metaEnd ? String(text[metaStart..<metaEnd]) : nil

        return (name, metadata)
    }
}
