# Briefing.app — TODO

## Performance
- [ ] Reduce first calendar load-time somehow...it's at about 3-4 seconds right now
- [ ] Cache calendar events so the popover can show stale data immediately while refreshing in the background

## UI / Window Management
- [ ] Settings window opens behind other apps if not using `activate()` — but `activate()` blanks the menu bar since LSUIElement apps have no main menu. Need a floating panel approach that doesn't trigger Keychain access prompts.
- [ ] When Briefing is the active app (after opening Settings), the system menu bar goes blank — user has to click another app to get back to the Briefing menu bar icon. LSUIElement apps don't have a main menu.
