import AppKit
import DriftCore
import SwiftUI

// MARK: - Idle (no timers)

/// Nothing running: a clear Start, a few one-tap lengths, and the launcher one
/// click away. No frozen 25:00 to fiddle with.
struct IdleRow: View {
    @ObservedObject var store: TimerStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: WidgetUIState
    @ObservedObject var schedule: ScheduleStore
    let scale: CGFloat
    let actions: WidgetActions

    private var hasPlan: Bool { settings.featurePlan && !schedule.blocks.isEmpty }

    var body: some View {
        let def = settings.defaultDuration
        let quick = Array([600.0, 900, 1_500, 2_700, 3_600].filter { $0 != def }.prefix(4))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8 * scale) {
                Circle()
                    .strokeBorder(Theme.tertiaryText, lineWidth: 1.25)
                    .frame(width: 7 * scale, height: 7 * scale)
                    .frame(width: 11 * scale, height: 11 * scale)
                Button { actions.openComposer() } label: {
                    Text("What are you working on?")
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                }
                .buttonStyle(EditableTextStyle(active: false))
                .help("Write the task and how long")
                .accessibilityLabel("New timer: write what you're working on")
                Spacer(minLength: 4)
                if hasPlan {
                    Button { ui.expanded.toggle() } label: {
                        Image(systemName: ui.expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10 * scale, weight: .bold))
                    }
                    .buttonStyle(ExpandButtonStyle(scale: scale, highlighted: !ui.expanded))
                    .help(ui.expanded ? "Collapse" : "Today's plan")
                    .accessibilityLabel(ui.expanded ? "Collapse" : "Show today's plan")
                } else if let shortcut = settings.shortcuts[.newTimer] {
                    KeyCaps(text: shortcut.display)
                }
            }
            .padding(.leading, 13 * scale)
            .padding(.trailing, 8 * scale)
            .padding(.top, 9 * scale)
            .padding(.bottom, 5 * scale)

            HStack(spacing: 4 * scale) {
                Button { store.create(seconds: def) } label: {
                    HStack(spacing: 6 * scale) {
                        Image(systemName: "play.fill").font(.system(size: 9 * scale, weight: .bold))
                        Text("Start \(TimeFormatter.compact(def))")
                    }
                }
                .buttonStyle(StartChipStyle(scale: scale, prominent: true))
                .help("Start a \(TimeFormatter.compact(def)) timer now")
                .accessibilityLabel("Start \(TimeFormatter.spoken(def))")
                ForEach(quick, id: \.self) { seconds in
                    Button(TimeFormatter.compact(seconds)) { store.create(seconds: seconds) }
                        .buttonStyle(StartChipStyle(scale: scale))
                        .help("Start \(TimeFormatter.compact(seconds)) now")
                        .accessibilityLabel("Start \(TimeFormatter.spoken(seconds))")
                }
                Menu {
                    ForEach(settings.presets, id: \.self) { seconds in
                        Button("Start \(TimeFormatter.compact(seconds))") { store.create(seconds: seconds) }
                    }
                    Divider()
                    Button("Other length or task…") { actions.openComposer() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 28 * scale, height: 28 * scale)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
                .help("Any length")
                .accessibilityLabel("More lengths")
            }
            .padding(.horizontal, 8 * scale)
            .padding(.bottom, 9 * scale)

            if hasPlan, !ui.expanded, ui.confirmation == nil, let next = schedule.next() {
                NextBlockLine(entry: next.entry, tomorrow: next.tomorrow, ui: ui, schedule: schedule, actions: actions, scale: scale)
                    .padding(.leading, -20 * scale)
                    .padding(.top, -2)
            }
        }
    }
}

/// A one-tap length in the idle widget.
struct StartChipStyle: ButtonStyle {
    let scale: CGFloat
    var prominent = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * scale, weight: .semibold).monospacedDigit())
            .foregroundStyle(prominent ? Color.white : Theme.primaryText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, (prominent ? 12 : 6) * scale)
            .frame(maxWidth: prominent ? nil : .infinity)
            .frame(height: 28 * scale)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Theme.accent : (configuration.isPressed || hovering ? Theme.controlHover : Theme.control))
            )
            .brightness(prominent && hovering ? 0.05 : 0)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Time's up

/// What finished, with one big button. Replaces the small ×.
struct TimesUpCard: View {
    let timer: DriftTimer
    @ObservedObject var store: TimerStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: WidgetUIState
    @ObservedObject var schedule: ScheduleStore
    let scale: CGFloat
    let actions: WidgetActions

    private var name: String { timer.name ?? "\(TimeFormatter.compact(timer.duration)) timer" }

    private var detail: String {
        var s = timer.isSession
            ? "\(timer.steps?.count ?? 0) time blocks · \(TimeFormatter.spoken(timer.sessionTotal))"
            : "\(TimeFormatter.spoken(timer.duration)) complete"
        if settings.featurePlan, let next = schedule.next(), !next.tomorrow, next.entry.state == .next,
           next.entry.occurrence.start.timeIntervalSince(schedule.now) < 3_600 {
            s += " · Next: \(next.entry.occurrence.name) at \(Schedule.time(next.entry.occurrence.startMinute))"
        }
        return s
    }

    var body: some View {
        let room = store.extraLeft(timer)
        let canAdd = !timer.isSession || settings.extraInSessions
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                Text(timer.isSession ? "SESSION COMPLETE" : "TIME’S UP")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.4)
                Spacer(minLength: 6)
                if let at = timer.finishedAt {
                    Text(at, style: .time)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                }
                Button { actions.acknowledge(); ui.expanded.toggle() } label: {
                    Image(systemName: ui.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10 * scale, weight: .bold))
                }
                .buttonStyle(ExpandButtonStyle(scale: scale, highlighted: false))
                .help(ui.expanded ? "Collapse" : "Show all timers")
                .accessibilityLabel(ui.expanded ? "Collapse" : "Show all timers")
            }
            .foregroundStyle(Theme.accent)

            Text(name)
                .font(.system(size: 17 * scale, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .padding(.top, 3)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            HStack(spacing: 6) {
                Button { actions.acknowledge(); store.remove(timer.id) } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(CardButtonStyle(scale: scale, prominent: true))
                .help("Clear it")
                if canAdd {
                    Button(room.isInfinite || room >= 300 ? "+5 min" : "+\(TimeFormatter.compact(max(60, room)))") {
                        actions.acknowledge()
                        store.adjust(timer.id, by: 300)
                    }
                    .buttonStyle(CardButtonStyle(scale: scale))
                    .disabled(room < 1)
                    .help(room < 1 ? "Grace period used" : "A little more time")
                }
                Button(timer.isSession ? "Run again" : "Restart") {
                    actions.acknowledge()
                    if timer.isSession, let steps = timer.steps {
                        let name = timer.name
                        store.remove(timer.id)
                        store.startSession(name: name, steps: steps, remember: false)
                    } else {
                        store.resume(timer.id)
                    }
                }
                .buttonStyle(CardButtonStyle(scale: scale))
            }
            .padding(.top, 11)
        }
        .padding(.leading, 13 * scale)
        .padding(.trailing, 8 * scale)
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(timer.isSession ? "Session complete" : "Time's up"): \(name)")
    }
}

struct CardButtonStyle: ButtonStyle {
    let scale: CGFloat
    var prominent = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5 * min(scale, 1.15), weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Theme.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30 * min(scale, 1.15))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Theme.accent : (configuration.isPressed || hovering ? Theme.controlHover : Theme.control))
            )
            .brightness(prominent && hovering ? 0.05 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Sessions

/// Between time blocks: "✓ Inbox done · Next: Plan the day, 10m · starts in 8s".
struct HandoffCard: View {
    let timer: DriftTimer
    @ObservedObject var store: TimerStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = timer.waitUntil ?? .distantFuture
            let manual = wait == .distantFuture
            let left = max(0, wait.timeIntervalSince(context.date))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text("\(timer.handoff ?? "Time block") done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                }
                Text("Next: \(timer.currentBlock?.name ?? ""), \(TimeFormatter.compact(timer.duration))\(manual ? "" : " · starts in \(Int(left.rounded(.up)))s")")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .padding(.leading, 18)
                HStack(spacing: 5) {
                    Button("Start now") { store.startWaiting(timer.id) }
                        .buttonStyle(PillButtonStyle(prominent: true))
                    if !manual {
                        Button("Pause") { store.holdWaiting(timer.id) }
                            .buttonStyle(PillButtonStyle())
                    }
                }
                .padding(.leading, 18)
                .padding(.top, 6)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.13)))
            .padding(6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(timer.handoff ?? "Time block") done. Next: \(timer.currentBlock?.name ?? "")")
    }
}

/// A thin bar for the whole session, one segment per time block.
struct SessionBar: View {
    let timer: DriftTimer
    let steps: [TimeBlock]
    let now: Date
    let width: CGFloat

    var body: some View {
        let total = max(1, steps.reduce(0) { $0 + $1.seconds })
        let gaps = CGFloat(max(0, steps.count - 1)) * 2
        HStack(spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.offset) { item in
                let w = max(3, (width - gaps) * CGFloat(item.element.seconds / total))
                ZStack(alignment: .leading) {
                    Capsule().fill(item.offset < timer.step ? Theme.accent.opacity(0.45) : Theme.control)
                    if item.offset == timer.step {
                        Capsule().fill(Theme.accent).frame(width: max(2, w * CGFloat(timer.progress(at: now))))
                    }
                }
                .frame(width: w, height: 3)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Every time block in the session with its clock time.
struct SessionList: View {
    let timer: DriftTimer
    let steps: [TimeBlock]
    @ObservedObject var store: TimerStore
    let scale: CGFloat

    var body: some View {
        let times = starts()
        let end = (times.last ?? store.now).addingTimeInterval(steps.last?.seconds ?? 0)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(timer.name ?? "Session")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("· block \(timer.step + 1) of \(steps.count) · ends \(clock(end))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .lineLimit(1)
            .padding(.horizontal, 13 * scale)
            .padding(.bottom, 4)
            ForEach(Array(steps.enumerated()), id: \.offset) { item in
                row(item.offset, item.element, start: times[item.offset])
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func row(_ i: Int, _ block: TimeBlock, start: Date) -> some View {
        let done = i < timer.step, current = i == timer.step
        return HStack(spacing: 8) {
            Text(done ? "✓" : "")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 10)
            Text(done ? "" : clock(start, suffix: false))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 36, alignment: .leading)
            Text(block.name)
                .font(.system(size: 12, weight: current ? .semibold : .regular))
                .foregroundStyle(done ? Theme.tertiaryText : (current ? Theme.primaryText : Theme.secondaryText))
                .strikethrough(done)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(current ? TimeFormatter.clock(timer.remaining(at: store.now)) : TimeFormatter.compact(block.seconds))
                .font(.system(size: 11.5, weight: current ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(current ? Theme.accent : Theme.tertiaryText)
        }
        .padding(.horizontal, 13 * scale)
        .frame(height: 24)
        .background(current ? Theme.accent.opacity(0.12) : Color.clear)
    }

    /// When each block starts, from where the session is now.
    private func starts() -> [Date] {
        let now = store.now
        var at = timer.endDate ?? now.addingTimeInterval(timer.remaining(at: now))
        let currentLength = steps.indices.contains(timer.step) ? steps[timer.step].seconds : 0
        let currentStart = at.addingTimeInterval(-currentLength)
        var out: [Date] = []
        for i in steps.indices {
            if i < timer.step {
                out.append(now)
            } else if i == timer.step {
                out.append(currentStart)
            } else {
                out.append(at)
                at = at.addingTimeInterval(steps[i].seconds)
            }
        }
        return out
    }

    private func clock(_ date: Date, suffix: Bool = true) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Schedule.time((c.hour ?? 0) * 60 + (c.minute ?? 0), suffix: suffix)
    }
}

// MARK: - Scheduled

/// After scheduling: what, when, and that it starts on its own. Edit or Undo right here.
struct ScheduledCard: View {
    let block: ScheduledBlock
    let updated: Bool
    @ObservedObject var ui: WidgetUIState
    @ObservedObject var schedule: ScheduleStore
    let actions: WidgetActions

    var body: some View {
        let next = schedule.nextOccurrence(of: block.id)
        let start = next?.occurrence.startMinute ?? block.startMinute
        let duration = next?.occurrence.duration ?? block.duration
        let split = (block.steps?.count ?? 0) > 1
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 10.5, weight: .semibold))
                Text(updated ? "UPDATED" : "SCHEDULED")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.4)
            }
            .foregroundStyle(Theme.accent)
            Text(next?.occurrence.name ?? block.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .padding(.top, 4)
            Text("\(schedule.describeDays(block)) · \(Schedule.range(startMinute: start, duration: duration))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
                .padding(.top, 2)
            if let steps = block.steps, split {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(stepStarts(steps, from: start).enumerated()), id: \.offset) { item in
                        HStack(spacing: 8) {
                            Text(Schedule.time(item.element.start, suffix: false))
                                .foregroundStyle(Theme.tertiaryText)
                                .frame(width: 34, alignment: .leading)
                            Text(item.element.block.name)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(TimeFormatter.compact(item.element.block.seconds))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .font(.system(size: 11.5).monospacedDigit())
                    }
                }
                .padding(.top, 7)
            }
            if let next {
                Text("\(next.label) at \(Schedule.time(start)), \(AppInfo.name) checks in and starts it for you.\(split ? " Each block starts when the one before it ends." : "")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
            HStack(spacing: 5) {
                Button("Got it") { ui.confirmation = nil }
                    .buttonStyle(PillButtonStyle(prominent: true))
                Button("Edit") {
                    ui.confirmation = nil
                    ui.editBlock(block.id, schedule: schedule)
                    actions.focusPanel()
                }
                .buttonStyle(PillButtonStyle())
                if !updated {
                    Button("Undo") {
                        ui.confirmation = nil
                        schedule.delete(block.id)
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
            .padding(.top, 9)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.13)))
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(updated ? "Updated" : "Scheduled"): \(block.name), \(schedule.describeDays(block))")
    }

    private func stepStarts(_ steps: [TimeBlock], from start: Int) -> [(start: Int, block: TimeBlock)] {
        var at = Double(start)
        var out: [(start: Int, block: TimeBlock)] = []
        for b in steps {
            out.append((Int(at.rounded()), b))
            at += b.seconds / 60
        }
        return out
    }
}
