import Foundation
import AppKit
import UserNotifications

// In-process scheduler for automated briefing generation.
// Uses Timer on the main RunLoop rather than launchd/cron — this works because
// the app is a persistent menu bar app (LSUIElement=YES) that stays running.
// Handles two independent schedules (daily + weekly), wake-from-sleep recovery,
// and posts macOS notifications when a briefing is ready.
@Observable
final class BriefingScheduler {
    // Exposed for UI display (e.g., "Next daily briefing at 6:00 AM")
    var nextDailyFireDate: Date?
    var nextWeeklyFireDate: Date?

    private let settings: AppSettings
    private let calendarService: CalendarService
    private let thingsService: ThingsService

    private var dailyTimer: Timer?
    private var weeklyTimer: Timer?

    // Track when the Mac went to sleep so we can detect missed schedules on wake
    private var sleepDate: Date?
    private var sleepObserver: Any?
    private var wakeObserver: Any?

    init(settings: AppSettings, calendarService: CalendarService, thingsService: ThingsService) {
        self.settings = settings
        self.calendarService = calendarService
        self.thingsService = thingsService

        requestNotificationPermission()
        setupSleepWakeObservers()
    }

    // MARK: - Public API

    /// Call once at app launch to arm both timers based on current settings.
    func start() {
        rescheduleDaily()
        rescheduleWeekly()
    }

    /// Cancel and recreate the daily timer from current settings.
    /// Call this whenever dailyScheduleEnabled, dailyScheduleHour, or
    /// dailyScheduleMinute change.
    func rescheduleDaily() {
        dailyTimer?.invalidate()
        dailyTimer = nil
        nextDailyFireDate = nil

        guard settings.dailyScheduleEnabled else { return }

        guard let fireDate = nextOccurrence(
            hour: settings.dailyScheduleHour,
            minute: settings.dailyScheduleMinute
        ) else { return }

        nextDailyFireDate = fireDate

        // Block-based Timer avoids requiring NSObject inheritance
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            self?.handleDailyFire()
        }
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
    }

    /// Cancel and recreate the weekly timer from current settings.
    /// Call this whenever weeklyScheduleEnabled, weeklyScheduleDay,
    /// weeklyScheduleHour, or weeklyScheduleMinute change.
    func rescheduleWeekly() {
        weeklyTimer?.invalidate()
        weeklyTimer = nil
        nextWeeklyFireDate = nil

        guard settings.weeklyScheduleEnabled else { return }

        guard let fireDate = nextOccurrence(
            hour: settings.weeklyScheduleHour,
            minute: settings.weeklyScheduleMinute,
            weekday: settings.weeklyScheduleDay
        ) else { return }

        nextWeeklyFireDate = fireDate

        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            self?.handleWeeklyFire()
        }
        RunLoop.main.add(timer, forMode: .common)
        weeklyTimer = timer
    }

    // MARK: - Timer Callbacks

    private func handleDailyFire() {
        generateAndNotify(scope: .today, label: "daily")
        // Arm the next occurrence (tomorrow at the same time)
        rescheduleDaily()
    }

    private func handleWeeklyFire() {
        generateAndNotify(scope: .week, label: "weekly")
        // Arm the next occurrence (next week on the same day/time)
        rescheduleWeekly()
    }

    // MARK: - Briefing Generation

    /// Build a fresh BriefingEngine, generate the briefing, save to iCloud Drive,
    /// and post a macOS notification. The popover will pick up the new briefing
    /// from disk on its next loadAll() — no in-memory state is touched here.
    private func generateAndNotify(scope: BriefingScope, label: String) {
        let engine = BriefingEngine(
            calendarService: calendarService,
            thingsService: thingsService,
            taskFileService: TaskFileService(settings: settings),
            settings: settings
        )
        let directoryPath = settings.taskDirectoryPath

        Task {
            do {
                // No UI status tracking needed — pass a no-op callback
                let result = try await engine.generateBriefing(scope: scope) { _ in }
                BriefingCache.save(result, for: scope, directoryPath: directoryPath)
                await postNotification(label: label)
            } catch {
                print("BriefingScheduler: \(label) generation failed: \(error)")
            }
        }
    }

    // MARK: - Next Fire Date Computation

    /// Compute the next calendar date matching the given hour/minute (and
    /// optionally weekday). Uses Calendar.nextDate which handles DST transitions
    /// and day-of-week matching correctly.
    private func nextOccurrence(hour: Int, minute: Int, weekday: Int? = nil) -> Date? {
        let calendar = Calendar.current
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        if let weekday {
            components.weekday = weekday  // 1=Sunday, 7=Saturday
        }
        return calendar.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime)
    }

    // MARK: - Sleep/Wake Handling

    private func setupSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sleepDate = Date()
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    /// On wake, check if either schedule's fire date fell inside the sleep window.
    /// If so, fire immediately — the user expects their briefing to be ready
    /// even if the Mac was asleep at the scheduled time.
    private func handleWake() {
        guard let sleepDate else { return }
        self.sleepDate = nil

        let now = Date()

        // Daily: was the fire date between sleep and now?
        if settings.dailyScheduleEnabled,
           let nextDaily = nextDailyFireDate,
           nextDaily >= sleepDate && nextDaily <= now {
            generateAndNotify(scope: .today, label: "daily")
        }

        // Weekly: same check
        if settings.weeklyScheduleEnabled,
           let nextWeekly = nextWeeklyFireDate,
           nextWeekly >= sleepDate && nextWeekly <= now {
            generateAndNotify(scope: .week, label: "weekly")
        }

        // Timers that fired during sleep delivered into the void — reset them
        rescheduleDaily()
        rescheduleWeekly()
    }

    // MARK: - macOS Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, error in
            if let error {
                print("BriefingScheduler: notification permission error: \(error)")
            }
        }
    }

    private func postNotification(label: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Briefing Ready"
        content.body = "Your \(label) briefing has been generated."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "briefing-\(label)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // deliver immediately
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    deinit {
        dailyTimer?.invalidate()
        weeklyTimer?.invalidate()
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
