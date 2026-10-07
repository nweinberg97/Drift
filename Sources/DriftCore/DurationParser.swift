import Foundation

public struct ParsedDuration: Equatable, Sendable {
    public var seconds: TimeInterval
    /// Any words that weren't part of the duration, cleaned up into a timer
    /// name. "45m writing" → "Writing".
    public var label: String?

    public init(seconds: TimeInterval, label: String? = nil) {
        self.seconds = seconds
        self.label = label
    }
}

/// Turns what people actually type or say into a duration.
///
///   25            → 25 minutes (a bare number means minutes)
///   1:30          → 1 hour 30 minutes;  1:30:15 → with seconds
///   90s, 2h 15m, 36h, 3d, 1.5h
///   25 min, 1 hour 30 minutes, an hour and a half, half an hour
///   twenty five minutes
///   45m writing, writing 45m, "a 10 minute timer called break"
public enum DurationParser {
    /// Generous ceiling — there is no 60-minute or 24-hour limit.
    public static let maximum: TimeInterval = 366 * 86_400

    public static func parse(_ input: String) -> ParsedDuration? {
        var text = input.lowercased()
        var total: Double = 0
        var foundDuration = false

        if let colon = colonDuration(in: text) {
            total += colon.seconds
            foundDuration = true
            text.replaceSubrange(colon.range, with: " ")
        }

        let tokens = tokenize(text)
        var leftovers: [(index: Int, word: String)] = []
        var bare: [(index: Int, value: Double, word: String)] = []
        var lastUnit: Double?
        var lastUnitEnd = -1
        var i = 0

        while i < tokens.count {
            let token = tokens[i]

            // "half an hour", "half a minute", "half hour"
            if token == "half" {
                if i + 2 < tokens.count, articles.contains(tokens[i + 1]), let u = unit(tokens[i + 2]) {
                    total += 0.5 * u
                    foundDuration = true
                    lastUnit = u
                    i += 3
                    lastUnitEnd = i
                    continue
                }
                if i + 1 < tokens.count, let u = unit(tokens[i + 1]) {
                    total += 0.5 * u
                    foundDuration = true
                    lastUnit = u
                    i += 2
                    lastUnitEnd = i
                    continue
                }
            }

            if let number = number(at: i, in: tokens) {
                let j = i + number.consumed

                // "25 minutes", "an hour", "2h"
                if j < tokens.count, let u = unit(tokens[j]) {
                    total += number.value * u
                    foundDuration = true
                    lastUnit = u
                    i = j + 1
                    // "an hour and a half"
                    if isAndAHalf(tokens, at: i) {
                        total += 0.5 * u
                        i += 3
                    }
                    lastUnitEnd = i
                    continue
                }

                // "1 and a half hours"
                if isAndAHalf(tokens, at: j), j + 3 < tokens.count, let u = unit(tokens[j + 3]) {
                    total += (number.value + 0.5) * u
                    foundDuration = true
                    lastUnit = u
                    i = j + 4
                    lastUnitEnd = i
                    continue
                }

                // A lone "a"/"an" is just an article.
                if number.isArticle {
                    leftovers.append((i, token))
                    i += 1
                    continue
                }

                // "1h 30" → 30 minutes; "2m 10" → 10 seconds
                if i == lastUnitEnd, let previous = lastUnit, let lower = nextLowerUnit(previous) {
                    total += number.value * lower
                    lastUnit = lower
                    i = j
                    lastUnitEnd = i
                    continue
                }

                bare.append((i, number.value, tokens[i..<j].joined(separator: " ")))
                i = j
                continue
            }

            leftovers.append((i, token))
            i += 1
        }

        // A number with no unit anywhere means minutes: "25", "25 writing".
        if !foundDuration, let first = bare.first {
            total += first.value * 60
            foundDuration = true
            bare.removeFirst()
        }
        // Remaining unit-less numbers belong to the name: "45m chapter 3".
        leftovers += bare.map { ($0.index, $0.word) }

        guard foundDuration, total.isFinite, total >= 1, total <= maximum else { return nil }

        let words = leftovers.sorted { $0.index < $1.index }.map(\.word)
        return ParsedDuration(seconds: total.rounded(), label: cleanLabel(words))
    }

    // MARK: - Label cleanup

    static let filler: Set<String> = [
        "a", "an", "the", "my", "for", "of", "to", "on", "in", "with", "and", "at",
        "timer", "timers", "countdown", "clock", "alarm",
        "called", "named", "labeled", "labelled", "titled", "name", "label",
        "start", "starting", "set", "new", "begin", "create", "make", "run", "add",
        "please", "it", "me", "up", "just", "another", "now", "go",
        "hey", "drift", "ok", "okay", "can", "could", "would", "you", "i", "want", "need",
        "lets", "let's", "give", "get", "do",
    ]

    /// Strips filler from both ends and capitalises the first letter.
    /// "a timer called writing" → "Writing"; "read the book" stays intact.
    public static func cleanLabel(_ words: [String]) -> String? {
        var w = words.filter { !$0.isEmpty }
        while let first = w.first, filler.contains(first) { w.removeFirst() }
        while let last = w.last, filler.contains(last) { w.removeLast() }
        guard !w.isEmpty else { return nil }
        var label = w.joined(separator: " ")
        if label.count > 40 { label = String(label.prefix(40)) }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    // MARK: - Tokens

    static let articles: Set<String> = ["a", "an", "one"]

    static func isAndAHalf(_ tokens: [String], at i: Int) -> Bool {
        i + 2 < tokens.count && tokens[i] == "and" && articles.contains(tokens[i + 1]) && tokens[i + 2] == "half"
    }

    /// Lowercased words with digits split from letters ("1h30m" → 1 h 30 m)
    /// and edge punctuation removed.
    static func tokenize(_ text: String) -> [String] {
        var spaced = ""
        var previous: Character?
        for ch in text {
            let separator = ch == "-" || ch == "," || ch == "/" || ch == "+" || ch == "–" || ch == "—"
            let current: Character = separator ? " " : ch
            if let p = previous {
                let boundary = (p.isNumber && current.isLetter) || (p.isLetter && current.isNumber)
                if boundary { spaced.append(" ") }
            }
            spaced.append(current)
            previous = current
        }
        let edges = CharacterSet(charactersIn: ".,!?;:\"'()[]“”‘’")
        return spaced
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: edges) }
            .filter { !$0.isEmpty }
    }

    static func unit(_ token: String) -> Double? {
        switch token {
        case "s", "sec", "secs", "second", "seconds": return 1
        case "m", "mn", "min", "mins", "minute", "minutes": return 60
        case "h", "hr", "hrs", "hour", "hours": return 3_600
        case "d", "day", "days": return 86_400
        case "w", "wk", "wks", "week", "weeks": return 604_800
        default: return nil
        }
    }

    static func nextLowerUnit(_ unit: Double) -> Double? {
        switch unit {
        case 604_800: return 86_400
        case 86_400: return 3_600
        case 3_600: return 60
        case 60: return 1
        default: return nil
        }
    }

    static let ones: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    static let tens: [String: Double] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    struct NumberToken {
        var value: Double
        var consumed: Int
        var isArticle: Bool
    }

    static func number(at i: Int, in tokens: [String]) -> NumberToken? {
        let token = tokens[i]
        if let first = token.first, first.isNumber || first == "." {
            guard let value = Double(token), value.isFinite, value >= 0 else { return nil }
            return NumberToken(value: value, consumed: 1, isArticle: false)
        }
        if let t = tens[token] {
            if i + 1 < tokens.count, let o = ones[tokens[i + 1]], o >= 1, o <= 9 {
                return NumberToken(value: t + o, consumed: 2, isArticle: false)
            }
            return NumberToken(value: t, consumed: 1, isArticle: false)
        }
        if let o = ones[token] {
            return NumberToken(value: o, consumed: 1, isArticle: false)
        }
        if token == "a" || token == "an" {
            return NumberToken(value: 1, consumed: 1, isArticle: true)
        }
        return nil
    }

    // MARK: - Clock notation

    private static let colonPattern = try! NSRegularExpression(
        pattern: #"(?<![\d:])(\d{1,3}):(\d{2})(?::(\d{2}))?(?![\d:])"#
    )

    /// "1:30" → 1h 30m, "1:30:15" → 1h 30m 15s.
    static func colonDuration(in text: String) -> (seconds: Double, range: Range<String.Index>)? {
        let ns = NSRange(text.startIndex..., in: text)
        guard let match = colonPattern.firstMatch(in: text, range: ns),
              let whole = Range(match.range, in: text),
              let hRange = Range(match.range(at: 1), in: text),
              let mRange = Range(match.range(at: 2), in: text),
              let hours = Double(text[hRange]),
              let minutes = Double(text[mRange]),
              minutes < 60
        else { return nil }

        var seconds = hours * 3_600 + minutes * 60
        if match.range(at: 3).location != NSNotFound,
           let sRange = Range(match.range(at: 3), in: text),
           let s = Double(text[sRange]) {
            guard s < 60 else { return nil }
            seconds += s
        }
        return (seconds, whole)
    }
}
