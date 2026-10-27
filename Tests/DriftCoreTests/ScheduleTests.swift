import XCTest
@testable import DriftCore

final class ScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        return c
    }

    /// Monday, 26 Oct 2026, 8:00 PM.
    private var monday8pm: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 20, minute: 0))!
    }

    private func parse(_ s: String) -> ScheduleSpec? {
        ScheduleParser.parse(s, now: monday8pm, calendar: calendar)
    }

    private func highlighted(_ s: String) -> [String] {
        guard let spec = parse(s) else { return [] }
        return (spec.whenRanges + spec.lengthRanges).sorted { $0.lowerBound < $1.lowerBound }.map { String(s[$0]) }
    }

    func testRangesAndDays() throws {
        let deep = try XCTUnwrap(parse("Deep work 9-10:30 weekdays"))
        XCTAssertEqual(deep.name, "Deep work")
        XCTAssertEqual(deep.startMinute, 9 * 60)
        XCTAssertEqual(deep.duration, 90 * 60)
        XCTAssertEqual(deep.days, [1, 2, 3, 4, 5])
        XCTAssertEqual(highlighted("Deep work 9-10:30 weekdays"), ["9-10:30", "weekdays"])

        let gym = try XCTUnwrap(parse("Gym 6-7pm mon wed fri"))
        XCTAssertEqual(gym.startMinute, 18 * 60)
        XCTAssertEqual(gym.duration, 3_600)
        XCTAssertEqual(gym.days, [1, 3, 5])

        let lunch = try XCTUnwrap(parse("lunch 12-1"))
        XCTAssertEqual(lunch.startMinute, 12 * 60)
        XCTAssertEqual(lunch.duration, 3_600)

        let fromTo = try XCTUnwrap(parse("Deep work from 9 to 11 every day"))
        XCTAssertEqual(fromTo.duration, 2 * 3_600)
        XCTAssertEqual(fromTo.days, Array(0...6))
    }

    func testAtWithLength() throws {
        let email = try XCTUnwrap(parse("Email at 1pm for 30m"))
        XCTAssertEqual(email.name, "Email")
        XCTAssertEqual(email.startMinute, 13 * 60)
        XCTAssertEqual(email.duration, 1_800)
        XCTAssertNil(email.days)
        // 1pm has passed at 8pm, so it's tomorrow.
        XCTAssertEqual(email.date, "2026-10-27")
        XCTAssertEqual(highlighted("Email at 1pm for 30m"), ["at 1pm", "30m"])

        let standup = try XCTUnwrap(parse("standup tomorrow at 9:15am"))
        XCTAssertEqual(standup.startMinute, 9 * 60 + 15)
        XCTAssertEqual(standup.duration, 1_500) // default length
        XCTAssertEqual(standup.date, "2026-10-27")

        let tonight = try XCTUnwrap(parse("Reading at 9pm"))
        XCTAssertEqual(tonight.date, "2026-10-26")

        // "at 3" means 3 PM: working hours.
        XCTAssertEqual(parse("Call at 3")?.startMinute, 15 * 60)
    }

    func testNotASchedule() {
        XCTAssertNil(parse("9:30"))            // a 9½-hour timer
        XCTAssertNil(parse("Write intro 45m"))
        XCTAssertNil(parse("25"))
        XCTAssertNil(parse("Write intro"))
    }

    func testOccurrencesAndOverrides() throws {
        var block = ScheduledBlock(name: "Deep work", startMinute: 9 * 60, duration: 5_400, days: [1, 2, 3, 4, 5], date: nil)
        let monday = monday8pm
        let sunday = calendar.date(byAdding: .day, value: -1, to: monday)!
        XCTAssertNotNil(Schedule.occurrence(of: block, on: monday, calendar: calendar))
        XCTAssertNil(Schedule.occurrence(of: block, on: sunday, calendar: calendar))

        // Just today: Monday moves to 10, Tuesday stays at 9.
        let key = Schedule.dayKey(monday, calendar: calendar)
        block.overrides[key] = .init(name: "Deep work", startMinute: 10 * 60, duration: 3_600)
        let mon = try XCTUnwrap(Schedule.occurrence(of: block, on: monday, calendar: calendar))
        XCTAssertEqual(mon.startMinute, 600)
        XCTAssertTrue(mon.edited)
        let tuesday = calendar.date(byAdding: .day, value: 1, to: monday)!
        XCTAssertEqual(Schedule.occurrence(of: block, on: tuesday, calendar: calendar)?.startMinute, 540)
    }

    func testFormatting() {
        XCTAssertEqual(Schedule.range(startMinute: 540, duration: 5_400), "9:00–10:30 AM")
        XCTAssertEqual(Schedule.range(startMinute: 690, duration: 5_400), "11:30 AM–1:00 PM")
        XCTAssertEqual(Schedule.describeDays([1, 2, 3, 4, 5], date: nil), "Weekdays")
        XCTAssertEqual(Schedule.describeDays([5, 1, 3], date: nil), "Mon, Wed, Fri")
        XCTAssertEqual(Schedule.describeDays(nil, date: "2026-10-26", now: monday8pm, calendar: calendar), "Today")
    }

    func testBlockRoundTrip() throws {
        var block = ScheduledBlock(name: "Gym", startMinute: 1_080, duration: 3_600, days: [1, 3, 5], date: nil)
        block.status["2026-10-26"] = .skipped
        let data = try JSONEncoder().encode([block])
        XCTAssertEqual(try JSONDecoder().decode([ScheduledBlock].self, from: data), [block])
    }
}
