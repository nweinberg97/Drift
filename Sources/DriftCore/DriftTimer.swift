import Foundation

/// An optional focus/break cycle attached to a timer. When a phase finishes,
/// the timer rolls into the next phase instead of stopping:
///
///   Focus → Break → Focus → Break → Focus → Break → Focus → Long break → …
public struct PomodoroCycle: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case focus
        case rest
        case longRest
    }

    public var focus: TimeInterval
    public var rest: TimeInterval
    /// Longer break taken after every `roundsPerSet` focus sessions.
    public var longRest: TimeInterval
    /// Focus sessions per set. 0 turns long breaks off.
    public var roundsPerSet: Int
    public var phase: Phase
    /// 1-based focus session number, counting up forever.
    public var round: Int

    public init(
        focus: TimeInterval = 25 * 60,
        rest: TimeInterval = 5 * 60,
        longRest: TimeInterval = 15 * 60,
        roundsPerSet: Int = 4,
        phase: Phase = .focus,
        round: Int = 1
    ) {
        self.focus = focus
        self.rest = rest
        self.longRest = longRest
        self.roundsPerSet = roundsPerSet
        self.phase = phase
        self.round = round
    }

    /// Timers saved by earlier versions have no long-break fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focus = try c.decode(TimeInterval.self, forKey: .focus)
        rest = try c.decode(TimeInterval.self, forKey: .rest)
        longRest = try c.decodeIfPresent(TimeInterval.self, forKey: .longRest) ?? 15 * 60
        roundsPerSet = try c.decodeIfPresent(Int.self, forKey: .roundsPerSet) ?? 4
        phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .focus
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 1
    }

    public var isBreak: Bool { phase != .focus }

    public var currentDuration: TimeInterval { duration(of: phase) }

    public func duration(of phase: Phase) -> TimeInterval {
        switch phase {
        case .focus: return focus
        case .rest: return rest
        case .longRest: return longRest
        }
    }

    public static func name(of phase: Phase) -> String {
        switch phase {
        case .focus: return "Focus"
        case .rest: return "Break"
        case .longRest: return "Long break"
        }
    }

    public var phaseName: String { Self.name(of: phase) }

    /// Position within the current set, 1…roundsPerSet.
    public var roundInSet: Int {
        guard roundsPerSet > 0 else { return round }
        return (round - 1) % roundsPerSet + 1
    }

    public func advanced() -> PomodoroCycle {
        var next = self
        switch phase {
        case .focus:
            let setDone = roundsPerSet > 0 && round % roundsPerSet == 0
            next.phase = setDone ? .longRest : .rest
        case .rest, .longRest:
            next.phase = .focus
            next.round += 1
        }
        return next
    }

    /// What comes after the current phase, for "Break next · 5 min".
    public var upNext: (name: String, duration: TimeInterval) {
        let next = advanced()
        return (next.phaseName, next.currentDuration)
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
    /// Set when the timer was started by a scheduled block, with that day's key.
    public var blockID: UUID?
    public var blockDay: String?
    /// A session: time blocks that run back to back. `name` is the session's name.
    public var steps: [TimeBlock]?
    public var stepIndex: Int?
    /// Between time blocks: the next one starts by itself at this moment
    /// (`distantFuture` means when you press Start).
    public var waitUntil: Date?
    /// The time block that just ended, for "Inbox done".
    public var handoff: String?
    /// Extra time added to a single timer so far (for the grace period).
    public var extraUsed: TimeInterval?

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
        if let block = currentBlock { return block.name }
        return name
    }

    // MARK: - Sessions

    public var isSession: Bool { (steps?.count ?? 0) > 1 }
    public var step: Int { stepIndex ?? 0 }

    public var currentBlock: TimeBlock? {
        guard let steps, steps.indices.contains(step) else { return nil }
        return steps[step]
    }

    public var nextBlock: TimeBlock? {
        guard let steps, steps.indices.contains(step + 1) else { return nil }
        return steps[step + 1]
    }

    /// Waiting between time blocks.
    public var isWaiting: Bool { waitUntil != nil }

    public var sessionTotal: TimeInterval { (steps ?? []).reduce(0) { $0 + $1.seconds } }

    /// Extra time already added to this timer, or to the current time block.
    public var extraSoFar: TimeInterval {
        if let block = currentBlock { return block.extra }
        return extraUsed ?? 0
    }

    public mutating func recordExtra(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        if var s = steps, s.indices.contains(step) {
            s[step].extra += seconds
            steps = s
        } else {
            extraUsed = (extraUsed ?? 0) + seconds
        }
    }

    /// Sets the total extra for the current timer or block (the dial works this way).
    public mutating func setExtra(_ seconds: TimeInterval) {
        if var s = steps, s.indices.contains(step) {
            s[step].extra = max(0, seconds)
            steps = s
        } else {
            extraUsed = max(0, seconds)
        }
    }

    /// Moves a session on to its next time block. Returns false on the last one.
    /// `fromEnd`: the block ran out. With a `delay`, the next block waits that
    /// long (a hand-off card shows); `.infinity` waits for Start.
    @discardableResult
    public mutating func advanceStep(at now: Date, fromEnd: Bool, delay: TimeInterval = 0) -> Bool {
        guard let steps, steps.indices.contains(step + 1) else { return false }
        let finishedName = steps[step].name
        stepIndex = step + 1
        let next = steps[step]
        duration = next.seconds
        startedAt = now
        if fromEnd && delay > 0 {
            state = .paused(remaining: next.seconds)
            waitUntil = delay.isInfinite ? .distantFuture : now.addingTimeInterval(delay)
            handoff = finishedName
        } else {
            waitUntil = nil
            handoff = nil
            if !fromEnd, isPaused {
                state = .paused(remaining: next.seconds)
            } else {
                state = .running(endDate: now.addingTimeInterval(next.seconds))
            }
        }
        return true
    }

    /// Starts the waiting time block now.
    public mutating func startWaiting(at now: Date) {
        guard waitUntil != nil else { return }
        waitUntil = nil
        handoff = nil
        let left = remaining(at: now)
        state = .running(endDate: now.addingTimeInterval(max(left, DriftTimer.minimumRemaining)))
        startedAt = now
    }

    public func waitIsOver(at now: Date) -> Bool {
        guard let waitUntil else { return false }
        return waitUntil <= now
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
            waitUntil = nil
            handoff = nil
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
        if var s = steps, s.indices.contains(step) {
            s[step].seconds = value
            steps = s
        }
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
            PomodoroCycle(focus: $0.focus, rest: $0.rest, longRest: $0.longRest, roundsPerSet: $0.roundsPerSet)
        })
        if let cycle = copy.pomodoro { copy.duration = cycle.currentDuration }
        copy.start(at: now)
        return copy
    }
}
