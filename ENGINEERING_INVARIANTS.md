# Engineering Invariants — Briefing.app

> Hard constraints and non-obvious rules for this project.
> Any agent working on this codebase must read and follow these.

---

## Things 3 Integration

- **App name varies by version.** Older installs register as `"Things 3"` (with
  a space), newer ones as `"Things3"` (no space). JXA scripts must try both —
  use the `resolveApp` snippet in ThingsService rather than hardcoding either name.
- **JXA `make`/`push` does NOT work for creating tasks.** Use the URL scheme instead:
  `things:///add?title=...&notes=...&list=today`. Tasks created this way land in Inbox.
- **Ghost tasks exist.** Things 3 sometimes has tasks with empty names. Always filter
  `task.name().length === 0` before processing.
- **5-second timeout on JXA calls.** Things 3 can hang, especially if it's launching.
  Always use `Process` with a timeout, never block the main thread.

## Calendar Rules

- **cal:Home is Noosh's calendar, NOT Michael's.** Events from `cal:Home` must appear in a
  separate "Noosh's Schedule" section. Never merge them into Michael's main timeline.
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
- **Run `xcodegen generate`** after changing `project.yml` — it regenerates the
  entire `.xcodeproj`. Never edit `.xcodeproj` by hand.
- **Test target needs `GENERATE_INFOPLIST_FILE: YES`** and its own `CODE_SIGN_IDENTITY: "-"`.

## macOS Target

- **Minimum macOS 14 (Sonoma).** Required for `MenuBarExtra(.window)` style and
  `requestFullAccessToEvents` in EventKit.
- **LSUIElement=YES in Info.plist.** The app should not appear in the Dock.
- **Distribute outside App Store.** The sandbox blocks Apple Events needed for Things 3.

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

## Claude API

- **Default model: claude-sonnet-4-5-20250929.** Configurable in settings.
- **API key stored in macOS Keychain** via Security framework. Never write to disk or UserDefaults.
- **Cost per briefing: ~$0.06-0.09.** Acceptable for daily use.
