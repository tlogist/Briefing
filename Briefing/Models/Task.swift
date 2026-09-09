import Foundation

// Which Things 3 list a task lives in. Maps directly to Things 3's
// built-in lists. The raw string values match what JXA returns.
enum TaskList: String, CaseIterable, Sendable, Codable {
    case inbox = "Inbox"
    case today = "Today"
    case upcoming = "Upcoming"
    case anytime = "Anytime"
    case someday = "Someday"

    // Value for the URL scheme's `when` parameter. The `list` parameter is NOT
    // for built-in lists — it expects a project/area title, so `list=today`
    // matches nothing and the task silently lands in Inbox. Scheduling into a
    // built-in list is done via `when` instead.
    var whenParameterValue: String? {
        switch self {
        case .inbox: return nil          // no `when` → defaults to Inbox
        case .today: return "today"
        case .upcoming: return "tomorrow" // `when` has no "upcoming"; tomorrow lands there
        case .anytime: return "anytime"
        case .someday: return "someday"
        }
    }
}

// Where a task originated — matters for sync diffing later
enum TaskSource: String, Sendable, Codable {
    case things3
    case todoFile
    case both  // exists in both, matched by name
}

// A task from Things 3, todo.md, or both. Used across the app for
// display, sync diffing, and briefing generation.
struct BriefingTask: Identifiable, Sendable, Codable {
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
    // Staleness signals for AI maintenance triage. Optional vars with nil
    // defaults so file-parsed tasks and pre-existing cache JSON (which lack
    // these keys) keep constructing/decoding unchanged.
    var creationDate: Date? = nil
    var modificationDate: Date? = nil
    // Things "when" date (JXA activationDate) — the date the task is scheduled
    // to start, distinct from dueDate (the deadline). Same optional-with-nil
    // pattern as above so older cache JSON keeps decoding.
    var scheduledDate: Date? = nil

    // Days since the task was last touched (nil when Things didn't report it)
    var idleDays: Int? {
        guard let modified = modificationDate else { return nil }
        return Calendar.current.dateComponents([.day], from: modified, to: Date()).day
    }

    // The scheduled date worth showing in a row: only future dates carry
    // information — a task activating today or earlier already sits in Today,
    // so echoing the date would be noise. Likewise suppressed when it matches
    // the deadline day: the row's "due …" label already shows that date.
    var upcomingScheduledDate: Date? {
        guard let scheduled = scheduledDate, !isCompleted else { return nil }
        let calendar = Calendar.current
        if let due = dueDate, calendar.isDate(due, inSameDayAs: scheduled) { return nil }
        guard let startOfTomorrow = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())
        ) else { return nil }
        return scheduled >= startOfTomorrow ? scheduled : nil
    }

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
