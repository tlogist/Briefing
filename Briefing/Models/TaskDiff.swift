import Foundation

// Represents a single difference found during Things 3 <-> todo.md sync.
// Each diff is a proposed change that the user can approve or reject.
enum DiffAction: String, Sendable {
    case addToFile      // Task exists in Things 3 but not todo.md → add to file
    case addToThings    // Task exists in todo.md but not Things 3 → add to Things
    case markCompleted  // Task completed in one system but open in the other
    case updateInfo     // Due date, notes, or project changed
    case flagStale      // Task is overdue or unchanged for a long time
}

struct TaskDiff: Identifiable, Sendable {
    let id = UUID()
    let action: DiffAction
    let taskName: String
    let detail: String           // Human-readable explanation of what changed
    let thingsTask: BriefingTask? // The Things 3 version (nil if file-only)
    let fileSectionType: SectionType? // Where this task lives in todo.md
    var isApproved: Bool = true  // Default to approved; user can toggle off
}

// Result of applying approved diffs — tells the caller what happened.
struct SyncResult: Sendable {
    let appliedCount: Int
    let skippedCount: Int
    let errors: [String]
    let summary: String          // For appending to todo-log.md
}
