import XCTest
@testable import SorcererCore

final class DueLineTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    lazy var today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16))!

    func parse(_ line: String) -> DueLine.Parsed? {
        DueLine.parse(line: line, today: today, calendar: calendar)
    }

    func testCanonicalForms() {
        XCTAssertEqual(parse("Due: 10-20-26")?.date, TaskDate(year: 2026, month: 10, day: 20))
        XCTAssertEqual(parse("Due: 10-20-26 5:30 PM")?.date, TaskDate(year: 2026, month: 10, day: 20, hour: 17, minute: 30))
        XCTAssertEqual(parse("Due: 10-20-26")?.hadYear, true)
    }

    func testLenientForms() {
        XCTAssertEqual(parse("due 10/20")?.date, TaskDate(year: 2026, month: 10, day: 20))
        XCTAssertEqual(parse("Due: 1-5-2027 9am")?.date, TaskDate(year: 2027, month: 1, day: 5, hour: 9, minute: 0))
        XCTAssertEqual(parse("📅 Due: 10.20 17:00")?.date, TaskDate(year: 2026, month: 10, day: 20, hour: 17, minute: 0))
        XCTAssertEqual(parse("DUE: 10-20 12 a.m.")?.date, TaskDate(year: 2026, month: 10, day: 20, hour: 0, minute: 0))
        XCTAssertEqual(parse("Due: 10-20 12pm")?.date.hour, 12)
        XCTAssertEqual(parse("Due: 10-20 at 5:05p")?.date, TaskDate(year: 2026, month: 10, day: 20, hour: 17, minute: 5))
    }

    func testYearInference() {
        // More than 60 days in the past → next year.
        XCTAssertEqual(parse("Due: 01-05")?.date.year, 2027)
        XCTAssertEqual(parse("Due: 01-05")?.hadYear, false)
        // Recently passed → this year (an overdue task, not one a year away).
        XCTAssertEqual(parse("Due: 09-01")?.date.year, 2026)
    }

    func testRejectsNonDueLines() {
        XCTAssertNil(parse("Buy milk"))
        XCTAssertNil(parse("Due: 13-01-26"))
        XCTAssertNil(parse("Due: 02-30-26"))
        XCTAssertNil(parse("Due: 10-20-26 25:00"))
        XCTAssertNil(parse("Due tomorrow"))
        XCTAssertNil(parse("Due: 10-20 and other text"))
    }

    func testFormat() {
        XCTAssertEqual(DueLine.format(TaskDate(year: 2026, month: 3, day: 7)), "Due: 03-07-26")
        XCTAssertEqual(DueLine.format(TaskDate(year: 2026, month: 3, day: 7, hour: 0, minute: 15)), "Due: 03-07-26 12:15 AM")
        XCTAssertEqual(DueLine.format(TaskDate(year: 2026, month: 3, day: 7, hour: 17, minute: 30)), "Due: 03-07-26 5:30 PM")
    }

    func testApply() {
        let d = TaskDate(year: 2026, month: 10, day: 20)
        XCTAssertEqual(DueLine.apply(d, to: "", today: today, calendar: calendar), "Due: 10-20-26")
        XCTAssertEqual(DueLine.apply(d, to: "Bring receipts", today: today, calendar: calendar), "Due: 10-20-26\nBring receipts")
        XCTAssertEqual(DueLine.apply(d, to: "Due: 10-01-26\nBring receipts", today: today, calendar: calendar),
                       "Due: 10-20-26\nBring receipts")
        XCTAssertEqual(DueLine.apply(nil, to: "Due: 10-01-26\n\nBring receipts", today: today, calendar: calendar),
                       "Bring receipts")
        // Same date written differently, with a year: left exactly as typed.
        XCTAssertEqual(DueLine.apply(d, to: "due 10/20/2026\nx", today: today, calendar: calendar), "due 10/20/2026\nx")
        // Year-less line gets the year filled in so it can't drift to a different year later.
        XCTAssertEqual(DueLine.apply(d, to: "due 10/20\nx", today: today, calendar: calendar), "Due: 10-20-26\nx")
    }
}
