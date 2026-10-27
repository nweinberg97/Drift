import Foundation

/// Helpers for the task-first launcher: where the time is in what you typed
/// (so it can be highlighted), and what to call a timer when you only wrote
/// the task.
public enum LauncherText {
    private static let timePattern: NSRegularExpression = {
        let small = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|ninety"
        let tens = "(?:twenty|thirty|forty|fifty|sixty)(?:[\\s-](?:one|two|three|four|five|six|seven|eight|nine))?"
        let units = "h|hrs?|hours?|m|mn|mins?|minutes?|s|secs?|seconds?|d|days?"
        let pattern = "\\b\\d{1,3}:\\d{2}(?::\\d{2})?\\b"
            + "|\\bhalf an hour\\b"
            + "|\\b(?:an?|\\d+(?:\\.\\d+)?|\(tens)|\(small))\\s*(?:\(units))\\b(?:\\s+and a half)?"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Ranges of `text` that read as a duration: "45m", "1:30", "an hour and a half".
    /// A lone number at either end ("25", "intro 25") counts when the whole
    /// text parses as a duration.
    public static func timeRanges(in text: String) -> [Range<String.Index>] {
        let ns = NSRange(text.startIndex..., in: text)
        var out = timePattern.matches(in: text, range: ns).compactMap { Range($0.range, in: text) }
        if out.isEmpty, DurationParser.parse(text) != nil,
           let bare = try? NSRegularExpression(pattern: "^\\s*\\d+(?:\\.\\d+)?\\b|\\b\\d+(?:\\.\\d+)?\\s*$"),
           let m = bare.firstMatch(in: text, range: ns), let r = Range(m.range, in: text) {
            out.append(r)
        }
        return out
    }

    /// "write intro" → "Write intro". `nil` when there's nothing that reads
    /// like a task (empty, or only digits and punctuation).
    public static func task(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return nil }
        let label = trimmed.count > 40 ? String(trimmed.prefix(40)) : trimmed
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}
