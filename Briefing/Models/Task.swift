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

    // Days since the task was last touched (nil when Things didn't report it)
    var idleDays: Int? {
        guard let modified = modificationDate else { return nil }
        return Calendar.current.dateComponents([.day], from: modified, to: Date()).day
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

// MARK: - Things 3 Task Cache (iCloud Drive)

/// Wraps cached Things 3 tasks with a timestamp for freshness display.
struct CachedThingsData: Codable {
    let tasks: [BriefingTask]
    let cachedAt: Date
}

/// Reads/writes Things 3 tasks to a JSON file in the shared iCloud Drive folder.
/// Personal Mac writes (where Things works); work Mac reads as fallback.
///
/// Same pattern as CalendarCache — see CalendarEvent.swift.
enum ThingsCache {
    private static let filename = "things-task-cache.json"

    /// Write all Things 3 tasks to the shared cache file.
    static func save(tasks: [BriefingTask], to directoryPath: String) {
        let data = CachedThingsData(tasks: tasks, cachedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let jsonData = try? encoder.encode(data) else { return }

        let fileURL = URL(fileURLWithPath: directoryPath)
            .appendingPathComponent(filename)
        try? jsonData.write(to: fileURL, options: .atomic)
    }

    /// Load cached Things 3 tasks from the shared cache file.
    /// Returns nil if the file doesn't exist or can't be decoded.
    static func load(from directoryPath: String) -> CachedThingsData? {
        let fileURL = URL(fileURLWithPath: directoryPath)
            .appendingPathComponent(filename)

        guard let jsonData = try? Data(contentsOf: fileURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedThingsData.self, from: jsonData)
    }
}
