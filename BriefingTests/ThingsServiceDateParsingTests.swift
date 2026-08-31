import XCTest
@testable import Briefing

final class ThingsServiceDateParsingTests: XCTestCase {

    // MARK: - JXA Date Parsing

    // JXA's toISOString() always emits fractional seconds. A default
    // ISO8601DateFormatter rejects that shape, which silently nil'd every
    // JXA-sourced date (due/scheduled/creation/modification) until 2026-08-31.
    func testParsesFractionalSecondsDate() {
        let date = ThingsService.parseJXADate("2026-09-11T04:00:00.000Z")
        XCTAssertNotNil(date)
        XCTAssertEqual(date?.timeIntervalSince1970, 1_789_099_200)
    }

    func testParsesPlainInternetDate() {
        XCTAssertNotNil(ThingsService.parseJXADate("2026-09-11T04:00:00Z"))
    }

    func testRejectsNonDateString() {
        XCTAssertNil(ThingsService.parseJXADate("not a date"))
    }
}
