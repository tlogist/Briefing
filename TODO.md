# Briefing.app — TODO

## Performance
- [x] Reduce first calendar load-time: stale-while-revalidate cache shows data instantly, refresh in background
- [x] Cache calendar events so the popover can show stale data immediately while refreshing in the background

## UI / Window Management
- [x] Settings window: now uses NSPanel floating window (no app activation, no menu bar blanking)
- [ ] Full briefing window (separate from popover) with toolbar (Print, Refresh)
- [ ] "Open Full Briefing" button in popover that opens the full window
- [ ] First-run onboarding flow (pick task directory, grant calendar access, enter API key)

## Authentication
- [ ] Switch from UserDefaults to real Keychain for API key storage once app is properly code-signed for distribution
- [ ] OAuth support (experimental): PKCE flow for "Sign in with Claude" as alternative to API key

## Scheduling & Notifications
- [ ] Timer-based auto-run: generate briefing on a configurable schedule
- [ ] macOS notification when a scheduled briefing is ready
- [ ] Handle wake-from-sleep (re-trigger if scheduled time was missed)

## iCloud Drive Sync
- [x] Cache personal calendar events (iCloud, Bendicoot, Planning Board) to iCloud Drive for work Mac
- [x] Cache Things 3 tasks to iCloud Drive for work Mac fallback
- [ ] Share generated briefings (today + week) via iCloud Drive so they don't need to be regenerated on each computer
- [ ] Get Things 3 automation working on work Mac under Tahoe (JXA fails with -1701; may need new Apple Events permissions model)

## Briefing Generation
- [ ] Fix Weekly briefing — currently generates today's briefing instead of a proper week view
- [ ] Add "Tomorrow" button to generate a briefing for the next day

## Polish
- [ ] Graceful error handling: calendar denied, Things 3 not running, network errors, missing config path
- [ ] Visual conflict/free-window indicators in calendar timeline
- [ ] Noosh's schedule as a clearly separated section
- [ ] Test on second Mac (same iCloud Drive path, verify same briefing)
