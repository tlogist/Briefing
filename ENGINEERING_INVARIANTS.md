# Engineering Invariants — Briefing.app

> Hard constraints and non-obvious rules for this project.
> Any agent working on this codebase must read and follow these.

---

## Things 3 Integration

- **App name is `"Things 3"` (with a space).** Not "Things3". JXA calls will fail silently
  with the wrong name.
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

## todo.md Format

- **Section order matters.** The parser must preserve the exact section order from the
  original file. Sections are identified by emoji prefixes (🔴, 📋, 🟠, 🟡, 🔵, ✅).
- **Unmodified sections must round-trip verbatim.** If a section wasn't touched during
  sync, write it back character-for-character. This prevents spurious diffs in iCloud Drive.
- **Project sub-headings (### level) exist** under both `## 📋 Projects` and `## 🔵 Someday`.
  The parser must handle nested project → task relationships.
- **Horizontal rules (`---`) separate sections.** They are structural, not decorative.

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

## Claude API

- **Default model: claude-sonnet-4-5-20250929.** Configurable in settings.
- **API key stored in macOS Keychain** via Security framework. Never write to disk or UserDefaults.
- **Cost per briefing: ~$0.06-0.09.** Acceptable for daily use.
