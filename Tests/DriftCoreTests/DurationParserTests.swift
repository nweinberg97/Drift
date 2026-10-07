import XCTest
@testable import DriftCore

final class DurationParserTests: XCTestCase {
    private func seconds(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> TimeInterval? {
        DurationParser.parse(s)?.seconds
    }

    func testBareNumberIsMinutes() {
        XCTAssertEqual(seconds("25"), 1_500)
        XCTAssertEqual(seconds("5"), 300)
        XCTAssertEqual(seconds("1.5"), 90)
    }

    func testClockNotation() {
        XCTAssertEqual(seconds("1:30"), 5_400)
        XCTAssertEqual(seconds("0:45"), 2_700)
        XCTAssertEqual(seconds("1:30:15"), 5_415)
        XCTAssertNil(seconds("1:75"))
    }

    func testUnits() {
        XCTAssertEqual(seconds("5s"), 5)
        XCTAssertEqual(seconds("10s"), 10)
        XCTAssertEqual(seconds("90s"), 90)
        XCTAssertEqual(seconds("90 seconds"), 90)
        XCTAssertEqual(seconds("25m"), 1_500)
        XCTAssertEqual(seconds("25 min"), 1_500)
        XCTAssertEqual(seconds("25 minutes"), 1_500)
        XCTAssertEqual(seconds("1h"), 3_600)
        XCTAssertEqual(seconds("1 hour"), 3_600)
        XCTAssertEqual(seconds("12h"), 43_200)
        XCTAssertEqual(seconds("24h"), 86_400)
        XCTAssertEqual(seconds("36h"), 129_600)
        XCTAssertEqual(seconds("2d"), 172_800)
        XCTAssertEqual(seconds("2 days"), 172_800)
        XCTAssertEqual(seconds("3d"), 259_200)
        XCTAssertEqual(seconds("1.5h"), 5_400)
    }

    func testCompoundDurations() {
        XCTAssertEqual(seconds("2h 15m"), 8_100)
        XCTAssertEqual(seconds("2h15m"), 8_100)
        XCTAssertEqual(seconds("1h 30m"), 5_400)
        XCTAssertEqual(seconds("1 hour 30 minutes"), 5_400)
        XCTAssertEqual(seconds("2h 30m"), 9_000)
        XCTAssertEqual(seconds("1h 30"), 5_400)
        XCTAssertEqual(seconds("1d 2h"), 93_600)
    }

    func testSpokenForms() {
        XCTAssertEqual(seconds("an hour"), 3_600)
        XCTAssertEqual(seconds("half an hour"), 1_800)
        XCTAssertEqual(seconds("an hour and a half"), 5_400)
        XCTAssertEqual(seconds("1 and a half hours"), 5_400)
        XCTAssertEqual(seconds("twenty five minutes"), 1_500)
        XCTAssertEqual(seconds("twenty-five minutes"), 1_500)
        XCTAssertEqual(seconds("ten minutes"), 600)
        XCTAssertEqual(seconds("a 10-minute timer"), 600)
    }

    func testLabels() {
        XCTAssertEqual(DurationParser.parse("45m writing"), ParsedDuration(seconds: 2_700, label: "Writing"))
        XCTAssertEqual(DurationParser.parse("45 minutes writing"), ParsedDuration(seconds: 2_700, label: "Writing"))
        XCTAssertEqual(DurationParser.parse("writing 45m"), ParsedDuration(seconds: 2_700, label: "Writing"))
        XCTAssertEqual(DurationParser.parse("45m focus")?.label, "Focus")
        XCTAssertEqual(DurationParser.parse("25 call mom")?.label, "Call mom")
        XCTAssertEqual(DurationParser.parse("45m chapter 3")?.label, "Chapter 3")
        XCTAssertEqual(DurationParser.parse("start a timer for 1 hour called writing"),
                       ParsedDuration(seconds: 3_600, label: "Writing"))
        XCTAssertEqual(DurationParser.parse("start a 10 minute timer called break"),
                       ParsedDuration(seconds: 600, label: "Break"))
        XCTAssertNil(DurationParser.parse("start a 25 minute timer.")?.label)
        XCTAssertNil(DurationParser.parse("25m")?.label)
    }

    func testRejectsNonsense() {
        XCTAssertNil(seconds(""))
        XCTAssertNil(seconds("writing"))
        XCTAssertNil(seconds("0"))
        XCTAssertNil(seconds("0s"))
        XCTAssertNil(seconds("inf"))
        XCTAssertNil(seconds("a timer"))
        XCTAssertNil(seconds("9999d"))
    }
}
