import XCTest
@testable import Briefing

final class CalendarServiceTests: XCTestCase {

    // MARK: - CalendarOwner Classification

    func testHomeCalendarIsFamily() {
        XCTAssertEqual(CalendarOwner.classify(calendarTitle: "Home"), .family)
    }

    func testHomeCalendarCaseInsensitive() {
        XCTAssertEqual(CalendarOwner.classify(calendarTitle: "home"), .family)
        XCTAssertEqual(CalendarOwner.classify(calendarTitle: "HOME"), .family)
    }

    func testOtherCalendarsAreMichael() {
        XCTAssertEqual(CalendarOwner.classify(calendarTitle: "Primary"), .michael)
        XCTAssertEqual(CalendarOwner.classify(calendarTitle: "Personal"), .michael)
        XCTAssertEqual(CalendarOwner.classify(calendarTitle: "Shushanville"), .michael)
        XCTAssertEqual(CalendarOwner.classify(calendarTitle: "All-Day Events"), .michael)
        XCTAssertEqual(CalendarOwner.classify(calendarTitle: "Calendar"), .michael)
    }

    // MARK: - Free Window Detection

    func testFreeWindowDuration() {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let end = cal.date(bySettingHour: 11, minute: 30, second: 0, of: Date())!
        let window = FreeWindow(startDate: start, endDate: end)
        XCTAssertEqual(window.durationMinutes, 90)
    }

    // MARK: - Date Formatting

    func testDurationFormatting() {
        XCTAssertEqual(DateFormatting.duration(minutes: 90), "1h 30m")
        XCTAssertEqual(DateFormatting.duration(minutes: 60), "1h")
        XCTAssertEqual(DateFormatting.duration(minutes: 45), "45m")
        XCTAssertEqual(DateFormatting.duration(minutes: 150), "2h 30m")
    }
}
