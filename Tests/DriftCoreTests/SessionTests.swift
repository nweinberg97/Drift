import XCTest
@testable import DriftCore

final class SessionTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        return c
    }

    /// Monday, 26 Oct 2026, 1:00 PM.
    private var monday1pm: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 13, minute: 0))!
    }

    private func parse(_ s: String, saved: @escaping (String) -> SessionParser.Saved? = { _ in nil }) -> SessionSpec? {
        SessionParser.parse(s, now: monday1pm, calendar: calendar, saved: saved)
    }

    func testTitledList() throws {
        let s = try XCTUnwrap(parse("Morning startup: inbox 10m, plan the day 10m, review calendar 5m"))
        XCTAssertEqual(s.name, "Morning startup")
        XCTAssertEqual(s.steps.map(\.name), ["Inbox", "Plan the day", "Review calendar"])
        XCTAssertEqual(s.steps.map(\.seconds), [600, 600, 300])
        XCTAssertNil(s.schedule)
    }

    func testPlainListNamesItself() throws {
        let s = try XCTUnwrap(parse("10m writing, 20m editing, 30 min reading"))
        XCTAssertEqual(s.steps.map(\.name), ["Writing", "Editing", "Reading"])
        XCTAssertEqual(s.total, 3_600)
        XCTAssertEqual(s.name, "Writing, Editing, Reading")
        XCTAssertEqual(try XCTUnwrap(parse("inbox 5m, slack 5m, calendar 5m, standup 5m")).name, "Inbox, Slack +2 more")
    }

    func testOnePerLineAndThen() throws {
        let s = try XCTUnwrap(parse("inbox 10m\nplan the day 10m then standup prep 5m"))
        XCTAssertEqual(s.steps.count, 3)
    }

    func testStartTimePlansIt() throws {
        let s = try XCTUnwrap(parse("10m writing, 20m editing, 30m reading, starting at 2pm today"))
        let plan = try XCTUnwrap(s.schedule)
        XCTAssertEqual(plan.startMinute, 14 * 60)
        XCTAssertEqual(plan.duration, 3_600)
        XCTAssertEqual(plan.date, "2026-10-26")
        XCTAssertEqual(plan.steps?.count, 3)
        XCTAssertEqual(s.steps.map(\.name), ["Writing", "Editing", "Reading"])
    }

    func testSpokenWithTitleAndStart() throws {
        let s = try XCTUnwrap(parse("morning startup, ten minutes of inbox, then ten minutes to plan the day, then five minutes reviewing the calendar, starting at 3"))
        XCTAssertEqual(s.name, "Morning startup")
        XCTAssertEqual(s.steps.map(\.seconds), [600, 600, 300])
        XCTAssertEqual(s.steps[1].name, "Plan the day")
        XCTAssertEqual(s.schedule?.startMinute, 15 * 60)
    }

    func testRangeRemainder() throws {
        let s = try XCTUnwrap(parse("Deep work 3-5: outline 30m, write 1h"))
        XCTAssertEqual(s.steps.map(\.seconds), [1_800, 3_600, 1_800])
        XCTAssertEqual(s.steps.last?.name, "Deep work")
    }

    func testNotASession() {
        XCTAssertNil(parse("Reply to emails 25m"))
        XCTAssertNil(parse("Deep work 9-10:30 weekdays"))
        XCTAssertNil(parse("Gym 6-7pm mon, wed, fri"))
        XCTAssertNil(parse("inbox 10m, then lunch"))
    }

    func testSavedByName() throws {
        let steps = [TimeBlock(name: "Inbox", seconds: 600), TimeBlock(name: "Plan", seconds: 600)]
        let lookup: (String) -> SessionParser.Saved? = { $0.lowercased() == "morning startup" ? ("Morning startup", steps) : nil }
        XCTAssertEqual(parse("Morning startup", saved: lookup)?.steps, steps)
        XCTAssertEqual(parse("morning startup at 8am", saved: lookup)?.schedule?.startMinute, 8 * 60)
    }

    func testTimerSteps() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var t = DriftTimer(name: "Morning startup", duration: 600)
        t.steps = [TimeBlock(name: "Inbox", seconds: 600), TimeBlock(name: "Plan", seconds: 300)]
        t.stepIndex = 0
        t.start(at: now)
        XCTAssertEqual(t.displayName, "Inbox")

        // Ends: a 10-second hand-off, then the next block starts by itself.
        XCTAssertTrue(t.advanceStep(at: now.addingTimeInterval(600), fromEnd: true, delay: 10))
        XCTAssertEqual(t.displayName, "Plan")
        XCTAssertTrue(t.isWaiting)
        XCTAssertEqual(t.handoff, "Inbox")
        XCTAssertTrue(t.waitIsOver(at: now.addingTimeInterval(611)))
        t.startWaiting(at: now.addingTimeInterval(611))
        XCTAssertTrue(t.isRunning)
        XCTAssertEqual(t.remaining(at: now.addingTimeInterval(611)), 300)
        XCTAssertFalse(t.advanceStep(at: now, fromEnd: true))

        // Extra time is counted per block.
        t.recordExtra(120)
        XCTAssertEqual(t.extraSoFar, 120)
        XCTAssertEqual(t.steps?[0].extra, 0)
    }

    func testOldTimersStillDecode() throws {
        let json = #"[{"id":"7C3B8C3E-2D7B-4C55-8F0A-6B2B8D8F8E11","duration":1500,"state":{"idle":{}},"createdAt":0}]"#
        let timers = try JSONDecoder().decode([DriftTimer].self, from: Data(json.utf8))
        XCTAssertNil(timers[0].steps)
        XCTAssertEqual(timers[0].extraSoFar, 0)
    }
}
