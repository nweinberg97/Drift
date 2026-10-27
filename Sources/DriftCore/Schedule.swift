import Foundation

// MARK: - Model

/// A planned time box: "Deep work 9–10:30 weekdays" or "Email today at 1pm for 30m".
/// When its time comes Drift asks, then starts a timer that ends when the block ends.
public struct ScheduledBlock: Codable, Identifiable, Equatable, Sendable {
    /// What a single day looks like when it was changed "just today".
    public struct Override: Codable, Equatable, Sendable {
        public var name: String
        public var startMinute: Int
        public var duration: TimeInterval

        public init(name: String, startMinute: Int, duration: TimeInterval) {
            self.name = name
            self.startMinute = startMinute
            self.duration = duration
        }
    }

    public enum DayStatus: String, Codable, Sendable {
        case started, skipped, missed
    }

    public var id: UUID
    public var name: String
    /// Minutes after midnight, local time.
    public var startMinute: Int
    public var duration: TimeInterval
    /// Weekdays it repeats on, 0 = Sunday … 6 = Saturday. `nil` means once, on `date`.
    public var days: [Int]?
    /// Day key ("2026-10-26") of a one-off block.
    public var date: String?
    /// What happened on each day: started, skipped, or let pass.
    public var status: [String: DayStatus]
    public var snoozedUntil: [String: Date]
    /// Per-day changes made "just today".
    public var overrides: [String: Override]

    public init(id: UUID = UUID(), name: String, startMinute: Int, duration: TimeInterval, days: [Int]?, date: String?) {
        self.id = id
        self.name = name
        self.startMinute = startMinute
        self.duration = duration
        self.days = days.map { Array(Set($0)).sorted() }
        self.date = days == nil ? date : nil
        status = [:]
        snoozedUntil = [:]
        overrides = [:]
    }

    public init(spec: ScheduleSpec) {
        self.init(name: spec.name, startMinute: spec.startMinute, duration: spec.duration, days: spec.days, date: spec.date)
    }

    public var isRepeating: Bool { days != nil }

    public func occurs(onDayKey key: String, weekday: Int) -> Bool {
        if let days { return days.contains(weekday) }
        return date == key
    }

    /// The block as it runs on a given day, with any "just today" change applied.
    public func effective(on key: String) -> Override {
        overrides[key] ?? Override(name: name, startMinute: startMinute, duration: duration)
    }
}

/// One day's instance of a block.
public struct BlockOccurrence: Equatable, Sendable {
    public var blockID: UUID
    public var name: String
    public var startMinute: Int
    public var duration: TimeInterval
    public var start: Date
    public var end: Date
    public var dayKey: String
    /// Changed for this day only.
    public var edited: Bool
}

public enum Schedule {
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 0 = Sunday … 6 = Saturday.
    public static func weekday(_ date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.weekday, from: date) - 1
    }

    public static func occurrence(of block: ScheduledBlock, on date: Date, calendar: Calendar = .current) -> BlockOccurrence? {
        let key = dayKey(date, calendar: calendar)
        guard block.occurs(onDayKey: key, weekday: weekday(date, calendar: calendar)) else { return nil }
        let e = block.effective(on: key)
        let midnight = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .minute, value: e.startMinute, to: midnight) else { return nil }
        return BlockOccurrence(
            blockID: block.id, name: e.name, startMinute: e.startMinute, duration: e.duration,
            start: start, end: start.addingTimeInterval(e.duration), dayKey: key,
            edited: block.overrides[key] != nil
        )
    }

    /// Today's (or any day's) blocks, earliest first.
    public static func occurrences(_ blocks: [ScheduledBlock], on date: Date, calendar: Calendar = .current) -> [BlockOccurrence] {
        blocks.compactMap { occurrence(of: $0, on: date, calendar: calendar) }.sorted { $0.start < $1.start }
    }

    // MARK: Formatting

    /// 570 → "9:30 AM"
    public static func time(_ minute: Int, suffix: Bool = true) -> String {
        let m = ((minute % 1_440) + 1_440) % 1_440
        let h = m / 60, h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d", h12, m % 60) + (suffix ? (h < 12 ? " AM" : " PM") : "")
    }

    /// "9:00–10:30 AM", "11:30 AM–1:00 PM"
    public static func range(startMinute: Int, duration: TimeInterval) -> String {
        let end = startMinute + Int((duration / 60).rounded())
        let sameHalf = (startMinute % 1_440 < 720) == ((end % 1_440) < 720)
        return "\(time(startMinute, suffix: !sameHalf))–\(time(end))"
    }

    public static let shortDayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// "Weekdays", "Every day", "Mon, Wed, Fri", "Today", "Tomorrow", "Thu, Oct 29"
    public static func describeDays(_ days: [Int]?, date: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        if let days {
            let set = Set(days)
            if set == Set(0...6) { return "Every day" }
            if set == Set(1...5) { return "Weekdays" }
            if set == [0, 6] { return "Weekends" }
            // Monday first.
            return set.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }.map { shortDayNames[$0] }.joined(separator: ", ")
        }
        guard let date else { return "" }
        if date == dayKey(now, calendar: calendar) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), date == dayKey(tomorrow, calendar: calendar) { return "Tomorrow" }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let d = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return date }
        let f = DateFormatter()
        f.calendar = calendar
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return f.string(from: d)
    }
}

// MARK: - Parsing

/// What "Deep work 9–10:30 weekdays" means, plus which parts of the text said so
/// (for highlighting in the launcher).
public struct ScheduleSpec: Equatable {
    public var name: String
    public var startMinute: Int
    public var duration: TimeInterval
    public var days: [Int]?
    public var date: String?
    /// "9–10:30", "weekdays", "at 1pm": when it happens.
    public var whenRanges: [Range<String.Index>]
    /// "30m": how long, when it isn't implied by a range.
    public var lengthRanges: [Range<String.Index>]

    public init(name: String, startMinute: Int, duration: TimeInterval, days: [Int]?, date: String?,
                whenRanges: [Range<String.Index>] = [], lengthRanges: [Range<String.Index>] = []) {
        self.name = name
        self.startMinute = startMinute
        self.duration = duration
        self.days = days
        self.date = date
        self.whenRanges = whenRanges
        self.lengthRanges = lengthRanges
    }
}

public enum ScheduleParser {
    /// Reads a schedule from launcher text. Needs a time of day: a range ("9–10:30"),
    /// "at …", or am/pm. A bare "9:30" stays a 9½-hour duration, so it returns nil.
    ///
    ///   "Deep work 9-10:30 weekdays"  "Gym 6-7pm mon wed fri"
    ///   "Email at 1pm for 30m"        "standup tomorrow at 9:15am"
    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current, defaultDuration: TimeInterval = 1_500) -> ScheduleSpec? {
        let normalized = input.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        let lower = normalized.lowercased()
        let ns = lower as NSString
        // Highlights map back onto the original text only if lengths line up.
        let mappable = ns.length == (input as NSString).length
        var when: [NSRange] = []
        var cut: [String] = []

        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }

        struct T { var min: Int; var suffix: Character?; var h24: Bool }
        func toMin(_ h: String?, _ m: String?, _ s: String?) -> T? {
            guard var hour = h.flatMap({ Int($0) }) else { return nil }
            let minute = m.flatMap { Int($0) } ?? 0
            guard hour <= 23, minute <= 59 else { return nil }
            let suffix = s?.first
            if let suffix {
                guard hour <= 12 else { return nil }
                if suffix == "p" && hour < 12 { hour += 12 }
                if suffix == "a" && hour == 12 { hour = 0 }
            }
            return T(min: hour * 60 + minute, suffix: suffix, h24: suffix == nil && (hour > 12 || hour == 0))
        }
        // Without am/pm, 1–7 o'clock means the afternoon: working hours.
        func guess(_ t: T) -> Int {
            (t.suffix == nil && !t.h24 && t.min >= 60 && t.min < 8 * 60) ? t.min + 720 : t.min
        }

        let tm = "(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm|a\\.m\\.|p\\.m\\.)?"
        let rangeRE = try! NSRegularExpression(pattern: "(?:\\bfrom\\s+)?\\b\(tm)\\s*(?:-|to|until|till)\\s*\(tm)(?![\\d:])")
        let atRE = try! NSRegularExpression(pattern: "(?:\\bat\\s+|@\\s*)\(tm)(?![\\d:])")
        let ampmRE = try! NSRegularExpression(pattern: "\\b(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm|a\\.m\\.|p\\.m\\.)")
        let unitAfterRE = try! NSRegularExpression(pattern: "^\\s*(s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?)\\b")
        let full = NSRange(location: 0, length: ns.length)

        var start: Int?
        var end: Int?
        if let m = rangeRE.firstMatch(in: lower, range: full) {
            let afterLoc = m.range.location + m.range.length
            let after = ns.substring(from: afterLoc)
            let unitAfter = unitAfterRE.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) != nil
            let h1 = Int(group(m, 1) ?? "") ?? 99, h2 = Int(group(m, 4) ?? "") ?? 99
            let explicit = group(m, 2) != nil || group(m, 3) != nil || group(m, 5) != nil || group(m, 6) != nil
                || ns.substring(with: m.range).hasPrefix("from") || (h1 <= 12 && h2 <= 12)
            if !unitAfter, explicit, let a = toMin(group(m, 1), group(m, 2), group(m, 3)), let b = toMin(group(m, 4), group(m, 5), group(m, 6)) {
                var s0 = a.min, e0 = b.min
                if let sa = a.suffix, b.suffix == nil, !b.h24 {
                    e0 = b.min + (sa == "p" && b.min < 720 ? 720 : 0)
                    if e0 <= s0 { e0 += 720 }
                } else if a.suffix == nil, let sb = b.suffix, !a.h24 {
                    s0 = a.min + (sb == "p" && a.min < 720 ? 720 : 0)
                    if s0 >= e0 { s0 -= 720 }
                } else if a.suffix == nil, b.suffix == nil {
                    s0 = guess(a)
                    e0 = guess(b)
                    if e0 <= s0 { e0 += 720 }
                }
                if e0 <= s0 { e0 += 1_440 }
                start = s0
                end = e0
                when.append(m.range)
                cut.append(ns.substring(with: m.range))
            }
        }
        if start == nil, let m = atRE.firstMatch(in: lower, range: full), let a = toMin(group(m, 1), group(m, 2), group(m, 3)) {
            start = guess(a)
            when.append(m.range)
            cut.append(ns.substring(with: m.range))
        }
        if start == nil, let m = ampmRE.firstMatch(in: lower, range: full), let a = toMin(group(m, 1), group(m, 2), group(m, 3)) {
            start = a.min
            when.append(m.range)
            cut.append(ns.substring(with: m.range))
        }
        guard let startMinute = start else { return nil }

        // Days
        let dayWord = "(?:sun|mon|tue|tues|wed|weds|thu|thur|thurs|fri|sat)(?:day|days|s)?|(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday)s?"
        let dayRE = try! NSRegularExpression(pattern: "\\b(every\\s*day|everyday|daily|each day|every\\s+weekday|weekdays|week\\s*days|weekends?|every\\s+weekend|today|tonight|tomorrow|(?:every\\s+|on\\s+)?(?:\(dayWord))(?:\\s*(?:,|/|and|&|\\s)\\s*(?:\(dayWord)))*)\\b")
        var days: [Int]?
        var once: Int?
        for m in dayRE.matches(in: lower, range: full) {
            let w = ns.substring(with: m.range)
            if w.range(of: "every\\s*day|everyday|daily|each day", options: .regularExpression) != nil { days = Array(0...6) }
            else if w.range(of: "weekday|week\\s*days", options: .regularExpression) != nil { days = Array(1...5) }
            else if w.contains("weekend") { days = [0, 6] }
            else if w == "today" || w == "tonight" { once = 0 }
            else if w == "tomorrow" { once = 1 }
            else {
                let list = w.components(separatedBy: CharacterSet(charactersIn: " ,/&"))
                    .compactMap { dayNumbers[$0] }
                if !list.isEmpty { days = Array(Set((days ?? []) + list)).sorted() }
            }
            when.append(m.range)
            cut.append(w)
        }

        // Length: a range sets it, then "for 30m", then the default.
        var rest = lower
        for c in cut {
            if let r = rest.range(of: c) { rest.replaceSubrange(r, with: " ") }
        }
        var duration: TimeInterval? = end.map { TimeInterval(($0 - startMinute) * 60) }
        var name: String?
        var length: [Range<String.Index>] = []
        if duration == nil, let d = DurationParser.parse(rest) {
            duration = d.seconds
            name = d.label
            if mappable {
                let whenRanges = when.compactMap { Range($0, in: input) }
                length = LauncherText.timeRanges(in: input).filter { r in !whenRanges.contains { $0.overlaps(r) } }
            }
        }
        if name == nil {
            let words = DurationParser.tokenize(rest).filter { !scheduleFiller.contains($0) }
            name = DurationParser.cleanLabel(words)
        }
        let seconds = duration ?? defaultDuration
        guard seconds >= 60, seconds <= 16 * 3_600 else { return nil }

        var date: String?
        if days == nil {
            let nowMinute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
            let offset = once ?? (startMinute % 1_440 > nowMinute ? 0 : 1)
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
            date = Schedule.dayKey(day, calendar: calendar)
        }

        var whenRanges: [Range<String.Index>] = []
        if mappable {
            whenRanges = when.compactMap { Range(trimmed($0, in: ns), in: input) }.sorted { $0.lowerBound < $1.lowerBound }
        }
        return ScheduleSpec(
            name: name ?? "Focus", startMinute: startMinute % 1_440, duration: seconds,
            days: days, date: date, whenRanges: whenRanges, lengthRanges: length
        )
    }

    static let dayNumbers: [String: Int] = [
        "sun": 0, "sunday": 0, "sundays": 0, "suns": 0,
        "mon": 1, "monday": 1, "mondays": 1, "mons": 1,
        "tue": 2, "tues": 2, "tuesday": 2, "tuesdays": 2,
        "wed": 3, "weds": 3, "wednesday": 3, "wednesdays": 3,
        "thu": 4, "thur": 4, "thurs": 4, "thursday": 4, "thursdays": 4,
        "fri": 5, "friday": 5, "fridays": 5, "fris": 5,
        "sat": 6, "saturday": 6, "saturdays": 6, "sats": 6,
    ]

    static let scheduleFiller: Set<String> = [
        "from", "to", "until", "till", "every", "each", "on", "at", "for", "starting", "schedule", "block",
    ]

    /// Drops whitespace at either end of a highlight.
    private static func trimmed(_ r: NSRange, in ns: NSString) -> NSRange {
        var lo = r.location, hi = r.location + r.length
        let ws = CharacterSet.whitespaces
        while hi > lo, let u = UnicodeScalar(ns.character(at: hi - 1)), ws.contains(u) { hi -= 1 }
        while lo < hi, let u = UnicodeScalar(ns.character(at: lo)), ws.contains(u) { lo += 1 }
        return NSRange(location: lo, length: hi - lo)
    }
}
