import AppKit
import Foundation

// Communicates with Things 3 via JavaScript for Automation (JXA) run through
// `osascript -l JavaScript`. This is the same approach the briefing slash command
// uses, but wrapped in a proper service with timeout handling.
//
// Key quirks documented in ENGINEERING_INVARIANTS.md:
// - App name is "Things 3" (with space)
// - Ghost tasks with empty names exist and must be filtered
// - JXA make/push doesn't work for creating tasks — use URL scheme
// - Things 3 can hang on launch, so we enforce a 5-second timeout
actor ThingsService {
    private let timeoutSeconds: Double = 5.0

    /// Non-nil when the last fetch used cached tasks (i.e., Things 3 wasn't
    /// accessible on this Mac). The UI reads this to show freshness.
    private(set) var lastThingsCacheDate: Date?

    /// JXA snippet that resolves the Things app regardless of whether it's
    /// registered as "Things 3" (older versions) or "Things3" (newer versions).
    /// Injected at the top of every JXA script so the rest can just use `app`.
    private let resolveApp = """
        const app = (() => {
            try { return Application("Things 3"); } catch(e) {}
            try { return Application("Things3"); } catch(e) {}
            throw new Error("Things not found");
        })();
        """

    // MARK: - Read Tasks

    /// Fetch all open tasks from Things 3, grouped by list.
    /// Returns empty array (not an error) if Things 3 isn't running.
    func fetchAllTasks() async throws -> [BriefingTask] {
        // Single JXA call that pulls everything — more efficient than
        // separate calls per list since each osascript invocation has overhead.
        let script = """
        (() => {
            \(resolveApp)
            const results = [];

            // Enumerate lists in priority order: a task scheduled for Today also
            // appears in Anytime (its project's default list). By processing Today
            // first and tracking seen IDs, we keep the most specific list assignment.
            const seen = {};
            const lists = ["Inbox", "Today", "Upcoming", "Anytime", "Someday"];
            for (const listName of lists) {
                let toDos;
                try {
                    toDos = app.lists.byName(listName).toDos();
                } catch(e) {
                    continue;
                }
                for (const t of toDos) {
                    const name = t.name();
                    // Filter ghost tasks — Things 3 sometimes has empty-name entries
                    if (!name || name.length === 0) continue;

                    const tid = t.id();
                    // Skip if already seen from a higher-priority list
                    if (seen[tid]) continue;
                    seen[tid] = true;

                    const proj = t.project();
                    results.push({
                        id: tid,
                        name: name,
                        project: proj ? proj.name() : null,
                        list: listName,
                        dueDate: t.dueDate() ? t.dueDate().toISOString() : null,
                        notes: t.notes() || null,
                        tags: t.tagNames() || "",
                        status: t.status()
                    });
                }
            }

            // Also pull tasks from projects directly (catches tasks that might
            // not appear in the flat list views)
            const projects = app.projects();
            for (const proj of projects) {
                const projName = proj.name();
                const toDos = proj.toDos();
                for (const t of toDos) {
                    const name = t.name();
                    if (!name || name.length === 0) continue;
                    const tid = t.id();
                    // Skip if we already have this task from list enumeration
                    if (seen[tid]) continue;
                    seen[tid] = true;

                    results.push({
                        id: tid,
                        name: name,
                        project: projName,
                        list: "Anytime",
                        dueDate: t.dueDate() ? t.dueDate().toISOString() : null,
                        notes: t.notes() || null,
                        tags: t.tagNames() || "",
                        status: t.status()
                    });
                }
            }

            return JSON.stringify(results);
        })()
        """

        let output = try await runJXA(script)

        guard let data = output.data(using: .utf8) else {
            throw ThingsError.parseError("Could not convert JXA output to data")
        }

        let decoded = try JSONDecoder().decode([ThingsRawTask].self, from: data)
        return decoded.compactMap { raw in
            // Parse the ISO date string from JXA
            var dueDate: Date?
            if let dueDateStr = raw.dueDate {
                dueDate = ISO8601DateFormatter().date(from: dueDateStr)
            }

            // Map Things 3 list name to our enum
            let list = TaskList(rawValue: raw.list) ?? .anytime

            return BriefingTask(
                id: raw.id,
                name: raw.name,
                project: raw.project,
                list: list,
                dueDate: dueDate,
                notes: raw.notes,
                tags: raw.tags.isEmpty ? [] : raw.tags.components(separatedBy: ", "),
                isCompleted: raw.status == "completed",
                completionDate: nil,
                source: .things3
            )
        }
    }

    /// Fetch only Today tasks (convenience for the popover).
    func fetchTodayTasks() async throws -> [BriefingTask] {
        let all = try await fetchAllTasks()
        return all.filter { $0.list == .today && !$0.isCompleted }
    }

    // MARK: - Things 3 Task Cache

    /// Fetch all tasks with iCloud Drive cache fallback.
    ///
    /// If Things 3 is accessible: fetches live, writes cache, returns tasks.
    /// If Things 3 fails (not running, timeout, permissions): falls back to
    /// cached tasks from iCloud Drive (written by the personal Mac).
    func fetchAllTasksWithCache(
        cacheDirectoryPath: String
    ) async -> [BriefingTask] {
        do {
            let tasks = try await fetchAllTasks()
            // Success — write cache for the other Mac and clear cache indicator
            ThingsCache.save(tasks: tasks, to: cacheDirectoryPath)
            lastThingsCacheDate = nil
            return tasks
        } catch {
            // Things 3 not accessible — fall back to cached tasks
            if let cached = ThingsCache.load(from: cacheDirectoryPath) {
                lastThingsCacheDate = cached.cachedAt
                return cached.tasks
            }
            lastThingsCacheDate = nil
            return []
        }
    }

    /// Fetch today's tasks with iCloud Drive cache fallback.
    func fetchTodayTasksWithCache(
        cacheDirectoryPath: String
    ) async -> (tasks: [BriefingTask], status: ThingsFetchStatus) {
        do {
            // Fetch all tasks once — filter for today, cache everything
            let allTasks = try await fetchAllTasks()
            let todayTasks = allTasks.filter { $0.list == .today && !$0.isCompleted }
            ThingsCache.save(tasks: allTasks, to: cacheDirectoryPath)
            lastThingsCacheDate = nil
            return (todayTasks, .live)
        } catch {
            // Fall back to cached tasks, filtered to today
            if let cached = ThingsCache.load(from: cacheDirectoryPath) {
                lastThingsCacheDate = cached.cachedAt
                let todayTasks = cached.tasks.filter {
                    $0.list == .today && !$0.isCompleted
                }
                return (todayTasks, .cached(cached.cachedAt))
            }
            lastThingsCacheDate = nil

            // Preserve the original error type for UI messaging
            if let thingsError = error as? ThingsError,
               case .notRunning = thingsError {
                return ([], .notRunning)
            }
            return ([], .error(error.localizedDescription))
        }
    }

    // MARK: - Complete a Task

    /// Mark a task as completed in Things 3.
    func completeTask(id: String) async throws {
        let script = """
        (() => {
            \(resolveApp)
            const todo = app.toDos.byId("\(id)");
            todo.status = "completed";
            return "OK";
        })()
        """
        _ = try await runJXA(script)
    }

    // MARK: - Create a Task

    /// Create a new task in Things 3 via URL scheme.
    /// JXA's make/push doesn't work reliably for task creation,
    /// so we use the `things:///add` URL scheme instead.
    /// Note: tasks created this way land in Inbox regardless of list parameter.
    func createTask(title: String, notes: String? = nil, list: TaskList = .today) async throws {
        var components = URLComponents(string: "things:///add")!
        var queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "list", value: list.urlSchemeValue),
            URLQueryItem(name: "show-quick-entry", value: "false")
        ]
        if let notes = notes, !notes.isEmpty {
            queryItems.append(URLQueryItem(name: "notes", value: notes))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ThingsError.invalidURL
        }

        // NSWorkspace.open runs on the main thread
        let opened = await MainActor.run {
            NSWorkspace.shared.open(url)
        }

        guard opened else {
            throw ThingsError.notRunning
        }
    }

    // MARK: - Check if Things 3 is Running

    func isThingsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.culturedcode.ThingsMac"
        }
    }

    // MARK: - JXA Execution

    /// Run a JXA script via `osascript -l JavaScript` with a timeout.
    /// Throws ThingsError.notRunning if Things 3 isn't available,
    /// ThingsError.timeout if the script takes too long.
    private func runJXA(_ script: String) async throws -> String {
        // Check if Things 3 is running first to give a better error message
        guard isThingsRunning() else {
            throw ThingsError.notRunning
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            // Set up a timeout that terminates the process if Things 3 hangs
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
            }
            timer.resume()

            process.terminationHandler = { proc in
                timer.cancel()

                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus != 0 {
                    if errorOutput.contains("is not running") || errorOutput.contains("Connection is invalid") {
                        continuation.resume(throwing: ThingsError.notRunning)
                    } else if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: ThingsError.timeout)
                    } else {
                        continuation.resume(throwing: ThingsError.scriptError(errorOutput))
                    }
                } else {
                    continuation.resume(returning: output)
                }
            }

            do {
                try process.run()
            } catch {
                timer.cancel()
                continuation.resume(throwing: ThingsError.scriptError(error.localizedDescription))
            }
        }
    }
}

// MARK: - Raw JSON shape from JXA

/// Mirrors the JSON structure returned by our JXA script.
/// Private — only used for decoding, then mapped to BriefingTask.
private struct ThingsRawTask: Decodable {
    let id: String
    let name: String
    let project: String?
    let list: String
    let dueDate: String?
    let notes: String?
    let tags: String
    let status: String
}

// MARK: - Fetch Status

/// Result status from cache-aware Things fetch — lets the UI show
/// the right message (live, cached with timestamp, not running, error).
enum ThingsFetchStatus {
    case live
    case cached(Date)
    case notRunning
    case error(String)
}

// MARK: - Errors

enum ThingsError: LocalizedError {
    case notRunning
    case timeout
    case scriptError(String)
    case parseError(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Things 3 is not running. Launch it to enable task sync."
        case .timeout:
            return "Things 3 did not respond within 5 seconds. It may be starting up — try again."
        case .scriptError(let msg):
            return "Things 3 script error: \(msg)"
        case .parseError(let msg):
            return "Could not parse Things 3 data: \(msg)"
        case .invalidURL:
            return "Could not construct Things 3 URL scheme."
        }
    }
}
