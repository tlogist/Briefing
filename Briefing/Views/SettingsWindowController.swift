import AppKit
import SwiftUI

// A floating panel for Settings that doesn't activate the app.
// This solves two LSUIElement problems:
// 1. NSApp.activate() blanks the system menu bar (no main menu)
// 2. Without activation, the window hides behind other apps
//
// NSPanel with .nonActivatingPanel stays on top without taking
// over the menu bar, and .utilityWindow gives it the right appearance.
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?

    private init() {}

    func show(settings: AppSettings) {
        if let existing = panel, existing.isVisible {
            // Already open — just bring to front
            existing.orderFrontRegardless()
            return
        }

        let settingsView = SettingsView(settings: settings)
        let hostingView = NSHostingView(rootView: AnyView(settingsView))
        self.hostingView = hostingView

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 350),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Briefing Settings"
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
        hostingView = nil
    }
}
