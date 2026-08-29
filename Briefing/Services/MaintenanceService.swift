import Foundation

// Phase 3 of the ThingsEngage integration: the read → reason → write loop
// with the human in the approval seat. Claude reads the full task state and
// proposes maintenance actions (complete stale items, reschedule, set
// deadlines, tag); the user approves or skips each one in the popover; only
// approved actions are written — through ThingsService's verified URL-scheme
// channel, never directly.

// MARK: - Proposed Action

/// One maintenance action Claude proposed. `approved` is the user's decision
/// state in the review UI (defaults to true — the user unchecks to skip).
struct ProposedAction: Identifiable {
    enum Kind {
        case complete
        case reschedule(when: String)     // "today", "tomorrow", "someday", "YYYY-MM-DD"
        case setDeadline(String)          // "YYYY-MM-DD"
        case addTag(String)               // must be an existing Things tag

        /// Short label for the review row, e.g. "Complete", "→ Someday"
        var label: String {
            switch self {
            case .complete: return "Complete"
            case .reschedule(let when): return "→ \(when.capitalized)"
            case .setDeadline(let date): return "Deadline \(date)"
            case .addTag(let tag): return "#\(tag)"
            }
        }

        var systemImage: String {
            switch self {
            case .complete: return "checkmark.circle"
            case .reschedule: return "calendar.badge.clock"
            case .setDeadline: return "flag"
            case .addTag: return "tag"
            }
        }
    }

    let id = UUID()
    let taskID: String        // Things UUID — the read→write bridge
    let taskName: String
    let kind: Kind
    let reason: String
    var approved: Bool = true
}

// MARK: - Service

actor MaintenanceService {
    private let claude: ClaudeAPIService
    private let thingsService: ThingsService

    init(claude: ClaudeAPIService = ClaudeAPIService(), thingsService: ThingsService) {
        self.claude = claude
        self.thingsService = thingsService
    }

    // MARK: Propose

    /// Ask Claude for maintenance proposals over the full task state.
    /// Returns validated actions only: task ids must exist in the provided
    /// set, and tags must be in the existing vocabulary (the URL scheme
    /// silently drops unknown tags, so an invalid proposal would fake-succeed).
    func proposeActions(
        tasks: [BriefingTask],
        tagNames: [String],
        model: String
    ) async throws -> [ProposedAction] {
        let openTasks = tasks.filter { !$0.isCompleted }
        guard !openTasks.isEmpty else { return [] }

        let response = try await claude.sendChat(
            messages: [["role": "user", "content": buildPrompt(tasks: openTasks, tagNames: tagNames)]],
            system: Self.systemPrompt,
            model: model,
            maxTokens: 2048,
            tools: [Self.proposeTool(tagNames: tagNames)],
            toolChoice: ["type": "tool", "name": "propose_actions"]
        )

        guard let toolUse = response.toolUses.first(where: { $0.name == "propose_actions" }),
              let rawActions = toolUse.input["actions"] as? [[String: Any]] else {
            throw MaintenanceError.noProposals
        }

        let knownIDs = Set(openTasks.map { $0.id })
        let knownTags = Set(tagNames)

        return rawActions.compactMap { raw -> ProposedAction? in
            guard let action = raw["action"] as? String,
                  let taskID = raw["task_id"] as? String,
                  let taskName = raw["task_name"] as? String,
                  let reason = raw["reason"] as? String,
                  knownIDs.contains(taskID) else { return nil }
            let value = (raw["value"] as? String)?.trimmingCharacters(in: .whitespaces)

            let kind: ProposedAction.Kind
            switch action {
            case "complete":
                kind = .complete
            case "reschedule":
                guard let value, !value.isEmpty else { return nil }
                kind = .reschedule(when: value)
            case "set_deadline":
                guard let value, !value.isEmpty else { return nil }
                kind = .setDeadline(value)
            case "add_tag":
                // Hard gate: only tags that already exist in Things
                guard let value, knownTags.contains(value) else { return nil }
                kind = .addTag(value)
            default:
                return nil
            }
            return ProposedAction(taskID: taskID, taskName: taskName, kind: kind, reason: reason)
        }
    }

    // MARK: Apply

    /// Execute one approved action through the sanctioned write channel.
    /// ThingsService verifies each write by reading the task back, so a
    /// return without throwing means Things confirmed the change.
    func apply(_ action: ProposedAction) async throws {
        switch action.kind {
        case .complete:
            try await thingsService.completeTask(id: action.taskID)
        case .reschedule(let when):
            try await thingsService.updateTask(id: action.taskID, when: when)
        case .setDeadline(let deadline):
            try await thingsService.updateTask(id: action.taskID, deadline: deadline)
        case .addTag(let tag):
            try await thingsService.updateTask(id: action.taskID, addTags: [tag])
        }
    }

    // MARK: Prompt Construction

    private static let systemPrompt = """
        You are a task-maintenance assistant for Michael's Things 3 system. \
        The core problem you solve: capture works, but completion and upkeep don't — \
        tasks sit on the Today list for months, deadlines and tags go unset, and the \
        system rots. You propose small, concrete maintenance actions; a human approves \
        each one before anything is written.

        Rules:
        - Propose at most 8 actions, highest-impact first. Fewer is fine; an empty \
        list is the right answer for a healthy system.
        - Look for: overdue deadlines (reschedule or nudge to complete), Today items \
        idle for weeks (they are aspirations, not today-tasks — move to someday or \
        a concrete future date), time-sensitive items missing a deadline, untagged \
        actionable items (tag from the existing vocabulary only), and Anytime items \
        that clearly belong in Someday.
        - Never propose completing a task unless the data strongly suggests it is \
        done or obsolete — prefer reschedule/someday for doubtful cases.
        - Every reason must cite the data (idle days, overdue days, list) in one \
        short sentence.
        """

    private func buildPrompt(tasks: [BriefingTask], tagNames: [String]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        let lines = tasks.map { task -> String in
            var parts = ["[\(task.list.rawValue)] \(task.name)"]
            if let project = task.project { parts.append("project=\(project)") }
            if let due = task.dueDate {
                let days = Calendar.current.dateComponents([.day], from: Date(), to: due).day ?? 0
                parts.append("deadline=\(dateFormatter.string(from: due)) (\(days >= 0 ? "in \(days)d" : "\(-days)d overdue"))")
            } else {
                parts.append("deadline=none")
            }
            parts.append(task.tags.isEmpty ? "tags=none" : "tags=\(task.tags.joined(separator: ","))")
            if let idle = task.idleDays { parts.append("idle=\(idle)d") }
            parts.append("id=\(task.id)")
            return parts.joined(separator: " | ")
        }

        return """
            Today is \(today).
            Existing tags (the only tags you may apply): \(tagNames.joined(separator: ", "))

            Open tasks:
            \(lines.joined(separator: "\n"))
            """
    }

    private static func proposeTool(tagNames: [String]) -> [String: Any] {
        [
            "name": "propose_actions",
            "description": "Propose maintenance actions for the user's task system. Call exactly once with the full list (empty if nothing needs attention).",
            "input_schema": [
                "type": "object",
                "properties": [
                    "actions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "action": [
                                    "type": "string",
                                    "enum": ["complete", "reschedule", "set_deadline", "add_tag"]
                                ] as [String: Any],
                                "task_id": ["type": "string", "description": "The task's id exactly as given"] as [String: Any],
                                "task_name": ["type": "string"] as [String: Any],
                                "value": [
                                    "type": "string",
                                    "description": "reschedule: today|tomorrow|anytime|someday|YYYY-MM-DD. set_deadline: YYYY-MM-DD. add_tag: one existing tag name (\(tagNames.joined(separator: ", "))). Omit for complete."
                                ] as [String: Any],
                                "reason": ["type": "string", "description": "One short sentence citing the data"] as [String: Any]
                            ] as [String: Any],
                            "required": ["action", "task_id", "task_name", "reason"]
                        ] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["actions"]
            ] as [String: Any]
        ]
    }
}

// MARK: - Errors

enum MaintenanceError: LocalizedError {
    case noProposals

    var errorDescription: String? {
        switch self {
        case .noProposals:
            return "Claude did not return any structured proposals. Try again."
        }
    }
}
