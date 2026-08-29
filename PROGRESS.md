# Briefing.app — Development Progress

> Native macOS menu bar app that generates daily/weekly briefings from calendar events,
> Things 3 tasks, and todo.md files, using Claude for AI analysis.

**Project location:** `/Users/maa/Developer/Briefing/`
**Task system source:** `~/Library/Mobile Documents/com~apple~CloudDocs/To-Do Briefing/`
**Started:** 2026-02-15

---

## Status: Phase 4+ Complete — Briefing generation, PDF export, chat, caching all working

---

### Session: UI/UX Improvements + Chat + Caching (2026-02-16)

Extensive cross-cutting work spanning phases 4-5 and general polish.

#### Briefing scope and buttons
- [x] Split single "Generate Briefing" into **"Today's Briefing"** and **"Week's Briefing"**
- [x] Moved briefing buttons to the **top** of the popover (above calendar/tasks)
- [x] BriefingScope enum (.today / .week) controls whether BriefingEngine fetches today-only or week-ahead events
- [x] Prompt template heading dynamically adjusted per scope ("Calendar Events (Today)" vs "Next 7 Days")

#### Briefing caching
- [x] BriefingResult + BriefingScope made Codable, persisted to UserDefaults per scope
- [x] Today/Week buttons **show cached results instantly** — only the Refresh icon forces a new Claude call
- [x] Active scope visually highlighted (bold/primary vs regular/secondary)
- [x] Cache survives app restarts

#### PDF export
- [x] Export icon (arrow.down.doc) next to "Briefing" header in completed result
- [x] Uses NSPrintOperation — native print dialog with built-in "Save as PDF"
- [x] Scope-aware titles: "Briefing - February 16, 2026" or "Briefing - Week of February 16, 2026"
- [x] Closes popover first so print dialog isn't blocked

#### Claude chat input bar
- [x] Persistent TextField between Quit and Settings in footer
- [x] Auto-expands vertically as text wraps (up to 5 lines), submits on Return
- [x] Extended ClaudeAPIService with `sendChat` method (multi-turn messages + tool_use support)
- [x] System prompt includes current calendar events and tasks for context
- [x] **Tool use for Things 3:** `add_task` (creates via URL scheme) and `complete_task` (finds by name, completes via JXA)
- [x] Tool_use loop: Claude can chain multiple tool calls before final text response
- [x] Chat bubbles in scroll view (blue tint for user, grey for Claude, markdown rendered)
- [x] Spinner in input bar while Claude is responding
- [x] Task list auto-refreshes after tool execution

#### Popover data caching (stale-while-revalidate)
- [x] PopoverDataCache serializes calendar events, conflicts, free windows, and tasks to UserDefaults
- [x] On popover open: cached data appears **instantly** (no spinner), live refresh runs in background
- [x] Loading spinner only shown on very first launch with no cache
- [x] Made CalendarEvent, FreeWindow, ConflictPair, BriefingTask all Codable for serialization

#### Refresh indicator
- [x] Tiny spinner in header during background EventKit + Things 3 refresh
- [x] "Last updated" relative timestamp: "just now", "2m ago", "1h ago"
- [x] Updates every 60 seconds via existing timer

#### Files modified
| File | Changes |
|------|---------|
| `Briefing/Models/Briefing.swift` | Added BriefingScope enum, BriefingCache helper, made BriefingResult Codable |
| `Briefing/Models/CalendarEvent.swift` | Added Codable to CalendarEvent, FreeWindow, ConflictPair, CalendarOwner; added memberwise inits |
| `Briefing/Models/Task.swift` | Added Codable to TaskList, TaskSource, BriefingTask |
| `Briefing/Services/ClaudeAPIService.swift` | Added ChatResponse struct and sendChat method with tool_use support; refactored sendMessage to use sendChat |
| `Briefing/Services/BriefingEngine.swift` | Added scope parameter, scope-aware calendar fetching, scope-aware prompt heading |
| `Briefing/Views/MenuBarPopover.swift` | Briefing at top, two scope buttons, PDF export, chat input + bubbles, popover cache, refresh indicator |
| `TODO.md` | Marked performance cache items as done |

#### Key implementation details

- **Stale-while-revalidate:** `PopoverDataCache.restore()` fills the state arrays immediately, returning `true` to skip the spinner. `loadAll()` then refreshes live and calls `PopoverDataCache.save()`. Only the first-ever launch shows a spinner.
- **Tool_use loop:** `sendChatMessage()` sends messages to Claude with tool definitions. If Claude's `stop_reason` is `"tool_use"`, it executes each tool via `executeTool()`, sends tool results back, and loops until Claude returns final text.
- **`complete_task` tool** fetches all tasks, finds by case-insensitive name match, then completes by Things 3 ID.
- **Chat history** is stored as `[[String: Any]]` to support both plain text messages and tool_use/tool_result content blocks in the Anthropic API format.

---

### Phase 4 Completed (2026-02-15)
- [x] KeychainService — store/retrieve API key from macOS Keychain (Security framework)
- [x] AuthProvider protocol + APIKeyAuth implementation (x-api-key header)
- [x] ClaudeAPIService — HTTP client for Anthropic Messages API (URLSession, 120s timeout)
- [x] BriefingPrompt.txt — template with {{DATE}}, {{MICHAEL_EVENTS}}, {{NOOSH_EVENTS}}, {{CONFLICTS}}, {{FREE_WINDOWS}}, {{TODO_MD}}, {{SYNC_DIFF}}, {{RECENT_LOG}} placeholders
- [x] BriefingEngine actor — parallel data gathering, prompt assembly, Claude API call
- [x] BriefingResult model with generation metadata (timestamp, model, token counts, source data counts)
- [x] BriefingStatus enum (idle, gatheringData, callingClaude, complete, error)
- [x] BriefingContentView — renders markdown briefing with generation metadata
- [x] BriefingStatusView — shows appropriate UI for each status state
- [x] SettingsView — API key secure field with Keychain save/remove, model picker, task directory, calendar settings
- [x] "Generate Briefing" button in popover with status indicators
- [x] All 24 tests pass, build succeeds

### Key implementation details

- **AuthProvider protocol** decouples the API client from auth mechanism. `APIKeyAuth` reads
  from Keychain and sets `x-api-key` header. Future `OAuthAuth` will set `Authorization: Bearer`.
- **Keychain storage** uses `kSecClassGenericPassword` with service name `com.ammaturo.Briefing`.
  Keys are stored with `kSecAttrAccessibleWhenUnlocked`. Save does delete+add (no upsert API).
- **BriefingEngine is an actor** that gathers calendar, Things 3, and file data in parallel
  via `async let`, then assembles the prompt from the template and calls Claude. Things 3
  failure (not running) is non-fatal — the briefing still works with calendar + file data.
- **Prompt template loaded from Bundle.** Falls back to a hardcoded minimal template if the
  resource file isn't found. Events are grouped by day with formatted time ranges.
- **Status callback pattern** lets the popover update its UI as the engine progresses through
  stages (gathering → calling Claude → complete/error) without polling.
- **Settings uses SecureField** for API key input. Key is saved to Keychain on submit, then
  cleared from the text field. A "Remove" button deletes from Keychain.
- **Model picker** defaults to Sonnet 4.5 (~$0.06/briefing). Haiku and Opus also available.

### Files created

| File | Purpose |
|------|---------|
| `Briefing/Services/KeychainService.swift` | Keychain CRUD for credentials |
| `Briefing/Services/ClaudeAPIService.swift` | AuthProvider protocol + HTTP client for Messages API |
| `Briefing/Services/BriefingEngine.swift` | Actor: parallel data gathering + prompt + Claude call |
| `Briefing/Models/Briefing.swift` | BriefingResult, BriefingStatus |
| `Briefing/Views/BriefingContentView.swift` | Markdown rendering + status views |
| `Briefing/Resources/BriefingPrompt.txt` | Prompt template with placeholders |

### Files modified

| File | Change |
|------|--------|
| `Briefing/BriefingApp.swift` | Replaced SettingsPlaceholderView with full SettingsView, added BriefingEngine creation |
| `Briefing/Views/MenuBarPopover.swift` | Added briefingEngine prop, briefingSection with generate button and status UI |

---

### Phase 3 Completed (2026-02-15)
- [x] MarkdownParser — parse todo.md into structured TodoDocument
- [x] MarkdownWriter — serialize back with round-trip fidelity for unmodified sections
- [x] TaskFileService — read/write todo.md and todo-log.md with NSFileCoordinator
- [x] TaskDiff model — DiffAction enum (addToFile, addToThings, markCompleted, updateInfo, flagStale)
- [x] TaskSyncService — compare Things 3 vs todo.md, generate diffs, apply approved changes
- [x] SyncDiffView — approval UI with grouped diffs, select/deselect all, apply/cancel
- [x] 19 new parser/writer tests + 5 existing calendar tests = 24 total, all passing
- [x] Build succeeds

### Key implementation details

- **Parser model hierarchy:** `TodoDocument` → `TodoSection` → `TodoProject` → `TodoTask`.
  Each level preserves raw lines for round-trip fidelity. Sections have `isModified` flag;
  unmodified sections write back their `rawLines` verbatim.
- **Section detection by emoji prefix.** SectionType enum (🔴/📋/🟠/🟡/🔵/✅) matches
  against `## ` heading lines. Works even if heading text changes (e.g., "Anytime (Unassigned)").
- **Project sub-headings (`### `) only in Projects and Someday.** Tasks after a `###` heading
  belong to that project until the next `###` or section end — even across blank lines.
- **Metadata extraction:** Trailing `*(...)* ` patterns are split from task name. Handles
  nested markdown links, em-dashes, and parenthetical content inside metadata.
- **NSFileCoordinator for iCloud Drive safety.** Both reads and writes go through
  `coordinate(readingItemAt:)` / `coordinate(writingItemAt:)` to avoid reading half-synced files.
- **Fuzzy name matching for sync.** `normalizeForComparison()` strips markdown links,
  collapses whitespace, and lowercases — so "Schedule w/ [Ray Hair](url)" matches
  "Schedule w/ Ray Hair" from Things 3.
- **Diff actions map to concrete operations.** `addToFile` inserts into the appropriate
  section, `addToThings` uses URL scheme via ThingsService, `markCompleted` moves to the
  ✅ section with completion date and project attribution.

### Files created

| File | Purpose |
|------|---------|
| `Briefing/Utilities/MarkdownParser.swift` | Parse todo.md → TodoDocument with sections/projects/tasks |
| `Briefing/Utilities/MarkdownWriter.swift` | Serialize TodoDocument → markdown, timestamp updates, task completion |
| `Briefing/Services/TaskFileService.swift` | iCloud Drive I/O with NSFileCoordinator |
| `Briefing/Models/TaskDiff.swift` | DiffAction enum, TaskDiff struct, SyncResult |
| `Briefing/Services/TaskSyncService.swift` | Diff generation + application (Things 3 ↔ todo.md) |
| `Briefing/Views/SyncDiffView.swift` | Approval UI for sync changes |
| `BriefingTests/MarkdownParserTests.swift` | 19 tests: parsing, metadata, projects, round-trip, writer |

---

### Phase 2 Completed (2026-02-15)
- [x] BriefingTask model — id, name, project, list, dueDate, notes, tags, isCompleted, source
- [x] TaskList enum mapping to Things 3 lists (Inbox, Today, Upcoming, Anytime, Someday)
- [x] TaskSource enum (things3, todoFile, both) for sync diffing later
- [x] ThingsService (actor) — full JXA integration via osascript
- [x] Fetch all tasks from all lists + projects in a single JXA call
- [x] Ghost task filtering (empty names)
- [x] 5-second timeout via DispatchSource timer on Process (historical — raised to 10s on 2026-08-28)
- [x] Complete task via JXA (`t.status = "completed"`)
- [x] Create task via URL scheme (`things:///add?title=...&list=...`)
- [x] Graceful handling: Things 3 not running, timeout, script errors
- [x] MenuBarPopover updated with "Today's Tasks" section
- [x] TaskRow component with overdue indicator and project name
- [x] Calendar and tasks load in parallel (async let)
- [x] ThingsStatus enum for distinct UI states (available, notRunning, error)
- [x] All 5 existing tests still pass
- [x] Build succeeds

### Key implementation details

- **Single JXA call for all data.** Rather than one osascript invocation per list
  (expensive — each one spawns a process and launches the JS runtime), we use one
  script that iterates all lists AND projects, deduplicates by task ID, and returns
  JSON. This also avoids hitting Things 3 with multiple automation requests.
- **Process termination handler + DispatchSource timer for timeout.** We can't use
  `Task.sleep` for timeout because `Process` termination callbacks are not async.
  Instead, a GCD timer fires after the timeout (5s then; 10s since 2026-08-28) and calls `process.terminate()`.
- **ThingsError.notRunning detected two ways:** (1) pre-flight check via
  `NSWorkspace.shared.runningApplications` before launching osascript, and
  (2) parsing stderr for "is not running" / "Connection is invalid" if the
  process fails.
- **Task creation uses URL scheme, not JXA.** `things:///add?title=...&list=today`
  opens Things 3 and creates the task. JXA's `make`/`push` doesn't work. Tasks
  created this way land in Inbox regardless of the `list` parameter — this is a
  Things 3 limitation.
- **`import AppKit` needed for ThingsService** — `NSWorkspace` lives there, not in
  Foundation. Easy to forget since SwiftUI implicitly imports AppKit in views.

### Files created/modified

| File | Action | Purpose |
|------|--------|---------|
| `Briefing/Models/Task.swift` | Created | BriefingTask, TaskList, TaskSource |
| `Briefing/Services/ThingsService.swift` | Created | JXA actor: fetch, complete, create |
| `Briefing/Views/MenuBarPopover.swift` | Modified | Added tasks section, TaskRow, parallel loading |
| `Briefing/BriefingApp.swift` | Modified | Pass ThingsService to popover |

---

## Phase 1 Complete — App builds and runs

### Phase 1 Completed (2026-02-15)
- [x] Installed xcodegen via Homebrew
- [x] Created project.yml with Briefing + BriefingTests targets
- [x] Info.plist with LSUIElement=YES, calendar/Apple Events usage descriptions
- [x] Briefing.entitlements (kept on disk but NOT referenced in build — causes signing issues)
- [x] BriefingApp.swift — @main with MenuBarExtra (.window style) + Settings scene
- [x] CalendarEvent model with CalendarOwner enum (michael/noosh classification)
- [x] FreeWindow and ConflictPair models
- [x] CalendarService (actor) — EventKit fetch, conflict detection, free window identification
- [x] DateFormatting utilities (time, day, duration formatters)
- [x] MenuBarPopover — today's events, free windows, conflicts, Noosh's schedule
- [x] EventRow component
- [x] SettingsPlaceholderView — task directory path, calendar preferences
- [x] CalendarServiceTests — 5 tests, all passing
- [x] Build succeeds with ad-hoc signing (DEVELOPER_DIR workaround for xcode-select)

### Build command
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Briefing.xcodeproj -scheme Briefing -configuration Debug build
```

### Run the app
```bash
open ~/Library/Developer/Xcode/DerivedData/Briefing-gaslbouinicyljglrpcyijaecsgq/Build/Products/Debug/Briefing.app
```

### Key discoveries during Phase 1

- **`xcode-select` points to CLT, not Xcode.app.** Every `xcodebuild` call must be
  prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Without
  this, you get `error: tool 'xcodebuild' requires Xcode`.
- **Swift 6 strict concurrency breaks the build.** Foundation types like
  `ISO8601DateFormatter` are not `Sendable`, so static formatter properties fail.
  Solution: use `SWIFT_VERSION: "5.0"` (still compiles with the Swift 6.2 toolchain,
  just relaxes concurrency checking).
- **Entitlements file causes provisioning errors with ad-hoc signing.** Specifically,
  `keychain-access-groups` requires a real provisioning profile. The file exists on
  disk for future distribution signing but is NOT referenced in `project.yml` build
  settings. Calendar and Apple Events permissions work fine without it — macOS grants
  them at runtime based on Info.plist usage description strings.
- **`GENERATE_INFOPLIST_FILE: YES` needed for test target.** Without it, the test
  bundle fails to code sign.
- **xcodegen regenerates the entire `.xcodeproj`.** Run `xcodegen generate` after
  any change to `project.yml`. Never hand-edit the `.xcodeproj`.

### Files created

| File | Purpose |
|------|---------|
| `project.yml` | xcodegen spec — targets, signing, build settings |
| `Briefing/Info.plist` | LSUIElement=YES, privacy usage descriptions |
| `Briefing/Briefing.entitlements` | Calendars, Apple Events, Keychain, Network (not in build) |
| `Briefing/BriefingApp.swift` | @main entry, MenuBarExtra + Settings scenes |
| `Briefing/Models/CalendarEvent.swift` | CalendarEvent, CalendarOwner, FreeWindow, ConflictPair |
| `Briefing/Models/AppSettings.swift` | @Observable preferences with UserDefaults persistence |
| `Briefing/Services/CalendarService.swift` | EventKit actor: fetch, conflicts, free windows |
| `Briefing/Utilities/DateFormatting.swift` | Cached DateFormatter statics |
| `Briefing/Views/MenuBarPopover.swift` | Popover UI + EventRow component |
| `BriefingTests/CalendarServiceTests.swift` | 5 tests: owner classification, duration, formatting |

---

### Next
- [x] Phase 1: Skeleton + Calendar
- [x] Phase 2: Things 3 integration
- [x] Phase 3: Task file I/O + sync
- [x] Phase 4: Claude API + briefing generation
- [ ] Phase 5: Full window + PDF export
- [ ] Phase 6: Scheduling + notifications
- [ ] Phase 7: Polish

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                     UI Layer (SwiftUI)                │
│  MenuBarExtra ──► Popover ──► Full Window ──► PDF    │
│                    Settings Window                    │
└─────────────────────┬────────────────────────────────┘
                      │
┌─────────────────────▼────────────────────────────────┐
│              BriefingEngine (actor, orchestrator)      │
│  Gathers data in parallel, calls Claude, produces     │
│  Briefing model, triggers file updates                │
└──┬──────┬──────┬──────┬──────┬───────────────────────┘
   │      │      │      │      │
   ▼      ▼      ▼      ▼      ▼
Calendar Things3 TaskFile Claude  PDF
Service  Service Service  API    Export
   │      │      │       Service  Service
   ▼      ▼      ▼        │
EventKit Process  FileSystem  ▼
         (JXA)   (iCloud)  api.anthropic.com
```

**Stack:** Swift + SwiftUI. Native frameworks only (EventKit, Security, UserNotifications).
**macOS minimum:** 14 (Sonoma)
**Distribution:** Direct download (not Mac App Store — avoids sandbox restrictions for Things 3 automation)

---

## Project Structure

```
Briefing/
├── Briefing.xcodeproj
├── Briefing/
│   ├── BriefingApp.swift              # @main, MenuBarExtra + Window scenes
│   ├── Info.plist                     # LSUIElement=YES, privacy descriptions
│   ├── Briefing.entitlements          # Calendars, Apple Events, Keychain, Network
│   │
│   ├── Models/
│   │   ├── CalendarEvent.swift        # Event from EventKit with owner classification
│   │   ├── Task.swift                 # Task from Things 3 / todo.md
│   │   ├── TaskDiff.swift             # Sync diff between Things 3 and todo.md
│   │   ├── Briefing.swift             # Full briefing: timelines, priorities, analysis
│   │   └── AppSettings.swift          # @Observable user preferences
│   │
│   ├── Services/
│   │   ├── CalendarService.swift      # EventKit: fetch, conflict detect, free windows
│   │   ├── ThingsService.swift        # JXA via Process: read, complete, URL-scheme add
│   │   ├── TaskFileService.swift      # Read/write todo.md and todo-log.md
│   │   ├── TaskSyncService.swift      # Things 3 <-> todo.md diffing
│   │   ├── ClaudeAPIService.swift     # HTTP client for Anthropic Messages API
│   │   ├── AuthService.swift          # Protocol-based: APIKeyAuth + OAuthAuth
│   │   ├── KeychainService.swift      # Store/retrieve credentials from Keychain
│   │   ├── BriefingEngine.swift       # Actor: orchestrates data gathering + Claude call
│   │   ├── SchedulerService.swift     # Timer-based auto-run + UserNotifications
│   │   └── PDFExportService.swift     # NSPrintOperation wrapper
│   │
│   ├── Views/
│   │   ├── MenuBarPopover.swift       # Compact: today's events + top priorities
│   │   ├── BriefingWindow.swift       # Full window with toolbar (Print, Refresh)
│   │   ├── BriefingContentView.swift  # Rendered briefing (shared popover/window)
│   │   ├── CalendarTimelineView.swift # Day-by-day visual timeline
│   │   ├── TaskPriorityView.swift     # Must-do / should-do / waiting / stale
│   │   ├── SyncDiffView.swift         # Things 3 vs todo.md diff for approval
│   │   ├── SettingsView.swift         # Preferences: path, auth, schedule, calendars
│   │   └── Components/               # EventRow, TaskRow, ConflictBadge, etc.
│   │
│   ├── Utilities/
│   │   ├── MarkdownParser.swift       # Parse todo.md → [Task] with sections/projects
│   │   ├── MarkdownWriter.swift       # Serialize [Task] → todo.md format
│   │   └── DateFormatting.swift       # Shared formatters
│   │
│   └── Resources/
│       └── BriefingPrompt.txt         # Prompt template with {{PLACEHOLDER}} tokens
│
├── BriefingTests/
│   ├── MarkdownParserTests.swift
│   ├── MarkdownWriterTests.swift
│   ├── TaskSyncServiceTests.swift
│   └── CalendarServiceTests.swift
│
├── PROGRESS.md                        # This file
└── ENGINEERING_INVARIANTS.md
```

---

## Key Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Stack | Swift + SwiftUI | EventKit, Keychain, MenuBarExtra are native-only |
| Claude model | Sonnet 4.5 default (configurable) | Best quality/cost/speed for daily analysis (~$0.06/run) |
| Auth | API key primary, OAuth experimental | OAuth likely blocked for 3P apps |
| Distribution | Direct download | Avoids sandbox — needed for Things 3 Apple Events |
| PDF export | NSPrintOperation (system print dialog) | Zero custom PDF code; includes "Save as PDF" |
| macOS minimum | 14 Sonoma | MenuBarExtra .window style, modern EventKit API |
| Concurrency | async/await, BriefingEngine as actor | Thread-safe orchestration, parallel data fetching |

---

## Source Files to Port

### ical.py → CalendarService.swift
**Location:** `~/Library/Mobile Documents/com~apple~CloudDocs/To-Do Briefing/.task-system/ical.py`

Key Swift EventKit code (lines 44-125) that currently gets compiled on the fly:
- Uses `EKEventStore` with `requestFullAccessToEvents` (macOS 14+)
- Fetches events with `predicateForEvents(withStart:end:calendars:nil)`
- Formats: `h:mm a` time, groups by day, includes calendar name and source
- Handles all-day events, location, notes (truncated to 200 chars)

The native app will use this same EventKit logic directly — no compilation step needed.

Also has event creation (lines 127-199) via EventKit and CalDAV fallback (lines 250+).

### briefing.md → BriefingEngine.swift orchestration
**Location:** `~/Library/Mobile Documents/com~apple~CloudDocs/To-Do Briefing/.claude/commands/briefing.md`

Defines the workflow:
1. Pull calendar events (ical.py week + cache)
2. Read todo.md + recent todo-log.md
3. Sync Things 3 via JXA (`Application("Things 3")`)
4. Compare Things 3 vs todo.md, present diff for approval
5. Generate briefing: calendar timeline, task priorities, bottom line
6. Update todo-log.md with sync entry
7. Update timestamps in todo.md

### daily-briefing-prompt.md → BriefingPrompt.txt
**Location:** `~/Library/Mobile Documents/com~apple~CloudDocs/To-Do Briefing/.task-system/daily-briefing-prompt.md`

Steps for the prompt:
1. Read CLAUDE.md preferences
2. Check work calendar (Google Calendar MCP → will become EventKit)
3. Check personal calendar (iCloud via CalDAV → will become EventKit)
4. Merge calendars into single timeline
5. Sync Things 3 via JXA
6. Read todo.md
7. Reconcile and update todo.md
8. Append to todo-log.md
9. Produce briefing: calendar, top 3 priorities, overdue, waiting-on, capacity assessment

### CLAUDE.md → AppSettings.swift defaults
**Location:** `~/Library/Mobile Documents/com~apple~CloudDocs/To-Do Briefing/CLAUDE.md`

Key configuration:
- Task files location: `~/Library/Mobile Documents/com~apple~CloudDocs/To-Do Briefing/`
- Work calendar: mmaturo@experience.com
- Personal calendar: michaelammaturo@icloud.com
- **cal:Home = Noosh's calendar** → separate section, not Michael's timeline
- All other Apple calendars → merge into main timeline
- Things 3 is the mobile layer, sync bidirectionally
- Protect focus time, flag stale/overdue items, be direct

---

## todo.md Format (Parser Requirements)

The parser must handle:

### Sections (identified by emoji + heading)
- `## 🔴 Today` — highest priority active tasks
- `## 📋 Projects` — organized by project sub-headings (`### Project Name`)
- `## 🟠 Personal` — personal tasks
- `## 🟡 Anytime (Unassigned)` — backlog
- `## 🔵 Someday` — future/maybe items (also has project sub-headings)
- `## ✅ Recently Completed` — done items

### Task syntax
- `- [ ] Task description` — open task
- `- [x] Task description *(completed DATE)*` — completed task
- Inline metadata in italics: `*(due DATE)*, *(notes)*`
- Markdown links: `[text](url)`
- Project context: `*(proj: Project Name)*`

### Header
```
# Michael's Task System
> **Last synced from Things 3:** 2026-02-15 10:55 PM PT
> **Last AI review:** 2026-02-15 10:55 PM PT
```

### Preservation rules
- Unmodified sections must be written back verbatim
- Section order must be preserved
- Project sub-headings under Projects and Someday must be preserved
- Horizontal rules (`---`) separate sections

---

## Things 3 JXA Technical Notes

From the briefing command and log entries:
- **App name:** `"Things 3"` (with space) — NOT `"Things3"`
- **Read tasks:** `osascript -l JavaScript` with `Application("Things 3")`
- **Complete tasks:** Set `t.status = "completed"` via JXA
- **Create tasks:** URL scheme `things:///add?title=...&notes=...&list=today` (JXA make/push doesn't work)
- **Tasks created via URL scheme land in Inbox**
- **Ghost tasks:** Empty-name tasks exist — filter them out
- **Timeout:** 5-second timeout on JXA calls (Things 3 can hang) — historical; now 10s
- **Lists to pull:** Inbox, Today, Upcoming, Anytime, Someday
- **For each task:** name, project, due date, notes

---

## Calendar Rules (from CLAUDE.md)

- **Work calendar:** mmaturo@experience.com — all events go in main timeline
- **Personal calendars:** All Apple calendars EXCEPT cal:Home → main timeline
- **cal:Home = Noosh's calendar** → separate "Noosh's Schedule" section
- Free windows: minimum 45 minutes to be useful for deep work
- Don't schedule deep work in 30-minute gaps between meetings
- Flag scheduling conflicts
- Note travel/logistics implications

---

## Authentication Design

**Primary: Console API key**
- User pastes `sk-ant-api03-...` from console.anthropic.com
- Stored in macOS Keychain via Security framework
- ~$0.06-0.09 per briefing with Sonnet 4.5

**Secondary: OAuth (experimental toggle)**
- PKCE flow, browser redirect, token stored in Keychain
- Likely blocked for 3P apps — behind experimental toggle

```swift
protocol AuthProvider {
    func authHeader() async throws -> (name: String, value: String)
}

struct APIKeyAuth: AuthProvider {  // "x-api-key" header
    func authHeader() async throws -> (name: String, value: String) { ... }
}

struct OAuthAuth: AuthProvider {   // "Authorization: Bearer" header
    func authHeader() async throws -> (name: String, value: String) { ... }
}
```

---

## Build Phases Detail

### Phase 1: Skeleton + Calendar
1. Create Xcode project, Info.plist (LSUIElement=YES), entitlements
2. BriefingApp.swift with MenuBarExtra (.window style)
3. CalendarService.swift — port EventKit from ical.py lines 44-125
4. CalendarEvent model with CalendarOwner enum (michael/noosh/holiday)
5. MenuBarPopover with today's events
6. Conflict detection + free window identification (45+ min gaps)

### Phase 2: Things 3 Integration
1. Add Apple Events entitlement
2. ThingsService.swift — JXA via Process
3. Task model
4. Read from all lists, handle ghost tasks, 5-second timeout (historical — now 10s)

### Phase 3: Task File I/O + Sync
1. MarkdownParser — parse todo.md sections, projects, checkboxes, metadata
2. MarkdownWriter — serialize back preserving unmodified sections
3. TaskFileService — read/write from configurable iCloud Drive path
4. TaskSyncService — diff Things 3 vs todo.md
5. SyncDiffView — present diff for approval
6. Round-trip tests

### Phase 4: Claude API + Briefing Generation
1. KeychainService — store/retrieve API key
2. AuthService — AuthProvider protocol + APIKeyAuth
3. ClaudeAPIService — HTTP client for Messages API
4. BriefingPrompt.txt with placeholders
5. BriefingEngine actor — parallel data gathering, prompt assembly, Claude call
6. BriefingContentView — render Markdown
7. SettingsView — API key, task directory, calendar filtering

### Phase 5: Full Window + PDF
1. Window scene (id: "briefing-window")
2. BriefingWindow with toolbar
3. PDF via NSPrintOperation

### Phase 6: Scheduling + Notifications + OAuth
1. SchedulerService — Timer + wake handling
2. UserNotifications
3. OAuthAuth implementation

### Phase 7: Polish
1. Error handling, first-run onboarding
2. Noosh's schedule as separate section
3. Visual conflict/free-window indicators

---

## Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| OAuth blocked for 3P apps | High | API key primary; OAuth behind toggle |
| Things 3 JXA quirks | Medium | Hard-code "Things 3"; filter ghosts; timeout |
| Apple Events permission | Medium | Distribute outside App Store |
| Markdown parser fragility | Medium | Test against real snapshots; preserve verbatim |
| iCloud Drive sync lag | Low | Show "last synced" timestamp; NSFileCoordinator |

---

## Environment Notes

- Swift 6.2.3 (swiftlang-6.2.3.3.21)
- Target: arm64-apple-macosx15.0
- Xcode CLT at /Library/Developer/CommandLineTools
- No xcodegen available — will create project manually or use `swift package init`
- Full Xcode may be needed for proper .app bundle with entitlements
