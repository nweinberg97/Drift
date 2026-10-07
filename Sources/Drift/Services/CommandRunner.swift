import DriftCore
import Foundation

/// Executes parsed commands against the store. Shared by the composer, voice,
/// and `drift://` URLs so they all behave identically.
@MainActor
final class CommandRunner {
    struct Preview: Equatable {
        var title: String
        var detail: String?
        var isValid: Bool
    }

    enum Outcome: Equatable {
        case done
        case failed(String)
    }

    private let store: TimerStore
    private let settings: AppSettings
    var showWidget: () -> Void = {}
    var revealTimers: () -> Void = {}
    var hideWidget: () -> Void = {}

    init(store: TimerStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    /// What pressing Return would do — shown live under the composer's field.
    func preview(_ text: String) -> Preview {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Preview(title: "Start \(TimeFormatter.clock(settings.defaultDuration))", detail: nil, isValid: true)
        }
        guard let command = CommandParser.parse(trimmed) else {
            return Preview(title: "Try 25, 1:30, 90s, 2h 15m, or 45m writing", detail: nil, isValid: false)
        }
        return preview(command)
    }

    func preview(_ command: DriftCommand) -> Preview {
        switch command {
        case let .start(seconds, name):
            return Preview(title: "Start \(TimeFormatter.clock(seconds))", detail: name, isValid: true)
        case let .pomodoro(focus, rest):
            return Preview(title: "Pomodoro", detail: "\(TimeFormatter.compact(focus)) focus · \(TimeFormatter.compact(rest)) break", isValid: true)
        case let .pause(target):
            return targetPreview("Pause", target) { $0.isRunning }
        case let .resume(target):
            return targetPreview("Resume", target) { $0.isPaused || $0.isFinished }
        case let .cancel(target):
            return targetPreview("Cancel", target) { _ in true }
        case let .adjust(delta, target):
            let verb = delta >= 0 ? "Add \(TimeFormatter.compact(delta))" : "Remove \(TimeFormatter.compact(-delta))"
            return targetPreview(verb, target) { !$0.isIdle }
        case .show:
            return Preview(title: "Show timers", detail: nil, isValid: true)
        case .hide:
            return Preview(title: "Hide widget", detail: nil, isValid: true)
        }
    }

    private func targetPreview(_ verb: String, _ target: String?, where eligible: (DriftTimer) -> Bool) -> Preview {
        if let target {
            guard let t = TimerMatcher.match(target, in: store.timers) else {
                return Preview(title: "No timer called “\(target)”", detail: nil, isValid: false)
            }
            return Preview(title: verb, detail: t.displayName, isValid: true)
        }
        guard let t = resolve(nil, eligible) else {
            return Preview(title: "No timer to \(verb.lowercased())", detail: nil, isValid: false)
        }
        return Preview(title: verb, detail: t.displayName ?? TimeFormatter.clock(t.remaining(at: Date())), isValid: true)
    }

    /// Runs `text` (empty means "start the default timer").
    @discardableResult
    func run(_ text: String) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.create(seconds: settings.defaultDuration)
            showWidget()
            return .done
        }
        guard let command = CommandParser.parse(trimmed) else {
            return .failed("Didn't recognise a duration. Try “25 minutes”.")
        }
        return run(command)
    }

    @discardableResult
    func run(_ command: DriftCommand) -> Outcome {
        switch command {
        case let .start(seconds, name):
            store.create(seconds: seconds, name: name)
            showWidget()
        case let .pomodoro(focus, rest):
            store.startPomodoro(focus: focus, rest: rest)
            showWidget()
        case let .pause(target):
            guard let t = resolve(target, { $0.isRunning }) else { return missing(target) }
            store.pause(t.id)
        case let .resume(target):
            guard let t = resolve(target, { $0.isPaused || $0.isFinished }) else { return missing(target) }
            store.resume(t.id)
        case let .cancel(target):
            guard let t = resolve(target, { _ in true }) else { return missing(target) }
            store.remove(t.id)
        case let .adjust(delta, target):
            guard let t = resolve(target, { !$0.isIdle }) else { return missing(target) }
            if !store.adjust(t.id, by: delta) {
                return .failed("Not enough time left to remove \(TimeFormatter.compact(-delta)).")
            }
        case .show:
            revealTimers()
        case .hide:
            hideWidget()
        }
        return .done
    }

    /// A named target, or — when none is given — the primary timer if it
    /// qualifies, else the first timer that does.
    private func resolve(_ target: String?, _ eligible: (DriftTimer) -> Bool) -> DriftTimer? {
        if let target { return TimerMatcher.match(target, in: store.timers) }
        if let primary = store.primary, eligible(primary) { return primary }
        return store.timers.first(where: eligible)
    }

    private func missing(_ target: String?) -> Outcome {
        if let target { return .failed("No timer called “\(target)”.") }
        return .failed("No timer to change.")
    }
}
