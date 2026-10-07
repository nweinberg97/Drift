import Foundation

/// Everything Drift can be asked to do in words — typed into the composer,
/// spoken, or sent via a `drift://` URL.
public enum DriftCommand: Equatable, Sendable {
    case start(seconds: TimeInterval, name: String?)
    case pomodoro(focus: TimeInterval, rest: TimeInterval)
    case pause(target: String?)
    case resume(target: String?)
    case cancel(target: String?)
    case adjust(delta: TimeInterval, target: String?)
    case show
    case hide
}

public enum CommandParser {
    public static let defaultPomodoro: (focus: TimeInterval, rest: TimeInterval) = (25 * 60, 5 * 60)

    /// Parses natural language into a command, or `nil` if it can't tell
    /// what was meant.
    ///
    ///   "25", "45m writing", "start a timer for 1 hour called writing"  → start
    ///   "pomodoro", "50/10"                                              → pomodoro
    ///   "pause my focus timer", "resume", "cancel the laundry timer"     → pause / resume / cancel
    ///   "add 5 minutes", "take 5 minutes off laundry"                    → adjust
    ///   "show my timers", "hide"                                         → show / hide
    public static func parse(_ input: String) -> DriftCommand? {
        let lowered = input.lowercased()
        var words = DurationParser.tokenize(lowered)
        while let first = words.first, wakeWords.contains(first) { words.removeFirst() }
        guard let verb = words.first else { return nil }
        let rest = Array(words.dropFirst())
        let restText = rest.joined(separator: " ")

        // Pomodoro: "pomodoro", "pomodoro 50/10", or a bare "50/10".
        let ratio = pomodoroRatio(in: lowered)
        if words.contains(where: pomodoroWords.contains) {
            let r = ratio ?? defaultPomodoro
            return .pomodoro(focus: r.focus, rest: r.rest)
        }
        if let ratio, words.allSatisfy({ Double($0) != nil || DurationParser.unit($0) != nil }) {
            return .pomodoro(focus: ratio.focus, rest: ratio.rest)
        }

        switch verb {
        case "pause", "hold", "freeze", "halt", "suspend":
            return .pause(target: target(rest))

        case "resume", "continue", "unpause", "restart":
            return .resume(target: target(rest))

        case "add", "plus", "extend", "increase":
            if let d = DurationParser.parse(restText) {
                return .adjust(delta: d.seconds, target: target(labelWords(d.label)))
            }
            return nil

        case "subtract", "minus", "take", "reduce", "shorten", "cut", "less", "remove":
            if let d = DurationParser.parse(restText) {
                return .adjust(delta: -d.seconds, target: target(labelWords(d.label)))
            }
            return verb == "remove" ? .cancel(target: target(rest)) : nil

        case "cancel", "stop", "delete", "clear", "end", "kill", "dismiss", "discard":
            return .cancel(target: target(rest))

        case "show", "open", "display", "view", "list", "what", "what's", "whats", "how", "where", "check":
            return .show

        case "hide", "close", "minimize", "minimise", "dismissall":
            return .hide

        case "start", "begin", "run", "set", "create", "new", "make":
            if let d = DurationParser.parse(words.joined(separator: " ")) {
                return .start(seconds: d.seconds, name: d.label)
            }
            // "start focus" — resume a named, paused timer.
            if let name = target(rest) { return .resume(target: name) }
            return nil

        default:
            if let d = DurationParser.parse(words.joined(separator: " ")) {
                return .start(seconds: d.seconds, name: d.label)
            }
            return nil
        }
    }

    // MARK: - Helpers

    static let wakeWords: Set<String> = [
        "hey", "hi", "ok", "okay", "drift", "please", "can", "could", "would", "will", "you", "um", "uh",
    ]

    static let pomodoroWords: Set<String> = ["pomodoro", "pomodoros", "pomo", "pomodori"]

    static let targetNoise: Set<String> = ["off", "from", "by", "all", "everything", "current", "this", "that"]

    /// Reduces "my focus timer" to "focus". `nil` means "the primary timer".
    static func target(_ words: [String]) -> String? {
        let filtered = words.filter { !targetNoise.contains($0) }
        return DurationParser.cleanLabel(filtered)?.lowercased()
    }

    static func labelWords(_ label: String?) -> [String] {
        guard let label else { return [] }
        return DurationParser.tokenize(label.lowercased())
    }

    private static let ratioPattern = try! NSRegularExpression(pattern: #"(\d{1,3})\s*/\s*(\d{1,3})"#)

    /// "50/10" → (50 min, 10 min)
    static func pomodoroRatio(in text: String) -> (focus: TimeInterval, rest: TimeInterval)? {
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = ratioPattern.firstMatch(in: text, range: ns),
              let a = Range(m.range(at: 1), in: text),
              let b = Range(m.range(at: 2), in: text),
              let focus = Double(text[a]), let rest = Double(text[b]),
              focus >= 1, rest >= 1
        else { return nil }
        return (focus * 60, rest * 60)
    }
}

/// Resolves a spoken/typed target like "focus" or "laundry" to a timer.
public enum TimerMatcher {
    /// Exact name match wins, then prefix, then substring.
    public static func match(_ target: String, in timers: [DriftTimer]) -> DriftTimer? {
        let t = target.lowercased()
        let named = timers.compactMap { timer -> (DriftTimer, String)? in
            guard let name = timer.displayName?.lowercased() else { return nil }
            return (timer, name)
        }
        if let hit = named.first(where: { $0.1 == t }) { return hit.0 }
        if let hit = named.first(where: { $0.1.hasPrefix(t) || t.hasPrefix($0.1) }) { return hit.0 }
        if let hit = named.first(where: { $0.1.contains(t) || t.contains($0.1) }) { return hit.0 }
        return nil
    }
}
