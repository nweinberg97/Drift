import Foundation

/// All of Drift's time formatting in one place.
public enum TimeFormatter {
    /// Whole seconds as a countdown shows them. Rounds *up*, so a fresh 25m
    /// timer reads 25:00 and the display hits 0:00 exactly at the end.
    public static func countdownSeconds(_ interval: TimeInterval) -> Int {
        guard interval > 0, interval.isFinite else { return 0 }
        return Int((interval - 0.0005).rounded(.up))
    }

    /// The widget's primary display.
    ///   7:32       under an hour
    ///   1:42:18    under a day
    ///   27h 14m    under three days
    ///   4d 6h      beyond that
    public static func clock(_ interval: TimeInterval) -> String {
        let total = countdownSeconds(interval)
        let days = total / 86_400
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        if total < 3_600 {
            return "\(minutes):\(twoDigits(seconds))"
        } else if total < 86_400 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds))"
        } else if total < 3 * 86_400 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(days)d \(hours % 24)h"
        }
    }

    /// Short form for chips and menus: "25m", "1h 30m", "90s" → "1m 30s", "3d".
    public static func compact(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let parts = components(total)
        var out: [String] = []
        if parts.days > 0 { out.append("\(parts.days)d") }
        if parts.hours > 0 { out.append("\(parts.hours)h") }
        if parts.minutes > 0 { out.append("\(parts.minutes)m") }
        if parts.seconds > 0 { out.append("\(parts.seconds)s") }
        return out.isEmpty ? "0s" : out.joined(separator: " ")
    }

    /// Full words for notifications and VoiceOver: "1 hour 30 minutes".
    public static func spoken(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let parts = components(total)
        var out: [String] = []
        if parts.days > 0 { out.append(plural(parts.days, "day")) }
        if parts.hours > 0 { out.append(plural(parts.hours, "hour")) }
        if parts.minutes > 0 { out.append(plural(parts.minutes, "minute")) }
        if parts.seconds > 0 { out.append(plural(parts.seconds, "second")) }
        return out.isEmpty ? "0 seconds" : out.joined(separator: " ")
    }

    // MARK: - Helpers

    private static func components(_ total: Int) -> (days: Int, hours: Int, minutes: Int, seconds: Int) {
        (total / 86_400, (total % 86_400) / 3_600, (total % 3_600) / 60, total % 60)
    }

    private static func plural(_ n: Int, _ unit: String) -> String {
        n == 1 ? "1 \(unit)" : "\(n) \(unit)s"
    }

    private static func twoDigits(_ n: Int) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }
}
