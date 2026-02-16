# Briefing.app — TODO

## Performance
- [x] Reduce first calendar load-time: stale-while-revalidate cache shows data instantly, refresh in background
- [x] Cache calendar events so the popover can show stale data immediately while refreshing in the background

## UI / Window Management
- [x] Settings window: now uses NSPanel floating window (no app activation, no menu bar blanking)
- [ ] Switch from UserDefaults to real Keychain for API key storage once app is properly code-signed for distribution
