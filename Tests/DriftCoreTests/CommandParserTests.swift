import XCTest
@testable import DriftCore

final class CommandParserTests: XCTestCase {
    func testStartCommands() {
        XCTAssertEqual(CommandParser.parse("25"), .start(seconds: 1_500, name: nil))
        XCTAssertEqual(CommandParser.parse("Start a 25 minute timer."), .start(seconds: 1_500, name: nil))
        XCTAssertEqual(CommandParser.parse("Start a timer for 90 minutes."), .start(seconds: 5_400, name: nil))
        XCTAssertEqual(CommandParser.parse("Start a 10 minute timer called break."), .start(seconds: 600, name: "Break"))
        XCTAssertEqual(CommandParser.parse("Hey Drift, start a 25 minute timer"), .start(seconds: 1_500, name: nil))
        XCTAssertEqual(CommandParser.parse("Start a timer for 1 hour called writing"), .start(seconds: 3_600, name: "Writing"))
        XCTAssertEqual(CommandParser.parse("45m writing"), .start(seconds: 2_700, name: "Writing"))
        XCTAssertEqual(CommandParser.parse("1:30"), .start(seconds: 5_400, name: nil))
        XCTAssertEqual(CommandParser.parse("set a timer for 36 hours"), .start(seconds: 129_600, name: nil))
    }

    func testPauseResumeCancel() {
        XCTAssertEqual(CommandParser.parse("Pause my focus timer."), .pause(target: "focus"))
        XCTAssertEqual(CommandParser.parse("pause"), .pause(target: nil))
        XCTAssertEqual(CommandParser.parse("resume"), .resume(target: nil))
        XCTAssertEqual(CommandParser.parse("continue laundry"), .resume(target: "laundry"))
        XCTAssertEqual(CommandParser.parse("Cancel the laundry timer."), .cancel(target: "laundry"))
        XCTAssertEqual(CommandParser.parse("stop"), .cancel(target: nil))
        XCTAssertEqual(CommandParser.parse("remove the break timer"), .cancel(target: "break"))
    }

    func testAdjust() {
        XCTAssertEqual(CommandParser.parse("Add 5 minutes."), .adjust(delta: 300, target: nil))
        XCTAssertEqual(CommandParser.parse("add 10 minutes to the laundry timer"), .adjust(delta: 600, target: "laundry"))
        XCTAssertEqual(CommandParser.parse("take 5 minutes off"), .adjust(delta: -300, target: nil))
        XCTAssertEqual(CommandParser.parse("subtract 2m from focus"), .adjust(delta: -120, target: "focus"))
        XCTAssertEqual(CommandParser.parse("remove 5 minutes"), .adjust(delta: -300, target: nil))
    }

    func testShowHide() {
        XCTAssertEqual(CommandParser.parse("Show my timers."), .show)
        XCTAssertEqual(CommandParser.parse("how much time is left"), .show)
        XCTAssertEqual(CommandParser.parse("hide"), .hide)
    }

    func testPomodoro() {
        XCTAssertEqual(CommandParser.parse("pomodoro"), .pomodoro(focus: 1_500, rest: 300))
        XCTAssertEqual(CommandParser.parse("start a pomodoro"), .pomodoro(focus: 1_500, rest: 300))
        XCTAssertEqual(CommandParser.parse("50/10"), .pomodoro(focus: 3_000, rest: 600))
        XCTAssertEqual(CommandParser.parse("pomodoro 50/10"), .pomodoro(focus: 3_000, rest: 600))
    }

    func testGracefulFailure() {
        XCTAssertNil(CommandParser.parse(""))
        XCTAssertNil(CommandParser.parse("hello there"))
        XCTAssertNil(CommandParser.parse("add some time"))
    }

    func testMatcher() {
        let timers = [
            DriftTimer(name: "Focus", duration: 60),
            DriftTimer(name: "Laundry", duration: 60),
            DriftTimer(duration: 60),
        ]
        XCTAssertEqual(TimerMatcher.match("laundry", in: timers)?.name, "Laundry")
        XCTAssertEqual(TimerMatcher.match("foc", in: timers)?.name, "Focus")
        XCTAssertNil(TimerMatcher.match("cooking", in: timers))
    }
}
