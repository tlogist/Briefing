import Foundation

// The result of a full briefing generation — contains both the
// Claude-generated analysis and the raw data that fed into it.
struct BriefingResult: Identifiable {
    let id = UUID()
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
