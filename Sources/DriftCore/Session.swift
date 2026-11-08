import Foundation

/// One piece of a session: "Inbox, 10 minutes".
public struct TimeBlock: Codable, Equatable, Sendable {
    public var name: String
    public var seconds: TimeInterval
    /// Extra time added to this block so far (for the grace period).
    public var extra: TimeInterval

    public init(name: String, seconds: TimeInterval, extra: TimeInterval = 0) {
        self.name = name
        self.seconds = seconds
        self.extra = extra
    }
}

/// What "Morning startup: inbox 10m, plan the day 10m, review calendar 5m"
/// means: a session of time blocks that run back to back, maybe at a set time.
public struct SessionSpec: Equatable {
    public var name: String
    public var steps: [TimeBlock]
    /// A length given for the whole session ("Morning startup 30m: …"), to check the blocks against.
    public var declared: TimeInterval?
    /// Set when it has a start time ("starting at 2pm"): plan it rather than start it.
    public var schedule: ScheduleSpec?
    /// Lengths and times of day in the text, for highlighting.
    public var lengthRanges: [Range<String.Index>]
    public var whenRanges: [Range<String.Index>]

    public var total: TimeInterval { steps.reduce(0) { $0 + $1.seconds } }
}

public enum SessionParser {
    public typealias Saved = (name: String, steps: [TimeBlock])

    private static let separator = try! NSRegularExpression(
        pattern: "\\s*(?:,|;|\\n|\\band then\\b|\\bthen\\b|\\bfollowed by\\b|\\bafter that\\b|\\+|→|->)\\s*",
        options: [.caseInsensitive])
    private static let preamble = try! NSRegularExpression(
        pattern: "^\\s*(?:and\\s+)?(?:then\\s+)?(?:after\\s+that\\s+)?(?:(?:i['’]?m|i\\s+am|i['’]?ll|i\\s+will|i\\s+want\\s+to|let['’]?s|we['’]?re)\\s+)?(?:(?:going\\s+to|gonna)\\s+)?(?:(?:do|doing|time\\s*box(?:ing)?|block(?:ing)?|spend|have|start(?:ing)?\\s+with)\\s+)?(?:my\\s+)?",
        options: [.caseInsensitive])
    private static let startWords = try! NSRegularExpression(
        pattern: "\\b(?:start(?:ing)?|begin(?:ning)?|kick off)\\s*(?=\\s*$|\\s{2,})",
        options: [.caseInsensitive])
    /// A colon that isn't part of a time like 1:30.
    private static let titleColon = try! NSRegularExpression(pattern: "(?<!\\d):(?!\\d)")
    private static let andSplit = try! NSRegularExpression(pattern: "\\s+and\\s+", options: [.caseInsensitive])
    private static let rangeWords = try! NSRegularExpression(pattern: "-|\\bto\\b|\\buntil\\b|\\btill\\b", options: [.caseInsensitive])

    /// True when the text lists more than one thing ("a, b", "a then b").
    public static func hasSeparator(_ text: String) -> Bool {
        separator.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Reads a session. Needs at least two time blocks, or the name of a saved session.
    ///
    ///   "Morning startup: inbox 10m, plan the day 10m, review calendar 5m"
    ///   "10m writing, 20m editing, 30m reading"
    ///   "10m writing, 20m editing, starting at 2pm"
    ///   "morning startup, ten minutes of inbox, then ten minutes to plan the day"
    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current,
                             defaultDuration: TimeInterval = 1_500,
                             saved: (String) -> Saved? = { _ in nil }) -> SessionSpec? {
        let normalized = input.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        let schedule = ScheduleParser.parse(input, now: now, calendar: calendar, defaultDuration: defaultDuration)
        let when = schedule?.whenRanges ?? []

        // Blank out the "when" words so they don't end up in block names.
        let masked = NSMutableString(string: normalized)
        if (normalized as NSString).length == (input as NSString).length {
            for r in when {
                let nr = NSRange(r, in: input)
                masked.replaceCharacters(in: nr, with: String(repeating: " ", count: nr.length))
            }
        }
        for m in startWords.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)).reversed() {
            masked.replaceCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
        }
        let text = masked as String
        let lengths = LauncherText.timeRanges(in: input).filter { r in !when.contains { $0.overlaps(r) } }

        func spec(_ name: String, _ steps: [TimeBlock], declared: TimeInterval?) -> SessionSpec {
            var plan: ScheduleSpec?
            if let schedule, !when.isEmpty {
                plan = ScheduleSpec(name: name, startMinute: schedule.startMinute, duration: steps.reduce(0) { $0 + $1.seconds },
                                    days: schedule.days, date: schedule.date, whenRanges: when, lengthRanges: [], steps: steps)
            }
            return SessionSpec(name: name, steps: steps, declared: declared, schedule: plan, lengthRanges: lengths, whenRanges: when)
        }

        // A saved session by name, maybe with a time: "Morning startup at 8am".
        if !hasSeparator(text) {
            let bare = collapse(text)
            guard !bare.isEmpty, let s = saved(bare), s.steps.count > 1 else { return nil }
            return spec(s.name, s.steps, declared: nil)
        }

        // Title: before a colon.
        var title = ""
        var body = text
        let ns = text as NSString
        if let c = titleColon.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), c.range.location > 0 {
            title = ns.substring(to: c.range.location)
            body = ns.substring(from: c.range.location + 1)
        }
        var pieces = split(body).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var parsed = pieces.map(blocks(in:))

        // "Morning startup, ten minutes of inbox, then …": a first piece with no length names it.
        if title.isEmpty, parsed.count > 2, parsed[0].isEmpty, parsed.dropFirst().allSatisfy({ !$0.isEmpty }) {
            title = pieces.removeFirst()
            parsed.removeFirst()
        }
        // "30 minutes of planning, 10 minutes of …": a first piece as long as all the rest names it.
        if title.isEmpty, parsed.count > 2, parsed[0].count == 1 {
            let rest = parsed.dropFirst().flatMap { $0 }.reduce(0) { $0 + $1.seconds }
            if parsed[0][0].seconds == rest {
                title = pieces.removeFirst()
                parsed.removeFirst()
            }
        }

        var steps = parsed.flatMap { $0 }
        for i in steps.indices where steps[i].name.isEmpty { steps[i].name = "Time block \(i + 1)" }

        var declared: TimeInterval?
        if !title.isEmpty {
            let body = strip(preamble, from: title)
            if let d = DurationParser.parse(body) {
                declared = d.seconds
                title = d.label ?? ""
            } else {
                title = DurationParser.cleanLabel(DurationParser.tokenize(body)) ?? ""
            }
            let words = DurationParser.tokenize(title)
            if words.count > 1 {
                title = DurationParser.cleanLabel(words.filter { $0 != "session" && $0 != "practice" }) ?? title
            }
        }

        if steps.count < 2 {
            guard let s = saved(title.isEmpty ? collapse(text) : title), s.steps.count > 1 else { return nil }
            return spec(s.name, s.steps, declared: nil)
        }

        // A range longer than the blocks ("Deep work 9-11: outline 30m, write 1h"): the rest is a last block.
        if let schedule, when.contains(where: { r in
            let w = String(input[r])
            return rangeWords.firstMatch(in: w, range: NSRange(location: 0, length: (w as NSString).length)) != nil
        }) {
            let total = steps.reduce(0) { $0 + $1.seconds }
            if schedule.duration > total + 59 {
                steps.append(TimeBlock(name: title.isEmpty ? "More time" : title, seconds: schedule.duration - total))
            }
        }

        let names = steps.map(\.name)
        let name = !title.isEmpty ? title
            : names.count <= 3 ? names.joined(separator: ", ")
            : "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2) more"
        return spec(name, steps, declared: declared)
    }

    /// Just the blocks from a list like "outline 30m, write 1h, edit 30m".
    public static func steps(from text: String) -> [TimeBlock] {
        var out = split(text).flatMap(blocks(in:))
        for i in out.indices where out[i].name.isEmpty { out[i].name = "Time block \(i + 1)" }
        return out
    }

    // MARK: Pieces

    static func split(_ text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        var at = 0
        for m in separator.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > at { out.append(ns.substring(with: NSRange(location: at, length: m.range.location - at))) }
            at = m.range.location + m.range.length
        }
        if at < ns.length { out.append(ns.substring(from: at)) }
        return out
    }

    /// "5 minutes prioritization and 5 minutes planning" → two blocks; "research and writing 30m" → one.
    static func blocks(in piece: String) -> [TimeBlock] {
        let ns = piece as NSString
        var halves: [String] = []
        var at = 0
        for m in andSplit.matches(in: piece, range: NSRange(location: 0, length: ns.length)) {
            halves.append(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            at = m.range.location + m.range.length
        }
        halves.append(ns.substring(from: at))
        let parts = halves.count > 1 && halves.allSatisfy({ DurationParser.parse($0) != nil }) ? halves : [piece]
        return parts.compactMap(block(from:))
    }

    static func block(from text: String) -> TimeBlock? {
        let body = strip(preamble, from: text)
        guard let d = DurationParser.parse(body) else { return nil }
        let words = DurationParser.tokenize(d.label ?? "").filter { !["minute", "minutes", "min", "mins", "block", "blocks"].contains($0) }
        return TimeBlock(name: DurationParser.cleanLabel(words) ?? "", seconds: d.seconds)
    }

    private static func strip(_ re: NSRegularExpression, from text: String) -> String {
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return text }
        return ns.substring(from: m.range.location + m.range.length)
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
