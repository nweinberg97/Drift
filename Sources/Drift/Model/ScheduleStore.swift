import AppKit
import Combine
import DriftCore
import Foundation

/// A block being created or changed in the widget's editor.
struct BlockDraft: Equatable {
    struct Original: Equatable {
        var name: String
        var startMinute: Int
        var duration: TimeInterval
        var days: [Int]?
    }

    var id: UUID?
    var name: String
    var startMinute: Int
    var duration: TimeInterval
    var days: [Int]?
    /// Day key for a one-off block.
    var date: String
    /// What it looked like when the editor opened, to tell whether anything changed.
    var original: Original?
    /// First minute shown on the editor's timeline.
    var windowStart: Int

    var changedTime: Bool {
        guard let o = original else { return false }
        return name != o.name || startMinute != o.startMinute || duration != o.duration
    }

    var changedRepeat: Bool {
        guard let o = original else { return false }
        return days != o.days
    }
}

/// Planned time boxes, and what happens when one comes due: Drift asks, then
/// starts a timer that ends when the block ends.
@MainActor
final class ScheduleStore: ObservableObject {
    struct Prompt: Equatable {
        var blockID: UUID
        var deadline: Date
    }

    enum EntryState: Equatable {
        case upcoming, next, due, running, done, passed, skipped
    }

    struct Entry: Identifiable, Equatable {
        var occurrence: BlockOccurrence
        var block: ScheduledBlock
        var state: EntryState
        var id: UUID { block.id }
    }

    /// Ignore the prompt and the block starts by itself after this long.
    static let autoStart: TimeInterval = 60

    @Published private(set) var blocks: [ScheduledBlock] = []
    @Published var prompt: Prompt?
    /// The clock the schedule UI renders against; ticks once a second.
    @Published private(set) var now = Date()

    /// A block's time has come: chime, notify, show the widget.
    var onPrompt: (BlockOccurrence) -> Void = { _ in }

    private let timers: TimerStore
    private let settings: AppSettings
    private let fileURL: URL
    private var ticker: Timer?
    private let calendar = Calendar.current

    init(timers: TimerStore, settings: AppSettings, fileURL: URL? = nil, autoTick: Bool = true) {
        self.timers = timers
        self.settings = settings
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = support.appendingPathComponent("Drift", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("schedule.json")
        }
        load()
        if autoTick {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.tick() }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        }
    }

    // MARK: - Reading

    func block(_ id: UUID) -> ScheduledBlock? { blocks.first { $0.id == id } }

    var dayKey: String { Schedule.dayKey(now, calendar: calendar) }

    /// Today's blocks with what's happening to each, earliest first.
    func today() -> [Entry] {
        let key = dayKey
        var entries = Schedule.occurrences(blocks, on: now, calendar: calendar).compactMap { occ -> Entry? in
            guard let block = block(occ.blockID) else { return nil }
            let status = block.status[key]
            let timer = timers.timers.first { $0.blockID == block.id && $0.blockDay == key }
            let state: EntryState
            if status == .skipped { state = .skipped }
            else if let timer, !timer.isFinished { state = .running }
            else if status == .started { state = .done }
            else if now >= occ.end || status == .missed { state = .passed }
            else if now >= occ.start { state = .due }
            else { state = .upcoming }
            return Entry(occurrence: occ, block: block, state: state)
        }
        if let i = entries.firstIndex(where: { $0.state == .upcoming }) { entries[i].state = .next }
        return entries
    }

    /// The next block to come: later today, else the first one tomorrow.
    func next() -> (entry: Entry, tomorrow: Bool)? {
        if let e = today().first(where: { $0.state == .next }) { return (e, false) }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              let occ = Schedule.occurrences(blocks, on: tomorrow, calendar: calendar).first,
              let block = block(occ.blockID) else { return nil }
        return (Entry(occurrence: occ, block: block, state: .upcoming), true)
    }

    func occurrenceToday(_ id: UUID) -> BlockOccurrence? {
        block(id).flatMap { Schedule.occurrence(of: $0, on: now, calendar: calendar) }
    }

    func describeDays(_ block: ScheduledBlock) -> String {
        Schedule.describeDays(block.days, date: block.date, now: now, calendar: calendar)
    }

    // MARK: - Changing

    @discardableResult
    func add(_ spec: ScheduleSpec) -> ScheduledBlock {
        var block = ScheduledBlock(spec: spec)
        // Already under way today: don't jump at you about it.
        if let occ = Schedule.occurrence(of: block, on: now, calendar: calendar), now >= occ.start {
            block.status[occ.dayKey] = .missed
        }
        blocks.append(block)
        settings.remember(task: block.name, seconds: block.duration)
        save()
        return block
    }

    /// Starts the block's timer. It ends when the block ends, so starting
    /// late keeps the time box rather than pushing it.
    func start(_ id: UUID) {
        guard let occ = occurrenceToday(id), let i = index(id) else { return }
        if prompt?.blockID == id { prompt = nil }
        blocks[i].status[occ.dayKey] = .started
        save()
        let seconds = max(60, occ.end.timeIntervalSince(Date()))
        let timer = timers.create(seconds: seconds, name: occ.name)
        timers.attachBlock(timer.id, block: id, day: occ.dayKey)
    }

    func snooze(_ id: UUID) {
        guard let i = index(id) else { return }
        blocks[i].snoozedUntil[dayKey] = now.addingTimeInterval(5 * 60)
        if prompt?.blockID == id { prompt = nil }
        save()
    }

    func skipToday(_ id: UUID, undo: Bool = false) {
        guard let i = index(id) else { return }
        if undo { blocks[i].status[dayKey] = nil } else { blocks[i].status[dayKey] = .skipped }
        if prompt?.blockID == id { prompt = nil }
        save()
    }

    func delete(_ id: UUID) {
        blocks.removeAll { $0.id == id }
        if prompt?.blockID == id { prompt = nil }
        save()
    }

    /// Saves the editor. For a repeating block, `todayOnly` changes just today.
    func save(_ draft: BlockDraft, todayOnly: Bool) {
        var name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Focus" }
        name = name.prefix(1).uppercased() + name.dropFirst()
        let key = dayKey

        guard let id = draft.id, let i = index(id) else {
            let spec = ScheduleSpec(name: name, startMinute: draft.startMinute, duration: draft.duration,
                                    days: draft.days, date: draft.days == nil ? draft.date : nil,
                                    whenRanges: [], lengthRanges: [])
            add(spec)
            return
        }

        if todayOnly {
            blocks[i].overrides[key] = .init(name: name, startMinute: draft.startMinute, duration: draft.duration)
        } else {
            blocks[i].name = name
            blocks[i].startMinute = draft.startMinute
            blocks[i].duration = draft.duration
            blocks[i].days = draft.days.map { Array(Set($0)).sorted() }
            blocks[i].date = draft.days == nil ? draft.date : nil
            blocks[i].overrides[key] = nil
        }
        // Moved later than now: it can come due again today.
        if let occ = occurrenceToday(id) {
            if blocks[i].status[key] == .missed, now < occ.start { blocks[i].status[key] = nil }
            // A running block follows the change.
            if let t = timers.timers.first(where: { $0.blockID == id && $0.blockDay == key && !$0.isFinished }) {
                timers.setRemaining(t.id, seconds: max(60, occ.end.timeIntervalSince(Date())))
                timers.rename(t.id, to: occ.name)
            }
        }
        save()
    }

    /// Snapshots and tests.
    func replaceAll(_ newBlocks: [ScheduledBlock], prompt: Prompt? = nil) {
        blocks = newBlocks
        self.prompt = prompt
        now = Date()
    }

    // MARK: - Clock

    func tick() {
        now = Date()
        let key = dayKey
        if let p = prompt, block(p.blockID) == nil { prompt = nil }
        var changed = false
        for entry in today() where entry.state == .due && entry.block.status[key] == nil {
            let id = entry.block.id
            if let p = prompt, p.blockID == id {
                if now >= p.deadline { start(id) }
                continue
            }
            if prompt != nil { continue }
            if let until = entry.block.snoozedUntil[key], now < until { continue }
            // Nearly over: let it pass quietly.
            if now >= entry.occurrence.end.addingTimeInterval(-60), let i = index(id) {
                blocks[i].status[key] = .missed
                changed = true
                continue
            }
            prompt = Prompt(blockID: id, deadline: now.addingTimeInterval(Self.autoStart))
            onPrompt(entry.occurrence)
        }
        if changed { save() }
    }

    // MARK: - Persistence

    private func index(_ id: UUID) -> Int? { blocks.firstIndex { $0.id == id } }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([ScheduledBlock].self, from: data) else { return }
        blocks = stored
        prune()
    }

    private func save() {
        prune()
        if let data = try? JSONEncoder().encode(blocks) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Drops one-off blocks from past days and per-day notes older than a week.
    private func prune() {
        let today = Schedule.dayKey(Date(), calendar: calendar)
        let weekAgo = Schedule.dayKey(Date().addingTimeInterval(-7 * 86_400), calendar: calendar)
        blocks.removeAll { $0.days == nil && ($0.date ?? "") < today }
        for i in blocks.indices {
            blocks[i].status = blocks[i].status.filter { $0.key >= weekAgo }
            blocks[i].snoozedUntil = blocks[i].snoozedUntil.filter { $0.key >= today }
            blocks[i].overrides = blocks[i].overrides.filter { $0.key >= today }
        }
    }
}
