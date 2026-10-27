import XCTest
@testable import DriftCore

final class LauncherTextTests: XCTestCase {
    private func highlighted(_ text: String) -> [String] {
        LauncherText.timeRanges(in: text).map { String(text[$0]) }
    }

    func testFindsTheTime() {
        XCTAssertEqual(highlighted("Write intro 45m"), ["45m"])
        XCTAssertEqual(highlighted("45 minutes for email"), ["45 minutes"])
        XCTAssertEqual(highlighted("Reading for an hour and a half"), ["an hour and a half"])
        XCTAssertEqual(highlighted("deep work 1:30"), ["1:30"])
        XCTAssertEqual(highlighted("twenty five minutes for reading"), ["twenty five minutes"])
        XCTAssertEqual(highlighted("25"), ["25"])
        XCTAssertEqual(highlighted("Write intro"), [])
    }

    func testTaskOnly() {
        XCTAssertEqual(LauncherText.task(from: "  write intro "), "Write intro")
        XCTAssertNil(LauncherText.task(from: "25"))
        XCTAssertNil(LauncherText.task(from: "   "))
    }

    func testTasksThatStartWithVerbs() {
        XCTAssertEqual(CommandParser.parse("check email 25m"), .start(seconds: 1_500, name: "Check email"))
        XCTAssertNil(CommandParser.parse("check email"))
        XCTAssertNil(CommandParser.parse("open the mail"))
        XCTAssertEqual(CommandParser.parse("show my timers"), .show)
        XCTAssertEqual(CommandParser.parse("close"), .hide)
        XCTAssertEqual(CommandParser.parse("pause laundry"), .pause(target: "laundry"))
        XCTAssertEqual(CommandParser.parse("add 5 minutes"), .adjust(delta: 300, target: nil))
    }
}
