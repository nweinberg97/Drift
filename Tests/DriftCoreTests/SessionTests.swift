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

    // MARK: Guided breaks

    func testTypedBreaks() throws {
        let s = try XCTUnwrap(parse("Writing 25m, move 3m, editing 25m, water break 2m, breathe 1m"))
        XCTAssertEqual(s.steps.map(\.isBreak), [false, true, false, true, true])
        XCTAssertEqual(s.steps.map(\.breakKind), [nil, .move, nil, .hydrate, .breathe])
        XCTAssertEqual(s.steps[1].name, "Move break")
        XCTAssertEqual(s.steps[1].seconds, 180)
    }

    func testPlainBreakIsLeftToThePlan() throws {
        let s = try XCTUnwrap(parse("Inbox 15m, break 5m, calls 30m, coffee break 10m"))
        XCTAssertEqual(s.steps.map(\.isBreak), [false, true, false, true])
        XCTAssertNil(s.steps[1].breakKind)
        XCTAssertEqual(s.steps[1].name, "Break")
        XCTAssertEqual(s.steps[3].name, "Coffee break")
    }

    func testWorkThatMentionsBreakWordsStaysWork() throws {
        let s = try XCTUnwrap(parse("Walk the dog 20m, eat lunch 30m, write 25m"))
        XCTAssertEqual(s.steps.map(\.isBreak), [false, false, false])
    }

    func testOldSavedBlocksDecode() throws {
        let old = #"[{"name":"Inbox","seconds":600,"extra":0}]"#
        let blocks = try JSONDecoder().decode([TimeBlock].self, from: Data(old.utf8))
        XCTAssertFalse(blocks[0].isBreak)
        XCTAssertNil(blocks[0].breakKind)
    }

    func testPomodoroForgetsTheBreakWhenFocusStarts() {
        var c = PomodoroCycle()
        c.breakKind = .move
        let rest = c.advanced()
        XCTAssertEqual(rest.breakKind, .move)
        var withActivity = rest
        withActivity.activity = "Leg swings"
        let focus = withActivity.advanced()
        XCTAssertNil(focus.breakKind)
        XCTAssertNil(focus.activity)
    }

    // MARK: - Breaks between blocks, editing a running session

    private func blocks(_ names: String...) -> [TimeBlock] {
        names.map { $0 == "~" ? .rest(.move, seconds: 300) : TimeBlock(name: $0, seconds: 600) }
    }

    func testBreaksBetweenEveryBlock() {
        var b = blocks("A", "B", "~", "C", "D")
        XCTAssertEqual(b.insertBreaksBetween(.hydrate), 2)
        XCTAssertEqual(b.map(\.isBreak), [false, true, false, true, false, true, false])
        XCTAssertEqual(b[1].breakKind, .hydrate)
        XCTAssertEqual(b[3].breakKind, .move, "an existing break stays")
        XCTAssertEqual(b[1].seconds, 300)
    }

    func testBreaksBetweenOnlyAfterStart() {
        var b = blocks("A", "B", "C")
        XCTAssertEqual(b.insertBreaksBetween(.walk, after: 1), 1)
        XCTAssertEqual(b.map(\.name), ["A", "B", "Walk break", "C"])
        XCTAssertEqual(b[2].seconds, 600)
    }

    func testMoveBlock() {
        var b = blocks("A", "B", "C")
        XCTAssertTrue(b.moveBlock(at: 2, by: -1))
        XCTAssertEqual(b.map(\.name), ["A", "C", "B"])
        XCTAssertFalse(b.moveBlock(at: 0, by: -1))
    }

    private func runningSession(_ now: Date) -> DriftTimer {
        var t = DriftTimer(name: "Morning", duration: 600)
        t.steps = blocks("A", "B", "C", "D")
        t.stepIndex = 1
        t.start(at: now)
        return t
    }

    func testEditUpcomingLeavesDoneAndCurrentAlone() {
        let now = Date()
        var t = runningSession(now)
        let end = t.endDate
        t.editUpcoming { up in
            up.insert(.rest(.breathe, seconds: 300), at: 0)
            up.removeLast()
        }
        XCTAssertEqual(t.steps?.map(\.name), ["A", "B", "Breathe break", "C"])
        XCTAssertEqual(t.step, 1)
        XCTAssertEqual(t.endDate, end, "the clock keeps going")
    }

    func testResizeCurrentBlock() {
        let now = Date()
        var t = runningSession(now)
        XCTAssertTrue(t.resizeCurrentBlock(by: 300, at: now))
        XCTAssertEqual(t.remaining(at: now), 900, accuracy: 0.5)
        XCTAssertEqual(t.steps?[1].seconds, 900)
        XCTAssertFalse(t.resizeCurrentBlock(by: -880, at: now), "keeps a minute on the clock")
        XCTAssertEqual(t.remaining(at: now), 900, accuracy: 0.5)
        XCTAssertTrue(t.resizeCurrentBlock(by: -300, at: now))
        XCTAssertEqual(t.steps?[1].seconds, 600)
    }
}
