import XCTest
@testable import DriftCore

final class DriftTimerTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testAccuracyIsTimestampBased() {
        let durations: [TimeInterval] = [5, 1_500, 5_400, 86_400, 129_600]
        for duration in durations {
            var timer = DriftTimer(duration: duration)
            timer.start(at: t0)
            XCTAssertEqual(timer.remaining(at: t0), duration)
            // Simulate a long sleep: no ticks happen, yet remaining is exact.
            XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(duration / 2)), duration / 2, accuracy: 0.0001)
            XCTAssertFalse(timer.shouldFinish(at: t0.addingTimeInterval(duration - 0.01)))
            XCTAssertTrue(timer.shouldFinish(at: t0.addingTimeInterval(duration)))
        }
    }

    func testPauseResume() {
        var timer = DriftTimer(duration: 600)
        timer.start(at: t0)
        timer.pause(at: t0.addingTimeInterval(100))
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(10_000)), 500)
        timer.start(at: t0.addingTimeInterval(200))
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(300)), 400, accuracy: 0.0001)
    }

    func testAdjustRunning() {
        var timer = DriftTimer(duration: 600)
        timer.start(at: t0)
        XCTAssertTrue(timer.adjust(by: 300, at: t0))
        XCTAssertEqual(timer.remaining(at: t0), 900)
        XCTAssertTrue(timer.adjust(by: -300, at: t0))
        XCTAssertEqual(timer.remaining(at: t0), 600)
        // Can't remove more time than is left.
        XCTAssertFalse(timer.adjust(by: -600, at: t0))
        XCTAssertEqual(timer.remaining(at: t0), 600)
    }

    func testAdjustFinishedSnoozes() {
        var timer = DriftTimer(duration: 60)
        timer.start(at: t0)
        timer.finish(at: t0.addingTimeInterval(61))
        XCTAssertTrue(timer.isFinished)
        XCTAssertEqual(timer.finishedAt, t0.addingTimeInterval(60))
        XCTAssertTrue(timer.adjust(by: 300, at: t0.addingTimeInterval(100)))
        XCTAssertTrue(timer.isRunning)
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(100)), 300)
    }

    func testSetRemainingKeepsPaused() {
        var timer = DriftTimer(duration: 600)
        timer.start(at: t0)
        timer.pause(at: t0)
        timer.setRemaining(120, at: t0)
        XCTAssertTrue(timer.isPaused)
        XCTAssertEqual(timer.remaining(at: t0), 120)
    }

    func testPomodoroAdvances() {
        var timer = DriftTimer(duration: 1_500, pomodoro: PomodoroCycle())
        timer.start(at: t0)
        XCTAssertEqual(timer.displayName, "Focus")
        timer.advancePomodoro(from: t0.addingTimeInterval(1_500))
        XCTAssertEqual(timer.displayName, "Break")
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(1_500)), 300)
        timer.advancePomodoro(from: t0.addingTimeInterval(1_800))
        XCTAssertEqual(timer.displayName, "Focus")
        XCTAssertEqual(timer.pomodoro?.round, 2)
    }

    func testCodableRoundTrip() throws {
        var timer = DriftTimer(name: "Laundry", duration: 2_400)
        timer.start(at: t0)
        let data = try JSONEncoder().encode([timer])
        let decoded = try JSONDecoder().decode([DriftTimer].self, from: data)
        XCTAssertEqual(decoded, [timer])
    }
}

final class TimeFormatterTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(TimeFormatter.clock(1_500), "25:00")
        XCTAssertEqual(TimeFormatter.clock(1_499.2), "25:00")
        XCTAssertEqual(TimeFormatter.clock(452), "7:32")
        XCTAssertEqual(TimeFormatter.clock(5), "0:05")
        XCTAssertEqual(TimeFormatter.clock(0), "0:00")
        XCTAssertEqual(TimeFormatter.clock(6_138), "1:42:18")
        XCTAssertEqual(TimeFormatter.clock(98_040), "27h 14m")
        XCTAssertEqual(TimeFormatter.clock(3 * 86_400 + 6 * 3_600), "3d 6h")
    }

    func testCompactAndSpoken() {
        XCTAssertEqual(TimeFormatter.compact(1_500), "25m")
        XCTAssertEqual(TimeFormatter.compact(5_400), "1h 30m")
        XCTAssertEqual(TimeFormatter.compact(90), "1m 30s")
        XCTAssertEqual(TimeFormatter.spoken(1_500), "25 minutes")
        XCTAssertEqual(TimeFormatter.spoken(3_660), "1 hour 1 minute")
    }
}
