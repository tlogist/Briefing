# Engineering Invariants — Briefing.app

> Hard constraints and non-obvious rules for this project.
> Any agent working on this codebase must read and follow these.

---

## Things 3 Integration

### Write channel (canonical — do not regress this)

The canonical rules live in `~/code_ThingsEngage/INVARIANTS.md`; this app
implements them. Summary of what's binding here:

- **READ via JXA, WRITE via the `things:///` URL scheme. JXA must NEVER mutate
  tasks.** The URL scheme is the only write path Cultured Code supports; the
  JXA write path is unreliable (make/push silently fails) and bypasses the
  system's single audited write channel. `ThingsService.completeTask` was
  converted from a JXA status mutation to `things:///update` on 2026-08-28.
- **`update` requires the auth token; `add` does not.** The token lives in the
  macOS keychain (service `things-url-auth-token`, account = login user) and is
  read by shelling out to `/usr/bin/security find-generic-password` — NOT the
  Security framework. Why: the app is ad-hoc signed, so its signature changes
  every rebuild and a framework read would re-prompt for keychain access each
  time; `/usr/bin/security` is Apple-signed and created the item, so reads go
  through silently. Accepted tradeoff: any local process can read the token the
  same way. The token is **per-machine** — never sync or commit it.
- **Every update is verified by read-after-write, field-specifically.** The URL
  scheme returns no result to `open`-style callers and fails silently (wrong id,
  missing tag, bad token). After each write, ThingsService polls the task back
  over JXA and checks the FIELD that was changed: completion → `status ==
  "completed"`; title → name matches; reschedule/deadline → the date reads back;
  tags → the tag is PRESENT in `tagNames` (a mod-date bump cannot catch a
  silently-dropped unknown tag). The mod-date guard is `>=`, not `>` — Things
  reports modification dates at whole-second granularity, so two writes to one
  task in the same second read back equal dates and strict `>` false-fails.
  A write that isn't confirmed within ~2.5s throws `verificationFailed`.
  `add` is verified by creation-window read-back: snapshot the clock before
  the write (padded 1s back for whole-second dates), then poll for a task
  with the matching name created after the snapshot — exactly one match also
  yields the created id. x-callback-url remains the planned upgrade for
  direct id capture without polling.
- **The `list` URL param is a project/area TITLE, not a built-in list.**
  `list=today` matches nothing and the task silently lands in Inbox (this was
  a live bug until 2026-08-28). Target built-in lists with `when=` (today,
  tomorrow, evening, anytime, someday, or a date). `TaskList.whenParameterValue`
  encodes the mapping.
- **Tags cannot be created via the URL scheme.** `add-tags` with a tag that
  doesn't exist in Things is silently dropped. New tags must be created once in
  the Things UI. Use `add-tags` (appends), never `tags` (replaces).
- **Writes require a successful live Things read this load.** `writesEnabled` is
  true only after `fetchAllTasks` / `fetchTodayTasks` succeeded; there is no cached
  mode any more (removed 2026-09-09), so a failed read empties the list, shows the
  error, and hides every write affordance.

### AI maintenance triage (Tidy Up)

- **Claude proposes; the human approves; ThingsService writes.** `MaintenanceService`
  asks Claude for structured proposals (forced `tool_choice` on a `propose_actions`
  tool — the structured-output path for our raw-HTTP client) and every write goes
  through ThingsService's verified URL-scheme channel. Never let proposal code
  write directly.
- **Validate proposals before showing them.** Task ids must exist in the fetched
  set and `add_tag` values must be in the live tag vocabulary — an unknown tag
  would be silently dropped by the URL scheme and fake-succeed. Invalid
  proposals are dropped, not repaired.
- **Proposals run against LIVE task state only** (`fetchAllTasks()`, not the
  cache) and the whole feature is gated on `writesEnabled` + API key.
- **`creationDate`/`modificationDate` on BriefingTask are optional vars with nil
  defaults** so todo.md-parsed tasks and pre-existing cache JSON keep working;
  they exist to compute idle-days for staleness reasoning.

### Read-side quirks

- **App name varies by version.** Older installs register as `"Things 3"` (with
  a space), newer ones as `"Things3"` (no space). JXA scripts must try both —
  use the `resolveApp` snippet in ThingsService rather than hardcoding either name.
- **JXA `make`/`push` does NOT work for creating tasks.** Use the URL scheme
  (`things:///add`) — see the write-channel rules above.
- **Ghost tasks exist.** Things 3 sometimes has tasks with empty names. Always filter
  `task.name().length === 0` before processing.
- **JXA dates carry fractional seconds — default ISO8601DateFormatter rejects them.**
  JXA's `toISOString()` always emits milliseconds (`2026-09-11T04:00:00.000Z`); a
  default-configured `ISO8601DateFormatter` returns nil for that shape, and the
  failure is silent (`date(from:)` → nil, no error). This nil'd EVERY JXA-sourced
  date (due/scheduled/creation/modification) until 2026-08-31 — task rows showed no
  dates and idle-days staleness was always unknown. Parse JXA dates only through
  `ThingsService.parseJXADate`, which tries `.withFractionalSeconds` first and the
  plain shape second. Pinned by `ThingsServiceDateParsingTests`.
- **The "when" date is `activationDate` in JXA, `dueDate` is the deadline.** Things'
  UI "scheduled for" date and its deadline are separate fields; a task can have
  either or both. `BriefingTask.scheduledDate` carries the activation date;
  `upcomingScheduledDate` hides it for today/past activations (already implied by
  the Today list) and when it lands on the same day as the deadline (the "due …"
  label already shows that date) so rows only show it when it adds information.
- **10-second timeout on JXA calls** (the same guard the Build System section's
  read-only failure mode describes). Things 3 can hang, especially if it's
  launching. Always use `Process` with a timeout, never block the main thread.
- **Tasks appear in multiple lists.** A task scheduled for Today still appears
  in `lists.byName("Anytime").toDos()` (its project's default list). The JXA
  script enumerates lists in priority order (Inbox → Today → Upcoming → Anytime
  → Someday) and tracks seen IDs in an object (`seen[tid]`). This ensures each
  task appears exactly once, assigned to its most specific list.

## Calendar Rules

- **cal:Home is the ONE joint calendar Michael shares with Noosh** (renamed from
  "Noosh's calendar" 2026-08-28; confirmed 2026-09-09 that no separate Noosh calendar
  exists). Events from `cal:Home` appear in a separate "Family Calendar" section — never
  merged into Michael's main timeline, never in conflict detection.
- **The prompt template and the substitution code must agree on placeholder names.**
  `BriefingPrompt.txt` carried `{{NOOSH_EVENTS}}` for twelve days after the code switched
  to `{{FAMILY_EVENTS}}`; Claude received the literal placeholder and Home events never
  reached a briefing. When renaming a placeholder, grep the `.txt` resource too — the
  compiler cannot catch it.
- **All other Apple calendars are Michael's** — merge into the main timeline alongside
  work calendar events.
- **Free windows must be ≥45 minutes** to be flagged as useful for deep work.

## Task Data Flow

- **Things 3 is the single source of truth for tasks.** The briefing prompt is populated
  directly from live Things 3 data via JXA — never from todo.md.
- **todo.md is a one-way export.** After each briefing generation, a snapshot of Things 3
  tasks is written to todo.md as a human-readable archive. This file is never read back
  into the briefing prompt.
- **todo-log.md is still read** for recent activity context in the briefing prompt.
- **MarkdownParser/Writer still exist** for legacy support and the export format, but
  they are no longer in the critical path for briefing generation.

## todo.md Format (Export)

- Sections are grouped by Things 3 list (Today, Inbox, Upcoming, Anytime, Someday).
- Project sub-headings (### level) group tasks within each list section.
- The file header shows the export timestamp and a "do not edit" notice.

## iCloud Drive

- **Task system path:** `~/Library/Mobile Documents/com~apple~CloudDocs/To-Do Briefing/`
- This path must be configurable in Settings since it could differ between machines.
- **Use NSFileCoordinator for reads** — iCloud Drive may be syncing when we access files.

## Build System

- **Use Swift 5 language mode** (`SWIFT_VERSION: 5.0`). Swift 6 strict concurrency
  causes build failures with Foundation types like `ISO8601DateFormatter` that aren't
  `Sendable`. We use the Swift 6.2 compiler but opt into Swift 5 language semantics.
- **`xcode-select` points to CLT, not Xcode.app.** Must prefix builds with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` to use full Xcode.
- **Ad-hoc signing for development** (`CODE_SIGN_IDENTITY: "-"`). No provisioning
  profile or dev team needed. Entitlements file is NOT referenced in build settings
  (causes signing errors); calendar/Apple Events permissions are granted at runtime
  via Info.plist usage description strings.
- **⚠️ The read-only failure mode: ANY fetchAllTasks failure → empty task list + error
  text, no checkboxes, no quick-add.** (Until 2026-09-09 it fell back to a stale iCloud
  cache instead, which hid the failure and showed completed tasks as open.) Known causes:
  1. **JXA timeout (the 2026-08-28 incident):** each Apple event against Things costs
     tens of ms, so per-item property loops blow the timeout as task count or property
     count grows. fetchAllTasks MUST use bulk reads (one event per property per
     collection — see the PERFORMANCE INVARIANT comment on it; the measured figures
     live in `~/code_ThingsEngage/INVARIANTS.md` §9, their single home). Timeout
     guard is 10s.
  2. **Automation (Apple Events) permission** — possible after signature changes (ad-hoc
     signing changes per build). If macOS prompts "Briefing wants to control Things3",
     approve it; recover a denied state with `tccutil reset AppleEvents
     com.ammaturo.Briefing` + relaunch. A stable signing identity would make grants
     durable across rebuilds.
- **Run `xcodegen generate`** after changing `project.yml` — it regenerates the
  entire `.xcodeproj`. Never edit `.xcodeproj` by hand.
- **Test target needs `GENERATE_INFOPLIST_FILE: YES`** and its own `CODE_SIGN_IDENTITY: "-"`.

## macOS Target

- **Minimum macOS 14 (Sonoma).** Required for `MenuBarExtra(.window)` style and
  `requestFullAccessToEvents` in EventKit.
- **LSUIElement=YES in Info.plist.** The app should not appear in the Dock.
- **Distribute outside App Store.** The sandbox blocks Apple Events needed for Things 3.
- **The live copy is /Applications/Briefing.app** (since 2026-08-28). Install flow after
  changes: `xcodebuild -configuration Release build`, then `ditto` the Release product
  from DerivedData to /Applications, then relaunch. The Debug build in DerivedData is
  for development only — don't assume it's what the user is running.
- **Two surfaces, one set of services.** The popover (MenuBarPopover, fixed 360×520) is
  the glance surface; the Briefing window (BriefingWindow.swift) is the resizable task
  workbench, opened via the header's ↗ button. The window uses the SettingsWindowController
  NSPanel pattern (`.nonactivatingPanel` — NSApp.activate() blanks the menu bar in an
  LSUIElement app) but adds `.resizable` at `.normal` level. Both surfaces share the same
  service instances and the iCloud briefing files; each keeps its own view state (including
  separate chat conversations). Write affordances in the window follow the same
  `writesEnabled` gate (live Things read succeeded) as the popover.
- **Exposé selection requires an ACTIVATING window.** With `.nonactivatingPanel`,
  macOS refuses to activate the app even when the user selects the window in
  Exposé/Mission Control (verified 2026-09-02: an AX raise leaves `frontmost` false).
  The system then hands focus back to the previously active app, whose window gets
  re-raised over the panel — "comes forward, then jumps one back." No amount of
  `orderFrontRegardless()` from observers fixes this, because no activation event
  ever fires. Fix: the workbench panel omits `.nonactivatingPanel`; it uses
  `WorkbenchPanel` (`canBecomeKey`/`canBecomeMain` true — stock NSPanel refuses main,
  which Exposé's z-order restore needs) plus a `didBecomeActiveNotification` observer
  that re-asserts front on the next runloop tick after activation churn.
- **The menu-bar-blanking rationale is stale for the workbench.** SwiftUI's App
  lifecycle gives Briefing a real main menu (6 items, verified via AX), so activating
  the app shows Briefing's menus — no blanking. The Settings panel keeps
  `.nonactivatingPanel` deliberately (a transient utility shouldn't steal activation),
  not because activation is unsafe.

## Single Machine, Live Data Only (since 2026-09-09)

- **There is no work Mac and no cross-machine fallback.** The iCloud-Drive caches
  `personal-calendar-cache.json` and `things-task-cache.json`, the "personal events
  exist → write, else read cache" heuristic, and the `"noosh"` legacy decoder were all
  removed on 2026-09-09. Do NOT reintroduce a cached fallback for calendar or task
  reads: on a single machine a fallback path can only ever show wrong data. Both halves
  of the 2026-09-09 incident were that path firing — a deleted event and a completed
  task shown as live, and the MA.com account's events missing because the cache never
  held them. The orphaned cache files in the iCloud folder are inert and can be deleted.
- **Calendar reads use a FRESH `EKEventStore` per fetch** (`CalendarService.makeStore`).
  The app ran six days on one store; after calaccessd (the daemon EventKit talks to,
  relaunched on demand) restarted underneath it, every query returned zero events — no
  error, nothing logged — while a new store in a shell script saw everything. A store
  that reports zero calendars throws `CalendarError.noCalendars` instead of returning
  an empty list.
- **A failed read fails loudly.** Popover/window: empty list + error text, write
  affordances hidden. Briefing engine: a Things or calendar failure aborts the briefing
  (`gatherTasksData` throws). Scheduler: one retry after 60 s, then a "Briefing Skipped"
  notification carrying the reason.
- **Diagnosing "wrong events" from a shell:** iTerm already has Full Access to Calendars,
  so a `swift` script using EventKit enumerates sources / calendars / events without a
  TCC prompt. Compare against what the app shows; if they differ, the app's read path is
  broken, not the data. The michael@michaelammaturo.com account appears as source
  "MA.com" / calendar "MichaelAmmaturo.com".
- The `.task-system/personal-calendar-cache.txt` in the iCloud folder belongs to the
  Claude Code `/briefing` pipeline (`ical.py`, `cal-sync.sh`), not to this app.

## Briefing Cache (iCloud Drive)

- **Briefings are cached to iCloud Drive, not UserDefaults.** Files live at
  `{taskDirectoryPath}/briefing-{scope}.json` (e.g., `briefing-today.json`,
  `briefing-week.json`). They persist across relaunches and are how the
  scheduler hands a finished briefing to the popover — no re-call to Claude.
- **Never delete the briefing file for staleness.** `invalidateStaleBriefings()`
  only clears the **in-memory** `briefingCache` dictionary — the file on disk
  stays and gets naturally overwritten when a new briefing is generated.
- **Load from disk AFTER invalidation, not before.** In `loadAll()`, the order
  is: (1) fetch fresh calendar + tasks, (2) `invalidateStaleBriefings()` clears
  stale in-memory entries, (3) reload from iCloud Drive files to fill empty slots.
  If you load before invalidation, the freshly-loaded briefing gets immediately
  nuked when its task fingerprint (from generation time) no longer matches.
- **`showOrGenerate` checks in-memory cache first.** If a briefing is in
  `briefingCache[scope]`, it's shown instantly. Otherwise Claude is called.
  The iCloud reload in `loadAll()` is what populates in-memory from disk.

## Claude API

- **Default model: claude-sonnet-4-6.** Configurable in settings.
- **API key stored in UserDefaults** (via `KeychainService` wrapper). Currently uses
  UserDefaults because ad-hoc signing triggers Keychain access prompts. Switch to
  real Keychain (Security framework) when the app is properly code-signed.
- **Cost per briefing: ~$0.06-0.09.** Acceptable for daily use.
- **180-second request timeout.** The non-streaming API sends zero bytes until
  the full response is generated. `URLSession.timeoutInterval` is an idle-between-
  packets timeout, so the entire generation time counts as "idle." Weekly briefings
  with ~10K input tokens routinely need 50-60s; 180s provides safe margin.

## Scheduled Briefing Generation

- **In-process Timer, not launchd/cron.** The app is a persistent menu bar app
  (`LSUIElement=YES`) that stays running indefinitely. `BriefingScheduler` uses
  `Timer` on the main RunLoop to fire at computed dates. This avoids the
  complexity of launchd plists and the permission issues they bring.
- **Two independent schedules.** Daily (generates `.today` scope) and weekly
  (generates `.week` scope) are fully independent — each has its own Timer,
  enable toggle, and time settings. They don't interact.
- **Scheduler writes to disk, popover reads from disk.** `BriefingScheduler`
  calls `BriefingEngine.generateBriefing()` and saves via `BriefingCache.save()`.
  It does NOT update in-memory popover state. The popover's `loadAll()` reloads
  from iCloud Drive files on every open, picking up scheduler-generated briefings.
- **Wake-from-sleep recovery.** The scheduler records when the Mac goes to sleep
  (`willSleepNotification`). On wake (`didWakeNotification`), it checks whether
  either schedule's fire date fell inside the sleep window. If so, it fires
  immediately — then reschedules for the next occurrence.
- **Block-based Timer API.** Uses `Timer(fire:interval:repeats:block:)` instead
  of `@objc` selector-based timers. This avoids requiring `NSObject` inheritance,
  which would conflict with the `@Observable` macro.
- **Scheduler must start in `BriefingApp.init()`, not in a `.task` modifier.**
  `MenuBarExtra` with `.window` style creates its content view lazily — only
  when the user first clicks the menu bar icon. A `.task` on the popover
  would miss any schedule that fires before the first click. The scheduler
  is created eagerly in `init()` using `State(initialValue:)`.
- **Settings change → manual reschedule.** The SettingsView uses `.onChange`
  modifiers to call `scheduler.rescheduleDaily()` / `rescheduleWeekly()` when
  the user changes schedule settings. The scheduler does not auto-observe
  settings because `withObservationTracking` is awkward for this use case.

## Dual-Output Strategy (Popover vs Export)

- **Popover uses markdown, export uses HTML.** Claude always outputs markdown
  (bullet lists, bold/italic) because that's what the narrow popover can render.
  `BriefingHTMLExporter` post-processes this markdown into a styled HTML document
  for PDF export — tables, colored section blocks, dark Bottom Line box.
- **Never change Claude's output format for export.** The markdown must remain
  popover-friendly. All rich formatting is applied in the HTML conversion layer.
- **Export workflow: HTML → Safari → Print → PDF.** The app writes an HTML file
  to the temp directory and opens it in the default browser. The user uses
  File > Print > Save as PDF. This avoids wrestling with `NSPrintOperation` and
  `NSAttributedString` limitations.
- **Calendar bullets follow a convention.** Claude outputs calendar events as
  `**TIME:** Event description` bullets. The HTML exporter pattern-matches these
  into `<table>` rows with time/event columns. Conflict rows get red styling,
  free windows get green.
