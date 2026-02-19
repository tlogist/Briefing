import Foundation

// The result of a full briefing generation — contains both the
// Claude-generated analysis and the raw data that fed into it.
struct BriefingResult: Identifiable, Codable {
    let id: UUID
    let generatedAt: Date
    let markdownContent: String      // The full briefing text from Claude
    let model: String                // Which Claude model was used
    let promptTokens: Int?           // Usage tracking (nil if not available)
    let responseTokens: Int?

    // Source data used to generate this briefing (for display/debugging)
    let michaelEventCount: Int
    let nooshEventCount: Int
    let conflictCount: Int
    let freeWindowCount: Int
    let taskCount: Int
    let syncDiffCount: Int

    // Fingerprint of the task data used to generate this briefing.
    // Sorted task names joined — lets us detect when tasks change
    // (completed, added, renamed) and the cached briefing is stale.
    let taskFingerprint: String

    init(
        generatedAt: Date,
        markdownContent: String,
        model: String,
        promptTokens: Int?,
        responseTokens: Int?,
        michaelEventCount: Int,
        nooshEventCount: Int,
        conflictCount: Int,
        freeWindowCount: Int,
        taskCount: Int,
        syncDiffCount: Int,
        taskFingerprint: String = ""
    ) {
        self.id = UUID()
        self.generatedAt = generatedAt
        self.markdownContent = markdownContent
        self.model = model
        self.promptTokens = promptTokens
        self.responseTokens = responseTokens
        self.michaelEventCount = michaelEventCount
        self.nooshEventCount = nooshEventCount
        self.conflictCount = conflictCount
        self.freeWindowCount = freeWindowCount
        self.taskCount = taskCount
        self.syncDiffCount = syncDiffCount
        self.taskFingerprint = taskFingerprint
    }

    /// Build a fingerprint from a list of tasks — sorted names joined.
    /// Two fingerprints match only if the exact same set of tasks (by name) was used.
    static func fingerprint(from tasks: [BriefingTask]) -> String {
        tasks.filter { !$0.isCompleted }
            .map { $0.name }
            .sorted()
            .joined(separator: "|")
    }
}

// Whether to generate a today-only or week-ahead briefing
enum BriefingScope: String, Hashable, Codable {
    case today
    case tomorrow
    case week

    var label: String {
        switch self {
        case .today: return "Today's Briefing"
        case .tomorrow: return "Tomorrow's Briefing"
        case .week: return "Week's Briefing"
        }
    }

    var calendarHeading: String {
        switch self {
        case .today: return "Calendar Events (Today)"
        case .tomorrow: return "Calendar Events (Tomorrow)"
        case .week: return "Calendar Events (Next 7 Days)"
        }
    }
}

// Status of a briefing generation in progress
enum BriefingStatus: Equatable {
    case idle
    case gatheringData
    case callingClaude
    case complete(BriefingResult)
    case error(String)

    // Equatable conformance for the associated-value cases
    static func == (lhs: BriefingStatus, rhs: BriefingStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.gatheringData, .gatheringData): return true
        case (.callingClaude, .callingClaude): return true
        case (.complete(let a), .complete(let b)): return a.id == b.id
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Persistent Cache

/// Persists the most recent briefing result per scope to UserDefaults
/// so cached briefings survive app restarts.
enum BriefingCache {
    private static let prefix = "com.ammaturo.Briefing.cache."

    static func save(_ result: BriefingResult, for scope: BriefingScope) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        UserDefaults.standard.set(data, forKey: prefix + scope.rawValue)
    }

    static func load(for scope: BriefingScope) -> BriefingResult? {
        guard let data = UserDefaults.standard.data(forKey: prefix + scope.rawValue) else {
            return nil
        }
        return try? JSONDecoder().decode(BriefingResult.self, from: data)
    }

    static func remove(for scope: BriefingScope) {
        UserDefaults.standard.removeObject(forKey: prefix + scope.rawValue)
    }
}
