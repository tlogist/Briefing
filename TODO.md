# Briefing.app — TODO

## Performance
- [ ] Reduce first calendar load-time somehow...it's at about 3-4 seconds right now
- [ ] Cache calendar events so the popover can show stale data immediately while refreshing in the background

## UI / Window Management
- [x] Settings window: now uses NSPanel floating window (no app activation, no menu bar blanking)
- [ ] Switch from UserDefaults to real Keychain for API key storage once app is properly code-signed for distribution
