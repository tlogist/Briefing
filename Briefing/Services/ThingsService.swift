import AppKit
import Foundation

// Talks to Things 3 over the two sanctioned channels:
//   READ  → JXA via `osascript -l JavaScript` against the live app
//   WRITE → the `things:///` URL scheme (`add` needs no token; `update` does)
//
// This mirrors the canonical rules in ~/code_ThingsEngage/INVARIANTS.md: JXA
// must never mutate tasks. The URL scheme is the only write path Cultured Code
// supports, and the JXA write path has already proven unreliable here
// (make/push silently fails). Because the URL scheme returns no result, every
// update is verified by reading the task back over JXA (read-after-write).
//
// Key quirks documented in ENGINEERING_INVARIANTS.md:
// - App name is "Things 3" (with space) on older installs, "Things3" on newer
// - Ghost tasks with empty names exist and must be filtered
// - The `list` URL param expects a project/area title; built-in lists use `when`
// - Things 3 can hang on launch, so we enforce a 5-second timeout
// - The write auth token lives in the keychain (service things-url-auth-token)
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

    /// Mark a task as completed via `things:///update` — the only sanctioned
    /// write channel (JXA writes are forbidden; see ENGINEERING_INVARIANTS.md).
    /// The URL scheme is fire-and-forget, so we confirm by reading the task's
    /// status back over JXA and throw if it never flipped.
    func completeTask(id: String) async throws {
        let token = try await authToken()
        try await openThingsURL(command: "update", queryItems: [
            URLQueryItem(name: "auth-token", value: token),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "completed", value: "true")
        ])

        try await verifyWrite(id: id, description: "completion") { state in
            state.status == "completed"
        }
    }

    // MARK: - Update a Task

    /// Reschedule, set a deadline, and/or append tags on an existing task via
    /// `things:///update`. At least one change parameter is required.
    ///
    /// - when: "today", "tomorrow", "evening", "anytime", "someday",
    ///   "YYYY-MM-DD", or "YYYY-MM-DD@HH:MM"
    /// - deadline: "YYYY-MM-DD"
    /// - addTags: appended non-destructively (`tags=` would replace the set).
    ///   Tags MUST already exist in Things or they are silently dropped —
    ///   the URL scheme cannot create tags.
    ///
    /// Verification is a modification-date bump: any applied update rewrites
    /// the item. Caveat: setting a field to its current value may not bump the
    /// date, which surfaces as verificationFailed on a change that was a no-op.
    func updateTask(
        id: String,
        when: String? = nil,
        deadline: String? = nil,
        addTags: [String]? = nil
    ) async throws {
        let token = try await authToken()
        var queryItems = [
            URLQueryItem(name: "auth-token", value: token),
            URLQueryItem(name: "id", value: id)
        ]
        if let when {
            queryItems.append(URLQueryItem(name: "when", value: when))
        }
        if let deadline {
            queryItems.append(URLQueryItem(name: "deadline", value: deadline))
        }
        if let addTags, !addTags.isEmpty {
            queryItems.append(URLQueryItem(name: "add-tags", value: addTags.joined(separator: ",")))
        }
        guard queryItems.count > 2 else {
            throw ThingsError.scriptError("updateTask called with nothing to change")
        }

        // Snapshot the modification date first — the bump after the write is
        // the one generic ack the write-only URL scheme can't give us itself.
        let before = try await fetchTaskState(id: id)
        try await openThingsURL(command: "update", queryItems: queryItems)
        try await verifyWrite(id: id, description: "update") { state in
            state.modificationMs > before.modificationMs
        }
    }

    // MARK: - Create a Task

    /// Create a new task in Things 3 via `things:///add` (creation needs no
    /// auth token). JXA's make/push doesn't work reliably for task creation.
    /// No read-back verification: `add` returns no id to read back — capturing
    /// it needs an x-callback-url round trip (planned, not yet built).
    func createTask(title: String, notes: String? = nil, list: TaskList = .today) async throws {
        var queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "show-quick-entry", value: "false")
        ]
        // Built-in lists are targeted with `when` — the `list` param expects a
        // project/area title, so e.g. `list=today` matched nothing and every
        // task silently landed in Inbox (the old behavior of this method).
        if let when = list.whenParameterValue {
            queryItems.append(URLQueryItem(name: "when", value: when))
        }
        if let notes = notes, !notes.isEmpty {
            queryItems.append(URLQueryItem(name: "notes", value: notes))
        }
        try await openThingsURL(command: "add", queryItems: queryItems)
    }

    // MARK: - Check if Things 3 is Running

    func isThingsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.culturedcode.ThingsMac"
        }
    }

    // MARK: - Auth Token (URL-scheme writes)

    /// Cached after the first successful keychain read. The token is
    /// per-install and doesn't change while the app runs; restart the app
    /// after regenerating it in Things settings.
    private var cachedAuthToken: String?

    /// Read the Things URL-scheme auth token from the macOS keychain by
    /// shelling out to `/usr/bin/security` — the same item the ThingsEngage
    /// CLI recipes use (service "things-url-auth-token").
    ///
    /// Why a subprocess instead of the Security framework: this app is ad-hoc
    /// signed, so its code signature changes every rebuild and a framework
    /// read would re-prompt for keychain access each time. `/usr/bin/security`
    /// is Apple-signed and created the item, so reads go through silently —
    /// and the token stays in one shared, per-machine location.
    private func authToken() async throws -> String {
        if let cached = cachedAuthToken { return cached }

        let result = try await runProcess(
            executablePath: "/usr/bin/security",
            arguments: [
                "find-generic-password",
                "-a", NSUserName(),
                "-s", "things-url-auth-token",
                "-w"
            ],
            timeout: timeoutSeconds
        )

        guard result.status == 0, !result.stdout.isEmpty else {
            throw ThingsError.noAuthToken
        }
        cachedAuthToken = result.stdout
        return result.stdout
    }

    // MARK: - URL Scheme Invocation

    /// Build and open a `things:///<command>?...` URL without activating
    /// Things — background maintenance writes shouldn't yank it to the front.
    private func openThingsURL(command: String, queryItems: [URLQueryItem]) async throws {
        var components = URLComponents(string: "things:///\(command)")!
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ThingsError.invalidURL
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                if error != nil {
                    continuation.resume(throwing: ThingsError.notRunning)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Write Verification (read-after-write)

    /// Minimal task state read back over JXA to confirm a write landed.
    private struct TaskState {
        let status: String
        let modificationMs: Double
    }

    private func fetchTaskState(id: String) async throws -> TaskState {
        let script = """
        (() => {
            \(resolveApp)
            const t = app.toDos.byId("\(id)");
            return JSON.stringify({
                status: t.status(),
                mod: t.modificationDate().getTime()
            });
        })()
        """
        let output = try await runJXA(script)
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String,
              let mod = json["mod"] as? Double else {
            throw ThingsError.parseError("Could not read back task \(id)")
        }
        return TaskState(status: status, modificationMs: mod)
    }

    /// Poll the task after a URL-scheme write until `check` passes. Things
    /// processes URLs asynchronously but usually well under a second.
    private func verifyWrite(
        id: String,
        description: String,
        check: (TaskState) -> Bool
    ) async throws {
        for attempt in 0..<5 {
            // Short beat before the first read, longer between retries
            try await Task.sleep(nanoseconds: attempt == 0 ? 300_000_000 : 500_000_000)
            if let state = try? await fetchTaskState(id: id), check(state) {
                return
            }
        }
        throw ThingsError.verificationFailed(
            "Things did not confirm the \(description) of task \(id). "
            + "Check the auth token (keychain item things-url-auth-token) and that the task still exists."
        )
    }

    // MARK: - Subprocess Execution

    private struct ProcessResult {
        let status: Int32
        let terminationReason: Process.TerminationReason
        let stdout: String
        let stderr: String
    }

    /// Run an external process with a hard timeout (terminated if exceeded).
    /// Shared by JXA reads and the keychain token read.
    private func runProcess(
        executablePath: String,
        arguments: [String],
        timeout: Double
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            // Terminate the process if it hangs past the timeout
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + timeout)
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

                continuation.resume(returning: ProcessResult(
                    status: proc.terminationStatus,
                    terminationReason: proc.terminationReason,
                    stdout: output,
                    stderr: errorOutput
                ))
            }

            do {
                try process.run()
            } catch {
                timer.cancel()
                continuation.resume(throwing: ThingsError.scriptError(error.localizedDescription))
            }
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

        let result = try await runProcess(
            executablePath: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", "-e", script],
            timeout: timeoutSeconds
        )

        if result.status != 0 {
            if result.stderr.contains("is not running") || result.stderr.contains("Connection is invalid") {
                throw ThingsError.notRunning
            } else if result.terminationReason == .uncaughtSignal {
                throw ThingsError.timeout
            } else {
                throw ThingsError.scriptError(result.stderr)
            }
        }
        return result.stdout
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
    case noAuthToken
    case verificationFailed(String)

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
        case .noAuthToken:
            return "No Things auth token in the keychain. In Things: Settings → General → "
                + "Enable Things URLs → Manage, copy the token, then run: "
                + "security add-generic-password -a \"$USER\" -s things-url-auth-token -w 'TOKEN'"
        case .verificationFailed(let msg):
            return "Things 3 write not confirmed: \(msg)"
        }
    }
}
