import AppKit
import Combine
import DriftCore
import Foundation

@MainActor
protocol TimerStoreDelegate: AnyObject {
    /// A timer reached zero. `late` is true when it ended well before Drift
    /// noticed (the Mac was asleep, or Drift wasn't running) — in that case
    /// we stay silent rather than chime about something long past.
    func timerStore(_ store: TimerStore, didFinish timer: DriftTimer, late: Bool)
    /// A timer was created by the user.
    func timerStore(_ store: TimerStore, didStart timer: DriftTimer)
    /// Running timers or their end times changed (start, pause, adjust,
    /// cancel…). Notifications and focus sound resync on this.
    func timerStoreScheduleDidChange(_ store: TimerStore)
}

/// Owns every timer. All timing is timestamp-based (see `DriftTimer`), so the
/// store only needs to wake up when something visible changes.
@MainActor
final class TimerStore: ObservableObject {
    @Published private(set) var timers: [DriftTimer] = []
    /// The clock the UI renders against. Updated once per visible second.
    @Published private(set) var now = Date()
    @Published private(set) var primaryID: UUID?

    weak var delegate: TimerStoreDelegate?

    private let settings: AppSettings
    private var ticker: Timer?
    private let fileURL: URL
    private var observers: [NSObjectProtocol] = []

    init(settings: AppSettings) {
        self.settings = settings
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Drift", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("timers.json")
        load()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        })
    }

    // MARK: - Derived

    /// The timer the widget features: the user's explicit pick if it's still
    /// around, else the most recently started running timer, else whatever
    /// is left.
    var primary: DriftTimer? {
        if let id = primaryID, let t = timers.first(where: { $0.id == id }) { return t }
        return timers.filter(\.isRunning).max(by: { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) })
            ?? timers.first(where: \.isPaused)
            ?? timers.last
    }

    /// Everything except the primary, soonest-ending first.
    var others: [DriftTimer] {
        let primaryID = primary?.id
        return timers
            .filter { $0.id != primaryID }
            .sorted { lhs, rhs in
                let l = sortKey(lhs), r = sortKey(rhs)
                return l.0 != r.0 ? l.0 < r.0 : l.1 < r.1
            }
    }

    private func sortKey(_ t: DriftTimer) -> (Int, TimeInterval) {
        if t.isFinished { return (0, -(t.finishedAt?.timeIntervalSinceReferenceDate ?? 0)) }
        if t.isRunning { return (1, t.remaining(at: now)) }
        return (2, t.remaining(at: now))
    }

    var hasRunning: Bool { timers.contains(where: \.isRunning) }

    func timer(_ id: UUID) -> DriftTimer? { timers.first { $0.id == id } }

    // MARK: - Commands

    @discardableResult
    func create(seconds: TimeInterval, name: String? = nil, pomodoro: PomodoroCycle? = nil) -> DriftTimer {
        let current = Date()
        var timer = DriftTimer(name: name, duration: pomodoro?.currentDuration ?? seconds, createdAt: current, pomodoro: pomodoro)
        timer.start(at: current)
        timers.append(timer)
        primaryID = timer.id
        delegate?.timerStore(self, didStart: timer)
        commit()
        return timer
    }

    func startPomodoro(focus: TimeInterval, rest: TimeInterval) {
        create(seconds: focus, pomodoro: PomodoroCycle(focus: focus, rest: rest))
    }

    func toggle(_ id: UUID) { mutate(id) { $0.toggle(at: Date()) } }
    func pause(_ id: UUID) { mutate(id) { $0.pause(at: Date()) } }
    func resume(_ id: UUID) { mutate(id) { $0.start(at: Date()) } }

    @discardableResult
    func adjust(_ id: UUID, by delta: TimeInterval) -> Bool {
        var ok = false
        mutate(id) { ok = $0.adjust(by: delta, at: Date()) }
        return ok
    }

    func setRemaining(_ id: UUID, seconds: TimeInterval) {
        mutate(id) { $0.setRemaining(seconds, at: Date()) }
    }

    func rename(_ id: UUID, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(id) { $0.name = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    func duplicate(_ id: UUID) {
        guard let t = timer(id) else { return }
        let copy = t.duplicated(at: Date())
        timers.append(copy)
        delegate?.timerStore(self, didStart: copy)
        commit()
    }

    /// Cancel, delete and dismiss are the same gesture: the timer goes away.
    func remove(_ id: UUID) {
        timers.removeAll { $0.id == id }
        if primaryID == id { primaryID = nil }
        commit()
    }

    func removeAllFinished() {
        timers.removeAll(where: \.isFinished)
        commit()
    }

    func makePrimary(_ id: UUID) {
        primaryID = id
    }

    // MARK: - Ticking

    /// Re-evaluates the clock: completes due timers, expires finished ones,
    /// and schedules the next wake-up.
    func tick() {
        let current = Date()
        now = current
        var changed = false
        var finished: [(DriftTimer, Bool)] = []

        for index in timers.indices where timers[index].shouldFinish(at: current) {
            let end = timers[index].endDate ?? current
            let late = current.timeIntervalSince(end) > 60
            if timers[index].pomodoro != nil {
                finished.append((timers[index], late))
                // Roll into the next phase from now, so a long sleep doesn't
                // leave a half-elapsed break behind.
                timers[index].advancePomodoro(from: late ? current : end)
            } else {
                timers[index].finish(at: current)
                finished.append((timers[index], late))
            }
            changed = true
        }

        if let retention = settings.finishedRetention.interval {
            let before = timers.count
            timers.removeAll { t in
                guard let at = t.finishedAt else { return false }
                return current.timeIntervalSince(at) >= retention
            }
            if timers.count != before { changed = true }
        }

        if changed { commit(scheduleOnly: false) }
        for (timer, late) in finished {
            delegate?.timerStore(self, didFinish: timer, late: late)
        }
        scheduleNextTick()
    }

    /// Wakes exactly when the primary display would change, or when any timer
    /// ends — never on a busy 10 Hz loop.
    private func scheduleNextTick() {
        ticker?.invalidate()
        ticker = nil
        let current = Date()
        var delays: [TimeInterval] = []

        for t in timers {
            if let end = t.endDate {
                let remaining = end.timeIntervalSince(current)
                delays.append(remaining)
                // Next whole-second boundary of this timer's countdown.
                let fraction = remaining - remaining.rounded(.down)
                delays.append(fraction > 0.001 ? fraction : 1)
            }
            if let at = t.finishedAt, let retention = settings.finishedRetention.interval {
                delays.append(at.addingTimeInterval(retention).timeIntervalSince(current))
            }
        }
        guard let next = delays.filter({ $0 > -1 }).min() else { return }

        let timer = Timer(timeInterval: max(0.02, next + 0.005), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.02
        // .common so the clock keeps moving while menus are open.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    // MARK: - Persistence

    private func mutate(_ id: UUID, _ body: (inout DriftTimer) -> Void) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        body(&timers[index])
        commit()
    }

    private func commit(scheduleOnly: Bool = false) {
        now = Date()
        save()
        delegate?.timerStoreScheduleDidChange(self)
        if !scheduleOnly { scheduleNextTick() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([DriftTimer].self, from: data)
        else { return }
        timers = saved
        // Anything that ended while Drift wasn't running is finished, quietly.
        let current = Date()
        for index in timers.indices where timers[index].shouldFinish(at: current) {
            if timers[index].pomodoro != nil {
                timers[index].advancePomodoro(from: current)
            } else {
                timers[index].finish(at: current)
            }
        }
        scheduleNextTick()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(timers)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Drift: failed to save timers: \(error.localizedDescription)")
        }
    }
}
