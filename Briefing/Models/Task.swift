import Foundation

// Which Things 3 list a task lives in. Maps directly to Things 3's
// built-in lists. The raw string values match what JXA returns.
enum TaskList: String, CaseIterable, Sendable {
    case inbox = "Inbox"
    case today = "Today"
    case upcoming = "Upcoming"
    case anytime = "Anytime"
    case someday = "Someday"

    // Things 3 URL scheme list parameter values
    var urlSchemeValue: String {
        switch self {
        case .inbox: return "inbox"
        case .today: return "today"
        case .upcoming: return "upcoming"
        case .anytime: return "anytime"
        case .someday: return "someday"
        }
    }
}

// Where a task originated — matters for sync diffing later
enum TaskSource: String, Sendable {
    case things3
    case todoFile
    case both  // exists in both, matched by name
}

// A task from Things 3, todo.md, or both. Used across the app for
// display, sync diffing, and briefing generation.
struct BriefingTask: Identifiable, Sendable {
    let id: String              // Things 3 ID or generated UUID for file-only tasks
    let name: String
    let project: String?        // Things 3 project name, or ### heading from todo.md
    let list: TaskList
    let dueDate: Date?
    let notes: String?
    let tags: [String]
    let isCompleted: Bool
    let completionDate: Date?
    let source: TaskSource

    // Whether this task is overdue based on its due date
    var isOverdue: Bool {
        guard let due = dueDate, !isCompleted else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }

    // Days overdue (0 if not overdue)
    var daysOverdue: Int {
        guard let due = dueDate, isOverdue else { return 0 }
        return Calendar.current.dateComponents([.day], from: due, to: Date()).day ?? 0
    }
}
