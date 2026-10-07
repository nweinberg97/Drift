import Foundation

/// An optional focus/break cycle attached to a timer. When a phase finishes,
/// the timer rolls into the next phase instead of stopping.
public struct PomodoroCycle: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case focus
        case rest
    }

    public var focus: TimeInterval
    public var rest: TimeInterval
    public var phase: Phase
    public var round: Int

    public init(focus: TimeInterval = 25 * 60, rest: TimeInterval = 5 * 60, phase: Phase = .focus, round: Int = 1) {
        self.focus = focus
        self.rest = rest
        self.phase = phase
        self.round = round
    }

    public var currentDuration: TimeInterval { phase == .focus ? focus : rest }
    public var phaseName: String { phase == .focus ? "Focus" : "Break" }

    public func advanced() -> PomodoroCycle {
        var next = self
        switch phase {
        case .focus:
            next.phase = .rest
        case .rest:
            next.phase = .focus
            next.round += 1
        }
        return next
    }
}

/// A single countdown. All timing is derived from wall-clock timestamps
/// (`endDate - now`), never from counting ticks, so timers stay exact across
/// sleep, app restarts, and UI stalls.
public struct DriftTimer: Codable, Identifiable, Equatable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        /// Created but never started. Remaining time equals `duration`.
        case idle
        /// Counting down toward `endDate`.
        case running(endDate: Date)
        /// Frozen with `remaining` seconds left.
        case paused(remaining: TimeInterval)
        /// Reached zero at `at`.
        case finished(at: Date)
    }

    /// The smallest remaining time an adjustment may leave on a timer.
    public static let minimumRemaining: TimeInterval = 1

    public let id: UUID
    public var name: String?
    /// Total length of the current run. Used for progress and for
    /// "25 minutes complete" copy.
    public var duration: TimeInterval
    public var state: State
    public var createdAt: Date
    public var startedAt: Date?
    public var pomodoro: PomodoroCycle?

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        duration: TimeInterval,
        state: State = .idle,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        pomodoro: PomodoroCycle? = nil
    ) {
        self.id = id
        self.name = name
        self.duration = max(duration, DriftTimer.minimumRemaining)
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.pomodoro = pomodoro
    }

    // MARK: - Derived

    public var displayName: String? {
        if let pomodoro { return pomodoro.phaseName }
        return name
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    public var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    public var isIdle: Bool { state == .idle }

    /// Running or paused — something the user is still waiting on.
    public var isActive: Bool { isRunning || isPaused }

    public var endDate: Date? {
        if case let .running(endDate) = state { return endDate }
        return nil
    }

    public var finishedAt: Date? {
        if case let .finished(at) = state { return at }
        return nil
    }

    public func remaining(at now: Date) -> TimeInterval {
        switch state {
        case .idle:
            return duration
        case let .running(endDate):
            return max(0, endDate.timeIntervalSince(now))
        case let .paused(remaining):
            return max(0, remaining)
        case .finished:
            return 0
        }
    }

    /// 0 at start, 1 when done.
    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        let p = 1 - remaining(at: now) / duration
        return min(1, max(0, p))
    }

    public func shouldFinish(at now: Date) -> Bool {
        if case let .running(endDate) = state { return endDate <= now }
        return false
    }

    // MARK: - Transitions

    /// Starts an idle timer, resumes a paused one, or restarts a finished one.
    public mutating func start(at now: Date) {
        switch state {
        case .idle:
            state = .running(endDate: now.addingTimeInterval(duration))
            startedAt = now
        case let .paused(remaining):
            state = .running(endDate: now.addingTimeInterval(max(remaining, DriftTimer.minimumRemaining)))
        case .finished:
            if let pomodoro { duration = pomodoro.currentDuration }
            state = .running(endDate: now.addingTimeInterval(duration))
            startedAt = now
        case .running:
            break
        }
    }

    public mutating func pause(at now: Date) {
        guard case .running = state else { return }
        state = .paused(remaining: max(remaining(at: now), DriftTimer.minimumRemaining))
    }

    public mutating func toggle(at now: Date) {
        if isRunning { pause(at: now) } else { start(at: now) }
    }

    /// Marks the timer finished. `at` defaults to the scheduled end so a timer
    /// that ended while the Mac slept reports its true finish time.
    public mutating func finish(at now: Date) {
        let finishedAt = endDate.map { min($0, now) } ?? now
        state = .finished(at: finishedAt)
    }

    /// Adds (or with a negative delta, removes) time.
    /// Returns `false` and leaves the timer unchanged if the result would drop
    /// below one second. Adding time to a finished timer starts it again for
    /// exactly `delta` — a snooze.
    @discardableResult
    public mutating func adjust(by delta: TimeInterval, at now: Date) -> Bool {
        switch state {
        case .idle:
            let next = duration + delta
            guard next >= DriftTimer.minimumRemaining else { return false }
            duration = next
        case let .running(endDate):
            let next = endDate.timeIntervalSince(now) + delta
            guard next >= DriftTimer.minimumRemaining else { return false }
            state = .running(endDate: endDate.addingTimeInterval(delta))
            duration = max(duration + delta, next)
        case let .paused(remaining):
            let next = remaining + delta
            guard next >= DriftTimer.minimumRemaining else { return false }
            state = .paused(remaining: next)
            duration = max(duration + delta, next)
        case .finished:
            guard delta >= DriftTimer.minimumRemaining else { return false }
            duration = delta
            state = .running(endDate: now.addingTimeInterval(delta))
            startedAt = now
        }
        return true
    }

    /// Replaces the remaining time (the "edit" action). Preserves running vs.
    /// paused; a finished or idle timer starts running.
    public mutating func setRemaining(_ seconds: TimeInterval, at now: Date) {
        let value = max(seconds, DriftTimer.minimumRemaining)
        duration = value
        switch state {
        case .paused:
            state = .paused(remaining: value)
        case .running, .idle, .finished:
            state = .running(endDate: now.addingTimeInterval(value))
            startedAt = now
        }
    }

    /// For Pomodoro timers: move into the next phase, starting at `from`.
    public mutating func advancePomodoro(from start: Date) {
        guard let cycle = pomodoro else { return }
        let next = cycle.advanced()
        pomodoro = next
        duration = next.currentDuration
        state = .running(endDate: start.addingTimeInterval(next.currentDuration))
        startedAt = start
    }

    /// A fresh, running copy with the same name and length.
    public func duplicated(at now: Date) -> DriftTimer {
        var copy = DriftTimer(name: name, duration: duration, createdAt: now, pomodoro: pomodoro.map {
            PomodoroCycle(focus: $0.focus, rest: $0.rest)
        })
        if let cycle = copy.pomodoro { copy.duration = cycle.currentDuration }
        copy.start(at: now)
        return copy
    }
}
