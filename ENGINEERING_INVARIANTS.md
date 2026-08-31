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
- **Writes require live Things on THIS machine.** When the app is running off
  the iCloud task cache (work Mac, Things not accessible), there is nothing to
  write to and no local token — any write UI must be disabled in cached mode.

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

- **cal:Home is the shared FAMILY calendar** (as of 2026-08-28; it was previously treated
  as Noosh's personal calendar). Events from `cal:Home` appear in a separate
  "Family Calendar" section — never merged into Michael's main timeline. Noosh's
  commitments still land here, but so do shared/family events.
- **Legacy cache compatibility:** pre-rename builds encoded the owner as `"noosh"`.
  `CalendarOwner.init(from:)` maps `"noosh"` → `.family` so cross-machine cache files
  (`personal-calendar-cache.json`) keep decoding while the two Macs are on different
  builds. Keep that mapping until both Macs run post-rename builds.
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
- **⚠️ The silent read-only failure mode: ANY fetchAllTasks failure → cached fallback →
  no checkboxes, no quick-add.** Symptom reads as "clicking tasks does nothing." When
  debugging it, check the mtime of `things-task-cache.json` in the iCloud folder — if it
  stopped updating, live JXA reads are failing. Known causes:
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
  service instances and iCloud caches; each keeps its own view state (including separate
  chat conversations). Write affordances in the window follow the same `writesEnabled`
  gate (live Things + not cached) as the popover.

## Personal Calendar Cache (iCloud Drive)

- **Personal Mac writes, work Mac reads.** When iCloud calendars have actual
  events, the app writes them to `personal-calendar-cache.json` in the shared
  iCloud Drive folder. When iCloud calendars are empty, it reads and merges
  cached events.
- **Detection is EVENT-BASED, not source-based.** Both Macs may have iCloud
  configured in Apple Calendar — the work Mac just has blank iCloud calendars.
  Checking `store.sources` would return true on both. Instead, scan a 14-day
  window for events from any personal source. If any exist → write. If zero →
  read cache.
- **Personal sources are defined in `CalendarService.personalSources`.** Currently:
  iCloud, Bendicoot, Planning Board. Add new personal-only sources there.
- **Cache window is 14 days.** The writer always caches a full 14-day window
  regardless of the requested date range, so the work Mac has enough data for
  both the popover (today) and the week briefing.
- **Cache file is distinct from other files.** It lives at
  `{taskDirectoryPath}/personal-calendar-cache.json` — do not confuse with the
  old `.txt` cache or `PopoverDataCache` (which uses UserDefaults).
- **Cached events are merged, not replaced.** The work Mac combines its live
  work events with cached personal events. All-day events sort first, then
  chronological.

## Things 3 Task Cache (iCloud Drive)

- **Same write/read pattern as the calendar cache.** Personal Mac writes all
  Things 3 tasks to `things-task-cache.json`; work Mac reads as fallback when
  Things 3 is inaccessible (not running, permissions, macOS version issues).
- **Detection is error-based.** Unlike the calendar cache (which checks for
  iCloud events), the Things cache simply tries to fetch and falls back on any
  failure. If Things works → write cache. If Things fails → read cache.
- **Cache contains ALL tasks, not just today's.** The writer caches every list
  (Inbox, Today, Upcoming, Anytime, Someday) so the work Mac can use the full
  set for briefing generation. The popover filters to Today at read time.

## Briefing Cache (iCloud Drive)

- **Briefings are cached to iCloud Drive, not UserDefaults.** Files live at
  `{taskDirectoryPath}/briefing-{scope}.json` (e.g., `briefing-today.json`,
  `briefing-week.json`). Generate on one Mac, the other picks it up via
  iCloud sync — no need to re-call Claude on each machine.
- **Never delete the shared cache file for staleness.** The iCloud Drive file
  is a shared resource between machines. One Mac must not delete what the other
  wrote just because its local task data differs. `invalidateStaleBriefings()`
  only clears the **in-memory** `briefingCache` dictionary — the file on disk
  stays and gets naturally overwritten when a new briefing is generated.
- **Load from disk AFTER invalidation, not before.** In `loadAll()`, the order
  is: (1) fetch fresh calendar + tasks, (2) `invalidateStaleBriefings()` clears
  stale in-memory entries, (3) reload from iCloud Drive files to fill empty slots.
  If you load before invalidation, the freshly-loaded briefing gets immediately
  nuked because the other Mac's task fingerprint doesn't match local tasks.
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
