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
// write is verified by reading state back over JXA (read-after-write): updates
// re-read the task's changed fields; adds poll the creation window for the
// new task by title.
//
// Key quirks documented in ENGINEERING_INVARIANTS.md:
// - App name is "Things 3" (with space) on older installs, "Things3" on newer
// - Ghost tasks with empty names exist and must be filtered
// - The `list` URL param expects a project/area title; built-in lists use `when`
// - Things 3 can hang on launch, so we enforce a 10-second timeout
// - The write auth token lives in the keychain (service things-url-auth-token)
actor ThingsService {
    // 10s guard against a hung Things; the bulk fetch normally runs <1s.
    // (Was 5.0 — the per-item fetch grew past it and every read silently
    // fell back to cache. Keep headroom, but never let the fetch creep up.)
    private let timeoutSeconds: Double = 10.0

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
    ///
    /// PERFORMANCE INVARIANT: every property is read as a BULK Apple Event
    /// (one event per property per collection), never in a per-item loop.
    /// Each Apple event costs tens of milliseconds against Things, so cost
    /// scales with EVENT count — a per-item loop once blew the JXA timeout
    /// and silently put the whole app into cached read-only mode. Measured
    /// figures live in ~/code_ThingsEngage/INVARIANTS.md §9 (the single home
    /// for them). The bulk form runs in under a second.
    func fetchAllTasks() async throws -> [BriefingTask] {
        let script = """
        (() => {
            \(resolveApp)
            const isoOrNull = d => d ? d.toISOString() : null;

            // 1. List membership: ids only — one event per list. Priority
            // order matters: a task scheduled for Today also appears in
            // Anytime, and first-list-wins keeps the most specific label.
            const listNames = ["Inbox", "Today", "Upcoming", "Anytime", "Someday"];
            const listIds = {};
            for (const L of listNames) {
                try { listIds[L] = app.lists.byName(L).toDos.id(); } catch(e) { listIds[L] = []; }
            }

            // 2. Project ownership: ONE bulk event — the id-aligned project
            // name of every to-do (null when the task isn't in a project),
            // so cost stays O(1) events as project count grows. Falls back
            // to the per-project ids loop (O(projects) events) if the bulk
            // form ever errors.
            const T = app.toDos;
            const ids = T.id();
            const idToProject = {};
            let bulkProjectNames = null;
            try { bulkProjectNames = T.project.name(); } catch(e) {}
            if (bulkProjectNames) {
                for (let i = 0; i < ids.length; i++) {
                    if (bulkProjectNames[i] !== null) idToProject[ids[i]] = bulkProjectNames[i];
                }
            } else {
                const projs = app.projects;
                const projNames = projs.name();
                for (let pi = 0; pi < projNames.length; pi++) {
                    let pids = [];
                    try { pids = projs[pi].toDos.id(); } catch(e) {}
                    for (const pid of pids) { idToProject[pid] = projNames[pi]; }
                }
            }

            // 3. One global bulk read per remaining property across all todos
            const names = T.name(), dues = T.dueDate(), notes = T.notes(),
                  tags = T.tagNames(), statuses = T.status(),
                  created = T.creationDate(), modified = T.modificationDate();

            const listOf = {};
            for (const L of listNames) {
                for (const id of listIds[L]) { if (!(id in listOf)) listOf[id] = L; }
            }

            // 4. Assemble — same membership semantics as the old per-item
            // version: the five flat lists plus project-contained tasks
            const results = [];
            for (let i = 0; i < ids.length; i++) {
                const id = ids[i];
                const inList = id in listOf;
                if (!inList && !(id in idToProject)) continue;
                const name = names[i];
                // Filter ghost tasks — Things 3 sometimes has empty-name entries
                if (!name || name.length === 0) continue;
                results.push({
                    id: id,
                    name: name,
                    project: idToProject[id] || null,
                    list: inList ? listOf[id] : "Anytime",
                    dueDate: isoOrNull(dues[i]),
                    notes: notes[i] || null,
                    tags: tags[i] || "",
                    status: statuses[i],
                    creationDate: isoOrNull(created[i]),
                    modificationDate: isoOrNull(modified[i])
                });
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

            let iso = ISO8601DateFormatter()
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
                source: .things3,
                creationDate: raw.creationDate.flatMap { iso.date(from: $0) },
                modificationDate: raw.modificationDate.flatMap { iso.date(from: $0) }
            )
        }
    }

    /// Fetch only Today tasks (convenience for the popover).
    func fetchTodayTasks() async throws -> [BriefingTask] {
        let all = try await fetchAllTasks()
        return all.filter { $0.list == .today && !$0.isCompleted }
    }

    // MARK: - Read Tags

    /// All tag names defined in Things. Tag UI must restrict itself to these:
    /// the URL scheme cannot create tags, and `add-tags` with an unknown tag
    /// is silently dropped. New tags are created once in the Things UI.
    func fetchTagNames() async throws -> [String] {
        let script = """
        (() => {
            \(resolveApp)
            return JSON.stringify(app.tags.name());
        })()
        """
        let output = try await runJXA(script)
        guard let data = output.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            throw ThingsError.parseError("Could not parse tag names")
        }
        return names
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

    /// Rename, reschedule, set a deadline, and/or append tags on an existing
    /// task via `things:///update`. At least one change parameter is required.
    ///
    /// - title: replaces the task's name
    /// - when: "today", "tomorrow", "evening", "anytime", "someday",
    ///   "YYYY-MM-DD", or "YYYY-MM-DD@HH:MM"
    /// - deadline: "YYYY-MM-DD"
    /// - addTags: appended non-destructively (`tags=` would replace the set).
    ///   Tags MUST already exist in Things or they are silently dropped —
    ///   the URL scheme cannot create tags.
    ///
    /// Verification is field-specific (INVARIANTS.md §14): each changed field
    /// is read back and compared, because a modification-date bump alone
    /// cannot catch a silently-dropped unknown tag, and Things reports mod
    /// dates at whole-second granularity — two writes to one task in the same
    /// second read back EQUAL dates, so strict `>` would false-fail rapid
    /// sequential updates. Caveat: setting a field to its current value may
    /// not bump the date, which can surface as verificationFailed on a change
    /// that was a no-op when no field check applies.
    func updateTask(
        id: String,
        title: String? = nil,
        when: String? = nil,
        deadline: String? = nil,
        addTags: [String]? = nil
    ) async throws {
        let token = try await authToken()
        var queryItems = [
            URLQueryItem(name: "auth-token", value: token),
            URLQueryItem(name: "id", value: id)
        ]
        if let title {
            queryItems.append(URLQueryItem(name: "title", value: title))
        }
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

        // Snapshot BEFORE the write (§14 step 1) — the read-back is compared
        // against this. Then verify each changed field, not just the mod date.
        let before = try await fetchTaskState(id: id)
        let expectedActivationYmd = Self.expectedActivationYmd(forWhen: when)
        try await openThingsURL(command: "update", queryItems: queryItems)
        try await verifyWrite(id: id, description: "update") { state in
            // >= not >: mod dates are whole-second, so a same-second write
            // legitimately reads back equal. The field checks below are what
            // prove the write landed; the strict bump is only required when
            // no field is checkable (e.g. when="anytime" alone), because
            // >= is vacuously true if nothing was written at all.
            guard state.modificationMs >= before.modificationMs else { return false }
            var fieldChecked = false
            if let title {
                fieldChecked = true
                guard state.name == title else { return false }
            }
            if let deadline {
                fieldChecked = true
                guard state.dueYmd == deadline else { return false }
            }
            if let addTags, !addTags.isEmpty {
                // The URL scheme silently drops unknown tags (§11) while the
                // other params still bump the mod date — presence in the
                // read-back is the only real proof. Case-insensitive: Things
                // matches tags case-insensitively and reports canonical casing.
                fieldChecked = true
                let present = Set(state.tags.map { $0.lowercased() })
                guard addTags.allSatisfy({ present.contains($0.lowercased()) }) else { return false }
            }
            if when != nil, let expectedActivationYmd {
                fieldChecked = true
                guard state.activationYmd == expectedActivationYmd else { return false }
            }
            return fieldChecked || state.modificationMs > before.modificationMs
        }
    }

    /// The local "YYYY-MM-DD" a task's activation date should read back as
    /// after `when` is applied, or nil when the value has no checkable date
    /// ("anytime"/"someday" clear scheduling, so there is nothing to compare).
    private static func expectedActivationYmd(forWhen when: String?) -> String? {
        guard let when else { return nil }
        switch when {
        case "anytime", "someday":
            return nil
        case "today", "evening", "tomorrow":
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let base = when == "tomorrow"
                ? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                : Date()
            return formatter.string(from: base)
        default:
            // "YYYY-MM-DD" or "YYYY-MM-DD@HH:MM" — the date part is the expectation
            return String(when.prefix(10))
        }
    }

    // MARK: - Create a Task

    /// Create a new task in Things 3 via `things:///add` (creation needs no
    /// auth token). JXA's make/push doesn't work reliably for task creation.
    ///
    /// Verified by creation-window read-back (INVARIANTS.md §14): `add` gives
    /// a shell-style caller no id, so we snapshot the clock before the write
    /// and poll for a task whose name matches and whose creation date falls
    /// after the snapshot. Zero matches within the poll window means the add
    /// silently failed → verificationFailed. Returns the created task's id
    /// when the match is unambiguous (exactly one), nil when several identical
    /// titles landed in the same window. An x-callback-url round trip remains
    /// the planned upgrade for direct id capture without polling.
    @discardableResult
    func createTask(title: String, notes: String? = nil, list: TaskList = .today) async throws -> String? {
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
        // Snapshot BEFORE the write (§14 step 1). Padded a full second back:
        // Things reports dates at whole-second granularity, so a creation
        // date truncated to the top of the current second must not read as
        // "before" the snapshot.
        let sinceMs = Date().timeIntervalSince1970 * 1000 - 1000
        try await openThingsURL(command: "add", queryItems: queryItems)
        return try await verifyCreate(title: title, sinceMs: sinceMs)
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

    /// Task state read back over JXA to confirm a write landed. Carries the
    /// writable fields (name, tags, dates) — verification must check the field
    /// that was changed, because a modification-date bump alone cannot detect
    /// a silently-dropped unknown tag riding along with other params.
    private struct TaskState {
        let status: String
        let name: String
        let modificationMs: Double
        /// Tag names exactly as Things reports them.
        let tags: [String]
        /// Local-time "YYYY-MM-DD" of the scheduled (when) date, nil if unscheduled.
        let activationYmd: String?
        /// Local-time "YYYY-MM-DD" of the deadline, nil if none.
        let dueYmd: String?
    }

    private func fetchTaskState(id: String) async throws -> TaskState {
        // Dates are formatted to local YYYY-MM-DD in JXA (not toISOString,
        // which is UTC and can shift the day for local-midnight dates).
        let script = """
        (() => {
            \(resolveApp)
            const t = app.toDos.byId("\(id)");
            const ymd = d => d
                ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`
                : null;
            return JSON.stringify({
                status: t.status(),
                name: t.name(),
                mod: t.modificationDate().getTime(),
                tags: t.tagNames(),
                activation: ymd(t.activationDate()),
                due: ymd(t.dueDate())
            });
        })()
        """
        let output = try await runJXA(script)
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String,
              let name = json["name"] as? String,
              let mod = json["mod"] as? Double else {
            throw ThingsError.parseError("Could not read back task \(id)")
        }
        // tagNames() is a single ", "-joined string (same format fetchAllTasks parses)
        let tagString = json["tags"] as? String ?? ""
        return TaskState(
            status: status,
            name: name,
            modificationMs: mod,
            tags: tagString.isEmpty ? [] : tagString.components(separatedBy: ", "),
            activationYmd: json["activation"] as? String,
            dueYmd: json["due"] as? String
        )
    }

    /// Poll for a task created after `sinceMs` whose name matches `title` —
    /// the read-back that proves a `things:///add` actually landed. Three
    /// bulk events per attempt (ids, names, creation dates), never a
    /// per-item loop (§9). Returns the new task's id when exactly one task
    /// matches, nil when the match is ambiguous (several identical titles
    /// created inside the window — the add still verifiably landed).
    private func verifyCreate(title: String, sinceMs: Double) async throws -> String? {
        // JSON-encode the title so quotes/backslashes can't break the script.
        guard let titleData = try? JSONEncoder().encode([title]),
              let titleJson = String(data: titleData, encoding: .utf8) else {
            throw ThingsError.parseError("Could not encode title for create verification")
        }
        let script = """
        (() => {
            \(resolveApp)
            const wanted = \(titleJson)[0];
            const T = app.toDos;
            const ids = T.id(), names = T.name(), created = T.creationDate();
            const matches = [];
            for (let i = 0; i < ids.length; i++) {
                if (names[i] === wanted && created[i] && created[i].getTime() >= \(sinceMs)) {
                    matches.push(ids[i]);
                }
            }
            return JSON.stringify(matches);
        })()
        """
        for attempt in 0..<5 {
            // Same cadence as verifyWrite: short beat, then longer retries
            try await Task.sleep(nanoseconds: attempt == 0 ? 300_000_000 : 500_000_000)
            guard let output = try? await runJXA(script),
                  let data = output.data(using: .utf8),
                  let matches = try? JSONDecoder().decode([String].self, from: data) else { continue }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { return nil }
        }
        throw ThingsError.verificationFailed(
            "Things did not confirm creation of \"\(title)\". "
            + "The add may have been silently dropped — check that Things is running."
        )
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
    let creationDate: String?
    let modificationDate: String?
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
            return "Things 3 did not respond within 10 seconds. It may be starting up — try again."
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
