import AppKit
import DriftCore
import SwiftUI

@MainActor
final class WidgetUIState: ObservableObject {
    @Published var expanded = false
    /// The timer whose label is being edited in place.
    @Published var renamingID: UUID?
    @Published var draft = ""
    /// The timer whose time is on the dial, and the dial's value.
    @Published var dialID: UUID?
    @Published var dialValue: TimeInterval = 0
    var dialOriginal: TimeInterval = 0
    /// A scheduled block open in the editor.
    @Published var blockDraft: BlockDraft?
    /// Shown for a moment after hiding, so the widget never just vanishes.
    @Published var hideHint = false
    /// A finished timer is chiming; the widget pulses until it's handled.
    @Published var alerting = false
    /// Time's up: the widget shakes until it's touched.
    @Published var shaking = false
    /// The "Scheduled" card at the top, after planning something.
    @Published var confirmation: Confirmation?
    /// Just deleted: a bar with Undo shows for a few seconds.
    @Published var deleted: ScheduledBlock?
    /// The idle widget's tab: 0 Start now, 1 Later today, 2 Routine.
    @Published var idleMode = 0
    /// The dial is open with no timer yet: Start begins one.
    @Published var idleDial = false
    /// The timer whose time is being typed in place (double-click the time).
    @Published var typingID: UUID?
    /// How far −, +, scrolling and dragging move a work session: 1, 5 or 10 minutes.
    @Published var nudgeStep = 5
    /// Typing a value into the dial's centre (double-click it).
    @Published var dialTyping = false
    /// The dial's limit when a grace period (or a session) caps extra time.
    var dialMax: TimeInterval = WidgetUIState.dialMaximum
    var dialBaseExtra: TimeInterval = 0

    struct Confirmation: Equatable {
        var blockID: UUID
        var updated: Bool
        var until: Date
    }
}

extension WidgetUIState {
    static let dialMaximum: TimeInterval = 12 * 3_600

    /// Deletes a planned session or routine, with Undo.
    func delete(_ id: UUID, schedule: ScheduleStore) {
        guard let block = schedule.block(id) else { return }
        schedule.delete(id)
        if confirmation?.blockID == id { confirmation = nil }
        if blockDraft?.id == id { blockDraft = nil }
        deleted = block
    }

    /// Opens the editor on an existing block (as it runs today) or a new one:
    /// later today, or a routine.
    func editBlock(_ id: UUID?, schedule: ScheduleStore, routine: Bool = false, start: Int? = nil, days: [Int]? = nil) {
        closeDial(commit: true, store: nil)
        renamingID = nil
        let now = schedule.now
        let cal = Calendar.current
        let nowMinute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        var draft: BlockDraft
        if let id, let block = schedule.block(id) {
            let e = schedule.occurrenceToday(id)
            let name = e?.name ?? block.name, start = e?.startMinute ?? block.startMinute, dur = e?.duration ?? block.duration
            draft = BlockDraft(id: id, name: name, startMinute: start, duration: dur, days: block.days,
                               date: block.date ?? schedule.dayKey,
                               original: .init(name: name, startMinute: start, duration: dur, days: block.days),
                               windowStart: 0, steps: block.steps)
        } else {
            let start = start ?? (routine ? 9 * 60 : min(23 * 60 + 30, (nowMinute / 15 + 1) * 15 + 15))
            var date = schedule.dayKey
            if !routine, start <= nowMinute, let t = cal.date(byAdding: .day, value: 1, to: now) { date = Schedule.dayKey(t) }
            draft = BlockDraft(id: nil, name: "", startMinute: start, duration: 3_600, days: routine ? (days ?? [1, 2, 3, 4, 5]) : nil,
                               date: date, original: nil, windowStart: 0)
        }
        draft.windowStart = BlockTimeline.window(around: draft.startMinute)
        blockDraft = draft
    }

    /// Moves a work session's start, or changes its length, by whole steps.
    func nudge(_ steps: Int, length: Bool) {
        guard let d = blockDraft else { return }
        let delta = steps * nudgeStep
        if length {
            let m = Int(d.duration / 60) + delta
            blockDraft?.duration = TimeInterval(max(5, min(16 * 60, m)) * 60)
        } else {
            let m = max(0, min(1_439, d.startMinute + delta))
            blockDraft?.startMinute = m
            blockDraft?.windowStart = BlockTimeline.window(around: m, current: d.windowStart)
        }
    }

    func beginRename(_ t: DriftTimer) {
        guard t.pomodoro == nil else { return }
        closeDial(commit: true, store: nil)
        draft = (t.isSession ? t.currentBlock?.name : t.name) ?? ""
        renamingID = t.id
    }

    /// `room`: how much extra time the timer may still get (grace period).
    func openDial(_ t: DriftTimer, now: Date, room: TimeInterval = .infinity) {
        guard !t.isFinished else { return }
        renamingID = nil
        dialOriginal = t.remaining(at: now)
        dialValue = max(60, (dialOriginal / 60).rounded() * 60)
        dialBaseExtra = t.extraSoFar
        dialMax = room.isInfinite ? Self.dialMaximum : max(dialValue, ((dialOriginal + room) / 60).rounded(.down) * 60)
        dialID = t.id
    }

    var dialLimited: Bool { dialMax < Self.dialMaximum }

    /// The dial for a new timer: pick a length, then Start.
    func openIdleDial(_ value: TimeInterval) {
        renamingID = nil
        typingID = nil
        blockDraft = nil
        dialMax = Self.dialMaximum
        dialValue = max(60, (value / 60).rounded() * 60)
        idleDial = true
    }

    /// Moves the dial; the timer follows live, a minute at a time.
    func setDial(_ value: TimeInterval, store: TimerStore) {
        if idleDial && dialID == nil {
            let next = min(Self.dialMaximum, max(60, (value / 60).rounded() * 60))
            guard next != dialValue else { return }
            dialValue = next
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            return
        }
        guard let id = dialID else { return }
        let next = min(dialMax, max(60, (value / 60).rounded() * 60))
        guard next != dialValue else { return }
        dialValue = next
        store.setRemaining(id, seconds: next, extra: dialLimited ? dialBaseExtra + max(0, next - dialOriginal) : nil)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Done keeps the new time; Cancel puts the old one back.
    func closeDial(commit: Bool, store: TimerStore?) {
        dialTyping = false
        if idleDial { idleDial = false }
        guard let id = dialID else { return }
        if !commit, let store, store.timer(id) != nil {
            store.setRemaining(id, seconds: dialOriginal, extra: dialBaseExtra)
        }
        dialID = nil
    }
}

struct WidgetActions {
    var openComposer: () -> Void
    var openVoice: () -> Void
    /// Any deliberate interaction with a finished timer stops the chime.
    var acknowledge: () -> Void
    var hide: () -> Void
    var resize: (CGSize) -> Void
    var focusPanel: () -> Void
    var releaseFocus: () -> Void
}

/// The floating widget. Collapsed, it's one line: what's happening, how much
/// time is left, and a way to pause. Click the time to reveal everything else.
struct WidgetView: View {
    @ObservedObject var store: TimerStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: WidgetUIState
    @ObservedObject var schedule: ScheduleStore
    let actions: WidgetActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var scale: CGFloat { settings.widgetSize.scale }
    private var expandedWidth: CGFloat { 272 * scale }
    private var editorWidth: CGFloat { 344 }

    private var cardWidth: CGFloat { 296 * scale }

    private var width: CGFloat? {
        if ui.hideHint { return nil }
        if ui.blockDraft != nil { return max(editorWidth, cardWidth) }
        // The idle row, cards and sessions need room; a single timer hugs its content.
        if store.primary == nil || store.primary?.isFinished == true || store.primary?.isWaiting == true
            || store.primary?.isSession == true || ui.confirmation != nil || ui.deleted != nil { return cardWidth }
        if ui.expanded || ui.dialID != nil || schedule.prompt != nil { return cardWidth }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !ui.hideHint, let prompt = schedule.prompt, let occ = schedule.occurrenceToday(prompt.blockID) {
                BlockPrompt(occurrence: occ, prompt: prompt, schedule: schedule, actions: actions)
                    .transition(.opacity)
            }
            if !ui.hideHint, let gone = ui.deleted {
                UndoBar(block: gone, ui: ui, schedule: schedule)
                    .transition(.opacity)
            }
            if !ui.hideHint, let c = ui.confirmation, let block = schedule.block(c.blockID) {
                ScheduledCard(block: block, updated: c.updated, ui: ui, schedule: schedule, actions: actions)
                    .transition(.opacity)
            }
            if ui.hideHint {
                HideHint(settings: settings, scale: scale)
            } else if let primary = store.primary, primary.isFinished {
                TimesUpCard(timer: primary, store: store, settings: settings, ui: ui, schedule: schedule, scale: scale, actions: actions)
            } else if let primary = store.primary {
                if primary.isWaiting {
                    HandoffCard(timer: primary, store: store)
                        .transition(.opacity)
                }
                PrimaryRow(timer: primary, store: store, ui: ui, scale: scale,
                           othersCount: store.others.count, actions: actions)
                if primary.isSession, !ui.expanded, ui.dialID == nil, let steps = primary.steps {
                    SessionBar(timer: primary, steps: steps, now: store.now, width: cardWidth - 46 * scale)
                        .padding(.leading, 33 * scale)
                        .padding(.bottom, 8)
                }
                if settings.featurePlan, !ui.expanded, ui.dialID == nil, ui.blockDraft == nil, schedule.prompt == nil,
                   ui.confirmation == nil, let next = schedule.next(), !next.tomorrow,
                   primary.blockID != next.entry.block.id {
                    NextBlockLine(entry: next.entry, tomorrow: false, ui: ui, schedule: schedule, actions: actions, scale: scale)
                }
            } else {
                IdleRow(store: store, settings: settings, ui: ui, schedule: schedule, scale: scale, actions: actions)
            }

            if ui.blockDraft != nil, !ui.hideHint {
                BlockEditor(ui: ui, schedule: schedule, actions: actions)
                    .transition(.opacity)
            } else if let id = ui.dialID, let t = store.timer(id), !ui.hideHint {
                DialSection(timer: t, store: store, settings: settings, ui: ui, actions: actions)
                    .transition(.opacity)
            } else if ui.idleDial, store.primary == nil, !ui.hideHint {
                DialSection(timer: nil, store: store, settings: settings, ui: ui, actions: actions)
                    .transition(.opacity)
            } else if ui.expanded && !ui.hideHint {
                ExpandedSection(store: store, settings: settings, ui: ui, schedule: schedule, scale: scale, actions: actions)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: width, alignment: .leading)
        .driftSurface(cornerRadius: Theme.cornerRadius * min(scale, 1.15), opacity: settings.widgetOpacity)
        .overlay(AlertPulse(active: ui.alerting, cornerRadius: Theme.cornerRadius * min(scale, 1.15)))
        .contextMenu { contextMenu }
        .animation(reduceMotion ? nil : Theme.quick, value: ui.expanded)
        .animation(reduceMotion ? nil : Theme.quick, value: ui.hideHint)
        .animation(reduceMotion ? nil : Theme.quick, value: ui.dialID)
        .animation(reduceMotion ? nil : Theme.quick, value: ui.idleDial)
        .animation(reduceMotion ? nil : Theme.quick, value: ui.blockDraft == nil)
        .animation(reduceMotion ? nil : Theme.quick, value: schedule.prompt)
        .animation(reduceMotion ? nil : Theme.quick, value: ui.confirmation)
        .animation(reduceMotion ? nil : Theme.quick, value: ui.deleted)
        .animation(reduceMotion ? nil : Theme.quick, value: store.primary?.isWaiting)
        .animation(reduceMotion ? nil : Theme.quick, value: store.timers.map(\.id))
        .fixedSize()
        .reportSize(actions.resize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(AppInfo.name) timer")
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let t = store.primary {
            if t.isFinished {
                Button("Add 5 Minutes") { actions.acknowledge(); store.adjust(t.id, by: 300) }
                Button("Dismiss") { actions.acknowledge(); store.remove(t.id) }
            } else {
                Button(t.isRunning ? "Pause" : "Resume") { store.toggle(t.id) }
                if t.isSession {
                    Button(t.nextBlock.map { "Next: \($0.name)" } ?? "Finish") { store.nextBlock(t.id) }
                }
                Button("Add 5 Minutes") { store.adjust(t.id, by: 300) }
                    .disabled(store.extraLeft(t) < 1)
                Button("Remove 5 Minutes") { store.adjust(t.id, by: -300) }
                    .disabled(t.remaining(at: store.now) <= 300)
                Button("Change Time…") { ui.openDial(t, now: Date(), room: store.extraLeft(t)); actions.focusPanel() }
                if t.pomodoro == nil { Button(t.name == nil ? "Add Task…" : "Rename…") { ui.beginRename(t); actions.focusPanel() } }
                if let cycle = t.pomodoro {
                    Button("Skip to \(cycle.upNext.name)") { store.skipPhase(t.id) }
                }
                if !t.isSession { Button("Duplicate") { store.duplicate(t.id) } }
                Divider()
                Button(t.pomodoro != nil ? "End Pomodoro" : t.isSession ? "End Session" : "Cancel Timer") { store.remove(t.id) }
            }
            Divider()
        }
        Button("New Timer…") { actions.openComposer() }
        Button(ui.expanded ? "Collapse" : "Show All Timers") { ui.expanded.toggle() }
        Button("Hide Widget") { actions.hide() }
    }

}

// MARK: - Primary row

private struct PrimaryRow: View {
    let timer: DriftTimer
    @ObservedObject var store: TimerStore
    @ObservedObject var ui: WidgetUIState
    let scale: CGFloat
    let othersCount: Int
    let actions: WidgetActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var timeHover = false

    private var remaining: TimeInterval { timer.remaining(at: store.now) }

    private func beginTyping() {
        actions.acknowledge()
        ui.closeDial(commit: true, store: store)
        ui.renamingID = nil
        ui.typingID = timer.id
        actions.focusPanel()
    }
    private var isWarning: Bool { timer.isRunning && remaining <= 60 && timer.duration > 90 }

    private var timeColor: Color {
        if timer.isFinished || isWarning { return Theme.accent }
        if timer.isPaused { return Theme.secondaryText }
        return Theme.primaryText
    }

    var body: some View {
        HStack(spacing: 9 * scale) {
            StatusDot(timer: timer, size: 7 * scale)

            HStack(alignment: .firstTextBaseline, spacing: 7 * scale) {
                TaskLabel(timer: timer, store: store, ui: ui, actions: actions,
                          size: 12 * scale, maxWidth: 104 * scale, fieldWidth: 120 * scale)
                if timer.isFinished {
                    Text("Done")
                        .font(Theme.digits(22 * scale))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                        .onTapGesture { actions.acknowledge(); ui.expanded.toggle() }
                        .accessibilityLabel(accessibilityText)
                        .accessibilityAddTraits(.isButton)
                } else if ui.typingID == timer.id {
                    TimeTypeField(timer: timer, store: store, ui: ui, scale: scale, actions: actions)
                } else {
                    // Click: the dial. Double-click: type the time right here.
                    TimeText(remaining: remaining, size: 22 * scale, color: timeColor)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(ui.dialID == timer.id ? Theme.accent.opacity(0.14) : (timeHover ? Theme.control : Color.clear))
                        )
                        .padding(.horizontal, -3)
                        .padding(.vertical, -1)
                        .contentShape(Rectangle())
                        .onHover { timeHover = $0 }
                        .gesture(
                            TapGesture(count: 2).onEnded { beginTyping() }
                                .exclusively(before: TapGesture(count: 1).onEnded { toggleDial() })
                        )
                        .help("Click to turn the dial. Double-click to type a time.")
                        .accessibilityLabel(accessibilityText)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Opens a dial to change the time")
                        .accessibilityAction { toggleDial() }
                        .accessibilityAction(named: "Type a time") { beginTyping() }
                }
            }

            Spacer(minLength: 2)

            HStack(spacing: 2) {
                if timer.isFinished {
                    Button { actions.acknowledge(); store.remove(timer.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 26 * scale, tint: Theme.accent))
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss finished timer")
                } else {
                    Button { store.toggle(timer.id) } label: {
                        Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                            .offset(x: timer.isRunning ? 0 : 0.5)
                    }
                    .buttonStyle(IconButtonStyle(size: 26 * scale, tint: timer.isRunning ? Theme.secondaryText : Theme.accent))
                    .help(timer.isRunning ? "Pause" : "Resume")
                    .accessibilityLabel(timer.isRunning ? "Pause" : "Resume")

                    if ui.expanded {
                        Button { store.remove(timer.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(IconButtonStyle(size: 26 * scale, tint: Theme.secondaryText))
                            .help(timer.pomodoro != nil ? "End Pomodoro" : timer.isSession ? "End this session" : "Cancel this timer")
                            .accessibilityLabel(timer.pomodoro != nil ? "End Pomodoro" : timer.isSession ? "End session" : "Cancel timer")
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }

                // Always visible: opens the full widget — every timer, + New
                // timer, focus sound. Shows "+N" when other timers exist.
                Button { actions.acknowledge(); ui.expanded.toggle() } label: {
                    if othersCount > 0 && !ui.expanded {
                        HStack(spacing: 2) {
                            Text("+\(othersCount)")
                                .font(.system(size: 10.5 * scale, weight: .semibold).monospacedDigit())
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8 * scale, weight: .bold))
                        }
                        .padding(.horizontal, 2)
                    } else {
                        Image(systemName: ui.expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10 * scale, weight: .bold))
                    }
                }
                .buttonStyle(ExpandButtonStyle(scale: scale, highlighted: !ui.expanded))
                .help(ui.expanded ? "Collapse" : "Show all timers, add a timer, focus sound")
                .accessibilityLabel(ui.expanded ? "Collapse" : (othersCount > 0 ? "Show \(othersCount) more \(othersCount == 1 ? "timer" : "timers")" : "Show timer controls"))
            }
        }
        .padding(.leading, 13 * scale)
        .padding(.trailing, 7 * scale)
        .padding(.vertical, 7 * scale)
        .animation(reduceMotion ? nil : Theme.gentle, value: isWarning)
        .animation(reduceMotion ? nil : Theme.quick, value: timer.state)
    }

    private func toggleDial() {
        actions.acknowledge()
        if ui.dialID == timer.id {
            ui.closeDial(commit: true, store: store)
            actions.releaseFocus()
        } else {
            ui.openDial(timer, now: Date(), room: store.extraLeft(timer))
            actions.focusPanel()
        }
    }

    private var accessibilityText: String {
        let name = timer.displayName ?? "Timer"
        if timer.isFinished { return "\(name) finished" }
        let state = timer.isRunning ? "running" : "paused"
        return "\(name), \(TimeFormatter.spoken(remaining.rounded(.up))) remaining, \(state)"
    }
}

/// The expand arrow: a soft filled pill so it reads as "there's more here".
struct ExpandButtonStyle: ButtonStyle {
    let scale: CGFloat
    let highlighted: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? Theme.primaryText : Theme.secondaryText)
            .frame(minWidth: 26 * scale, minHeight: 24 * scale)
            .background(
                Capsule().fill(configuration.isPressed || hovering ? Theme.controlHover : (highlighted ? Theme.control : Color.clear))
            )
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

/// A gentle ember ring that breathes while a finished timer is chiming.
private struct AlertPulse: View {
    let active: Bool
    let cornerRadius: CGFloat
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Theme.accent, lineWidth: 2)
            .opacity(active ? (reduceMotion ? 0.9 : (on ? 1 : 0.25)) : 0)
            .allowsHitTesting(false)
            .onChange(of: active) { start($0) }
            .onAppear { start(active) }
    }

    private func start(_ isActive: Bool) {
        guard isActive, !reduceMotion else { on = false; return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
    }
}

/// Briefly replaces the widget after hiding: tells you where it went.
private struct HideHint: View {
    @ObservedObject var settings: AppSettings
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Text("Hidden. Timers keep running.")
                .font(.system(size: 12 * scale, weight: .medium))
                .foregroundStyle(Theme.primaryText)
            if let s = settings.shortcuts[.toggleWidget] {
                KeyCaps(text: s.display)
                Text("brings it back")
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 13 * scale)
        .frame(height: 42 * scale)
        .accessibilityElement(children: .combine)
    }
}

/// Tabular digits in a width that only changes when the *format* changes
/// (e.g. 10:00 → 9:59), never as seconds tick.
struct TimeText: View {
    let remaining: TimeInterval
    let size: CGFloat
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = TimeFormatter.clock(remaining)
        let template = String(text.map { $0.isNumber ? "0" : $0 })
        ZStack(alignment: .leading) {
            Text(template.count < 5 ? "00:00" : template).hidden()
            Text(text)
                .foregroundStyle(color)
                .numericTransition()
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: text)
        }
        .font(Theme.digits(size))
        .kerning(-0.3)
        .lineLimit(1)
        // Never truncate the time: the name gives way instead.
        .fixedSize()
        .layoutPriority(2)
    }
}

/// Filled ember = running. Hollow = paused. Check = done.
struct StatusDot: View {
    let timer: DriftTimer
    let size: CGFloat

    var body: some View {
        ZStack {
            if timer.isFinished {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 1.3, weight: .bold))
                    .foregroundStyle(Theme.accent)
            } else if timer.isRunning {
                Circle().fill(Theme.accent).frame(width: size, height: size)
            } else {
                Circle().strokeBorder(Theme.tertiaryText, lineWidth: 1.25).frame(width: size, height: size)
            }
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .accessibilityHidden(true)
    }
}

// MARK: - Expanded

private struct ExpandedSection: View {
    @ObservedObject var store: TimerStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: WidgetUIState
    @ObservedObject var schedule: ScheduleStore
    let scale: CGFloat
    let actions: WidgetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let t = store.primary, !t.isFinished {
                ProgressLine(progress: t.progress(at: store.now), active: t.isRunning)
                    .padding(.horizontal, 13 * scale)

                if let cycle = t.pomodoro {
                    PomodoroStrip(cycle: cycle, scale: scale)
                }
                if t.isSession, let steps = t.steps {
                    SessionList(timer: t, steps: steps, store: store, scale: scale)
                }
                controls(for: t)
                if let note = graceNote(t) {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 13 * scale)
                        .padding(.bottom, 6)
                }
            }

            let others = store.others
            if !others.isEmpty {
                Hairline()
                VStack(spacing: 0) {
                    ForEach(others) { other in
                        OtherTimerRow(timer: other, store: store, ui: ui, actions: actions, scale: scale)
                    }
                }
                .padding(.vertical, 4)
            }

            if settings.featurePlan && !schedule.blocks.isEmpty {
                Hairline()
                TodaySection(ui: ui, schedule: schedule, actions: actions, scale: scale)
            }

            if settings.featureSounds {
                Hairline()
                FocusSoundRow(settings: settings, scale: scale)
            }

            Hairline()
            HStack(spacing: 4) {
                Button { actions.openComposer() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("New timer")
                    }
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .help("Write a task and a time, like “Reply to emails 25m”")
                if settings.featureVoice {
                    Button { actions.openVoice() } label: { Image(systemName: "mic") }
                        .buttonStyle(IconButtonStyle(size: 24, tint: Theme.secondaryText))
                        .help("Say it: “25 minutes for email”")
                        .accessibilityLabel("Speak a timer")
                }
                if settings.featurePlan && schedule.blocks.isEmpty {
                    Button {
                        ui.editBlock(nil, schedule: schedule)
                        actions.focusPanel()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar").font(.system(size: 10, weight: .semibold))
                            Text("Plan")
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .help("Plan something for later today, or a routine")
                }
                Spacer()
                Button { actions.hide() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.slash").font(.system(size: 10, weight: .semibold))
                        Text("Hide")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .help("Hide the widget. Timers keep running; the time shows in the menu bar.")
                .accessibilityLabel("Hide widget")
            }
            .padding(.horizontal, 7 * scale)
            .padding(.vertical, 5)
        }
    }

    /// Shown once extra time has been used under a grace period.
    private func graceNote(_ t: DriftTimer) -> String? {
        guard settings.gracePeriod > 0, t.extraSoFar > 0, t.pomodoro == nil else { return nil }
        let room = store.extraLeft(t)
        return room >= 60 ? "Grace period: \(TimeFormatter.compact(room)) of extra time left" : "Grace period used. Time to wrap up."
    }

    private func plusTitle(_ room: TimeInterval) -> String {
        room.isInfinite || room >= 300 ? "+5 min" : "+\(TimeFormatter.compact(max(60, room)))"
    }

    @ViewBuilder
    private func controls(for t: DriftTimer) -> some View {
        let room = store.extraLeft(t)
        HStack(spacing: 2) {
            if t.isSession {
                Button(t.nextBlock.map { "Next: \($0.name)" } ?? "Finish") { store.nextBlock(t.id) }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .lineLimit(1)
                    .help("Done early? Move straight on.")
                if room >= 1 {
                    Button(plusTitle(room)) { store.adjust(t.id, by: 300) }
                        .buttonStyle(QuietButtonStyle())
                }
                Button("Set time…") { ui.openDial(t, now: Date(), room: room); actions.focusPanel() }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
            } else if let cycle = t.pomodoro {
                Button("Skip to \(cycle.upNext.name.lowercased())") { store.skipPhase(t.id) }
                    .buttonStyle(QuietButtonStyle())
                    .help("End this \(cycle.phaseName.lowercased()) now and start the \(cycle.upNext.name.lowercased())")
                Button(plusTitle(room)) { store.adjust(t.id, by: 300) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(room < 1)
                Spacer()
            } else {
                Button("−5 min") { store.adjust(t.id, by: -300) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(t.remaining(at: store.now) <= 301)
                    .accessibilityLabel("Remove 5 minutes")
                Button(plusTitle(room)) { store.adjust(t.id, by: 300) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(room < 1)
                    .help(room < 1 ? "Grace period used" : "Add time")
                    .accessibilityLabel("Add 5 minutes")
                Button("Set time…") { ui.openDial(t, now: Date(), room: room); actions.focusPanel() }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .help("Turn a dial or pick 5, 10, 15, 20, 25, 30, 45 min, 1 h or 2 h")
                Spacer()
            }
        }
        .padding(.horizontal, 7 * scale)
        .padding(.vertical, 5)
    }
}

/// Shows where you are in a Pomodoro set and what's next:
///   ● ● ○ ○   Focus 2 of 4 · Break next, 5 min
private struct PomodoroStrip: View {
    let cycle: PomodoroCycle
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(1...max(1, cycle.roundsPerSet), id: \.self) { i in
                    Capsule()
                        .fill(dotColor(i))
                        .frame(width: i == cycle.roundInSet ? 14 : 6, height: 6)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(cycle.isBreak ? "\(cycle.phaseName) — step away" : "Focus \(cycle.roundInSet) of \(cycle.roundsPerSet)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(cycle.isBreak ? Theme.accent : Theme.primaryText)
                Text("\(cycle.upNext.name) next, \(TimeFormatter.compact(cycle.upNext.duration)). Runs on its own.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 13 * scale)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    private func dotColor(_ i: Int) -> Color {
        if i < cycle.roundInSet { return Theme.accent.opacity(0.55) }
        if i == cycle.roundInSet { return cycle.isBreak ? Theme.accent.opacity(0.55) : Theme.accent }
        return Theme.control
    }
}

/// Focus sound on/off and which sound, right in the widget.
private struct FocusSoundRow: View {
    @ObservedObject var settings: AppSettings
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(settings.focusSoundEnabled ? Theme.accent : Theme.tertiaryText)
            Text("Focus sound")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 4)
            Menu {
                ForEach(Soundscape.Category.allCases) { category in
                    Section(category.title) {
                        ForEach(category.scapes) { scape in
                            Button {
                                settings.soundscape = scape
                                settings.focusSoundEnabled = true
                            } label: {
                                if settings.soundscape == scape {
                                    Label(scape.title, systemImage: "checkmark")
                                } else {
                                    Text(scape.title)
                                }
                            }
                            .help(scape.subtitle)
                        }
                    }
                }
            } label: {
                Text(settings.soundscape.title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose a sound")
            Toggle("", isOn: $settings.focusSoundEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityLabel("Focus sound")
        }
        .padding(.horizontal, 13 * scale)
        .frame(height: 32)
        .help("Plays softly while a timer runs. Pauses during breaks.")
    }
}

private struct OtherTimerRow: View {
    let timer: DriftTimer
    @ObservedObject var store: TimerStore
    @ObservedObject var ui: WidgetUIState
    let actions: WidgetActions
    let scale: CGFloat
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(timer: timer, size: 6 * scale)
            TaskLabel(timer: timer, store: store, ui: ui, actions: actions,
                      size: 12 * scale, maxWidth: 150 * scale, fieldWidth: 130 * scale)
            Spacer(minLength: 6)
            if timer.isFinished {
                Text("Done")
                    .font(Theme.digits(13 * scale))
                    .foregroundStyle(Theme.accent)
            } else {
                Button {
                    ui.openDial(timer, now: Date(), room: store.extraLeft(timer))
                    actions.focusPanel()
                } label: {
                    Text(TimeFormatter.clock(timer.remaining(at: store.now)))
                        .font(Theme.digits(13 * scale))
                        .foregroundStyle(timer.isPaused ? Theme.tertiaryText : Theme.primaryText)
                }
                .buttonStyle(EditableTextStyle(active: ui.dialID == timer.id))
                .help("Click to change the time")
            }
            if !timer.isFinished {
                Button { store.toggle(timer.id) } label: {
                    Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                }
                .buttonStyle(IconButtonStyle(size: 22 * scale))
                .help(timer.isRunning ? "Pause" : "Resume")
                .accessibilityLabel(timer.isRunning ? "Pause" : "Resume")
            }
            Button { store.remove(timer.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 22 * scale))
                .help(timer.isFinished ? "Dismiss" : "Cancel")
                .accessibilityLabel(timer.isFinished ? "Dismiss" : "Cancel")
        }
        .frame(height: 28 * scale)
        .padding(.leading, 13 * scale)
        .padding(.trailing, 7 * scale)
        .background(hovering ? Theme.control : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.makePrimary(timer.id) }
        .help("Click to show this timer at the top")
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show at top") { store.makePrimary(timer.id) }
        .accessibilityAction(named: timer.isRunning ? "Pause" : "Resume") { store.toggle(timer.id) }
        .accessibilityAction(named: "Cancel") { store.remove(timer.id) }
    }
}

private struct ProgressLine: View {
    let progress: Double
    let active: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.control)
                Capsule()
                    .fill(active ? Theme.accent : Theme.tertiaryText)
                    .frame(width: max(2, proxy.size.width * progress))
            }
        }
        .frame(height: 2)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.5)
    }
}

// MARK: - Editing in place

/// A timer's task. Click to rename it right where it is; a timer without one
/// invites one with a faint "+ Add task".
private struct TaskLabel: View {
    let timer: DriftTimer
    @ObservedObject var store: TimerStore
    @ObservedObject var ui: WidgetUIState
    let actions: WidgetActions
    let size: CGFloat
    let maxWidth: CGFloat
    let fieldWidth: CGFloat

    @FocusState private var focused: Bool

    /// In a session, the label is the time block you're on.
    private var label: String? { timer.isSession ? timer.currentBlock?.name : timer.name }

    var body: some View {
        if ui.renamingID == timer.id {
            TextField("What is it for?", text: $ui.draft)
                .textFieldStyle(.plain)
                .font(.system(size: size + 0.5, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
                .padding(.horizontal, 6)
                .frame(width: fieldWidth, height: size + 10)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1))
                .onAppear { DispatchQueue.main.async { focused = true } }
                .onChange(of: focused) { isFocused in
                    if !isFocused && ui.renamingID == timer.id { commit() }
                }
                .accessibilityLabel("Task name")
        } else if timer.pomodoro != nil {
            Text(timer.displayName ?? "")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(timer.pomodoro?.isBreak == true ? Theme.accent : Theme.secondaryText)
                .lineLimit(1)
        } else if timer.isFinished && timer.name == nil {
            EmptyView()
        } else {
            Button {
                actions.acknowledge()
                ui.beginRename(timer)
                actions.focusPanel()
            } label: {
                if let name = label {
                    Text(name)
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil").font(.system(size: size - 1, weight: .semibold))
                        Text("Name it")
                    }
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                }
            }
            .buttonStyle(EditableTextStyle(active: false))
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: label == nil, vertical: false)
            .help(label == nil ? "Add what this timer is for" : (timer.isSession ? "\(timer.name ?? "Session"): block \(timer.step + 1) of \(timer.steps?.count ?? 0). Click to rename" : "Click to rename"))
            .accessibilityLabel(label.map { "Task: \($0). Rename" } ?? "Add task")
        }
    }

    private func commit() {
        guard ui.renamingID == timer.id else { return }
        store.rename(timer.id, to: ui.draft)
        ui.renamingID = nil
        ui.draft = ""
        actions.releaseFocus()
    }

    private func cancel() {
        ui.renamingID = nil
        ui.draft = ""
        actions.releaseFocus()
    }
}

/// Text you can click to edit: a dotted underline on hover says so.
struct EditableTextStyle: ButtonStyle {
    let active: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.14) : (hovering || configuration.isPressed ? Theme.control : Color.clear))
            )
            .padding(.horizontal, -3)
            .padding(.vertical, -1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Dial

/// Change a timer's time by turning a dial: a minute per notch, a full turn
/// is an hour. Presets and ±5 sit underneath. The timer follows live; Cancel
/// puts it back.
private struct DialSection: View {
    /// nil: a new timer, started with Start.
    let timer: DriftTimer?
    @ObservedObject var store: TimerStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: WidgetUIState
    let actions: WidgetActions

    @State private var lastAngle: Double?
    @State private var accumulated: Double = 0

    private static let diameter: CGFloat = 184

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(timer.map { $0.displayName ?? "Timer" } ?? "New timer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(timer == nil ? "turn, or tap a length" : "drag, scroll or use arrows")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            if ui.dialLimited {
                Text(timer?.isSession == true && !settings.extraInSessions ? "Time blocks can be shortened, not stretched" : "Up to \(TimeFormatter.compact(ui.dialMax)) with your grace period")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.bottom, 6)
            }
            DialFace(value: ui.dialValue, typing: ui.dialTyping)
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
                .gesture(turn)
                .overlay {
                    // The number in the middle: double-click to type a time.
                    if ui.dialTyping {
                        DialTypeField(ui: ui, store: store)
                    } else {
                        Color.clear
                            .frame(width: 110, height: 56)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { ui.dialTyping = true }
                            .help("Double-click to type a time")
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Time left")
                .accessibilityValue(TimeFormatter.spoken(ui.dialValue))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: ui.setDial(ui.dialValue + 60, store: store)
                    case .decrement: ui.setDial(ui.dialValue - 60, store: store)
                    @unknown default: break
                    }
                }

            HStack(spacing: 8) {
                step("−5 min", -300)
                step("−1", -60)
                step("+1", 60)
                step("+5 min", 300)
            }
            .padding(.top, 10)
            .padding(.bottom, 10)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5), spacing: 5) {
                ForEach(Array(settings.presets.prefix(10).enumerated()), id: \.offset) { item in
                    let seconds = item.element
                    Button(TimeFormatter.compact(seconds)) {
                        ui.setDial(seconds, store: store)
                        finish(commit: true)
                    }
                    .buttonStyle(PresetChipStyle(selected: ui.dialValue == seconds))
                    .accessibilityLabel("Set to \(TimeFormatter.spoken(seconds))")
                }
            }

            HStack(spacing: 6) {
                Spacer()
                Button("Cancel") { finish(commit: false) }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(timer == nil ? "Start \(TimeFormatter.compact(ui.dialValue))" : "Done") { finish(commit: true) }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    private func step(_ title: String, _ delta: TimeInterval) -> some View {
        Button(title) { ui.setDial(ui.dialValue + delta, store: store) }
            .buttonStyle(StepChipStyle())
            .accessibilityLabel(delta > 0 ? "Add \(TimeFormatter.spoken(delta))" : "Remove \(TimeFormatter.spoken(-delta))")
    }

    private func finish(commit: Bool) {
        if timer == nil {
            let value = ui.dialValue
            ui.idleDial = false
            if commit { store.create(seconds: value) }
        } else {
            ui.closeDial(commit: commit, store: store)
        }
        actions.releaseFocus()
    }

    /// Dragging around the ring: one minute per 6°.
    private var turn: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let c = Self.diameter / 2
                let angle = atan2(Double(g.location.y - c), Double(g.location.x - c)) * 180 / .pi
                if let last = lastAngle {
                    var d = angle - last
                    if d > 180 { d -= 360 }
                    if d < -180 { d += 360 }
                    accumulated += d / 6
                    let whole = accumulated.rounded(.towardZero)
                    if whole != 0 {
                        accumulated -= whole
                        ui.setDial(ui.dialValue + whole * 60, store: store)
                    }
                }
                lastAngle = angle
            }
            .onEnded { _ in
                lastAngle = nil
                accumulated = 0
            }
    }
}

private struct DialFace: View {
    let value: TimeInterval
    var typing = false

    var body: some View {
        let minutes = value.truncatingRemainder(dividingBy: 3_600) / 3_600
        let fullHour = value >= 3_600 && minutes == 0
        let fraction = fullHour ? 1 : minutes
        let hours = Int(value / 3_600)
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let ring = size / 2 - 16
            ZStack {
                ForEach(0..<60, id: \.self) { i in
                    Capsule()
                        .fill(Theme.tertiaryText.opacity(i % 5 == 0 ? 1 : 0.7))
                        .frame(width: i % 5 == 0 ? 1.6 : 1.1, height: i % 5 == 0 ? 6 : 4)
                        .offset(y: -(size / 2 - 4))
                        .rotationEffect(.degrees(Double(i) * 6))
                }
                Circle()
                    .stroke(Theme.control, lineWidth: 10)
                    .frame(width: ring * 2, height: ring * 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: ring * 2, height: ring * 2)
                Circle()
                    .fill(Theme.surface)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 3))
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .offset(y: -ring)
                    .rotationEffect(.degrees(fullHour ? 0 : minutes * 360))
                VStack(spacing: 6) {
                    Text(TimeFormatter.clock(value))
                        .font(Theme.digits(34))
                        .kerning(-0.5)
                        .foregroundStyle(Theme.primaryText)
                        .opacity(typing ? 0 : 1)
                    Text(typing ? "Return to set" : hours > 0 ? "\(hours) h + minutes on the ring" : "Double-click to type")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: size, height: size)
        }
    }
}

private struct StepChipStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(configuration.isPressed || hovering ? Theme.controlHover : Theme.control))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

private struct PresetChipStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(selected ? Color.white : (hovering ? Theme.primaryText : Theme.secondaryText))
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Theme.accent : (configuration.isPressed || hovering ? Theme.controlHover : Theme.control))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Schedule

/// "Deep work starts now": start, push it five minutes, or skip today.
/// Left alone, the block starts by itself when the countdown runs out.
private struct BlockPrompt: View {
    let occurrence: BlockOccurrence
    let prompt: ScheduleStore.Prompt
    @ObservedObject var schedule: ScheduleStore
    let actions: WidgetActions

    var body: some View {
        let left = max(0, prompt.deadline.timeIntervalSince(schedule.now))
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("\(occurrence.name) starts now")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
            }
            Text("\(Schedule.range(startMinute: occurrence.startMinute, duration: occurrence.duration)) · starts by itself in \(TimeFormatter.clock(left))")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .padding(.leading, 18)
            HStack(spacing: 5) {
                Button("Start") { schedule.start(prompt.blockID) }
                    .buttonStyle(PillButtonStyle(prominent: true))
                Button("In 5 min") { schedule.snooze(prompt.blockID) }
                    .buttonStyle(PillButtonStyle())
                Button("Skip today") { schedule.skipToday(prompt.blockID) }
                    .buttonStyle(PillButtonStyle())
            }
            .padding(.leading, 18)
            .padding(.top, 6)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.13)))
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(occurrence.name) starts now")
    }
}

/// "Next: Email at 1:00 PM" under the timer.
struct NextBlockLine: View {
    let entry: ScheduleStore.Entry
    let tomorrow: Bool
    @ObservedObject var ui: WidgetUIState
    @ObservedObject var schedule: ScheduleStore
    let actions: WidgetActions
    let scale: CGFloat

    var body: some View {
        Button {
            ui.editBlock(entry.block.id, schedule: schedule)
            actions.focusPanel()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar").font(.system(size: 10, weight: .semibold))
                Text("Next")
                Text(entry.occurrence.name).fontWeight(.semibold).foregroundStyle(Theme.primaryText).lineLimit(1)
                Text("\(tomorrow ? "tomorrow " : "")at \(Schedule.time(entry.occurrence.startMinute))").lineLimit(1)
            }
            .font(.system(size: 11.5 * min(scale, 1.15)))
            .foregroundStyle(Theme.secondaryText)
        }
        .buttonStyle(.plain)
        .padding(.leading, 33 * scale)
        .padding(.trailing, 10)
        .padding(.bottom, 7)
        .help("Click to change or skip it")
    }
}

/// Today's plan, in the expanded widget.
private struct TodaySection: View {
    @ObservedObject var ui: WidgetUIState
    @ObservedObject var schedule: ScheduleStore
    let actions: WidgetActions
    let scale: CGFloat
    @State private var showEarlier = false

    var body: some View {
        // What's still ahead; earlier and skipped items fold away.
        let all = schedule.today()
        let finished: Set<ScheduleStore.EntryState> = [.done, .passed, .skipped]
        let earlier = all.filter { finished.contains($0.state) }
        let entries = showEarlier ? all : all.filter { !finished.contains($0.state) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TODAY")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button {
                    ui.editBlock(nil, schedule: schedule)
                    actions.focusPanel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                        Text("Plan")
                    }
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .help("Plan something for later today. Or type “Deep work weekdays at 9” for a routine.")
            }
            .padding(.leading, 13 * scale)
            .padding(.trailing, 7 * scale)
            .padding(.top, 2)

            if entries.isEmpty {
                Text(schedule.blocks.isEmpty ? "Plan from ⌥ Space: “Client call at 2pm for 30m”" : earlier.isEmpty ? "Nothing planned today" : "Nothing else today")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 13 * scale)
                    .padding(.bottom, 7)
            }
            ForEach(entries) { entry in
                BlockRow(entry: entry, open: {
                    ui.editBlock(entry.block.id, schedule: schedule)
                    actions.focusPanel()
                }, skip: {
                    schedule.skipToday(entry.block.id, undo: entry.state == .skipped)
                }, remove: {
                    ui.delete(entry.block.id, schedule: schedule)
                })
            }
            if !earlier.isEmpty {
                Button(showEarlier ? "Hide earlier" : "Show \(earlier.count) earlier") { showEarlier.toggle() }
                    .buttonStyle(QuietButtonStyle())
                    .padding(.leading, 6 * scale)
            }
        }
        .padding(.bottom, 3)
    }
}

private struct BlockRow: View {
    let entry: ScheduleStore.Entry
    let open: () -> Void
    let skip: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    private var faded: Bool {
        let quiet: [ScheduleStore.EntryState] = [.done, .passed, .skipped]
        return quiet.contains(entry.state)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                // Just the start: the name gets the room. The full range is in the tooltip.
                Text(Schedule.time(entry.occurrence.startMinute))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(faded ? Theme.tertiaryText : Theme.secondaryText)
                    .frame(width: 60, alignment: .leading)
                Text(entry.occurrence.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(faded ? Theme.tertiaryText : Theme.primaryText)
                    .strikethrough(entry.state == .skipped)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if entry.occurrence.edited {
                    Tag(text: "today", style: .plain).help("Changed for today only")
                } else if entry.block.isRepeating {
                    Image(systemName: "repeat").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                }
                switch entry.state {
                case .running: Tag(text: "Now", style: .strong)
                case .next: Tag(text: "Next", style: .soft)
                case .due: Tag(text: "Starting", style: .soft)
                case .done: Tag(text: "Done", style: .plain)
                case .skipped: Tag(text: "Skipped", style: .plain)
                case .upcoming, .passed: EmptyView()
                }
                // Easy to remove: hover and click ×. Undo shows at the top.
                Button(action: remove) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 20))
                    .opacity(hovering ? 1 : 0)
                    .help(entry.block.isRepeating ? "Delete this routine" : "Delete")
                    .accessibilityLabel("Delete \(entry.occurrence.name)")
            }
            .padding(.leading, 13)
            .padding(.trailing, 5)
            .frame(height: 26)
            .background(hovering ? Theme.control : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(Schedule.range(startMinute: entry.occurrence.startMinute, duration: entry.occurrence.duration))\((entry.block.steps?.count ?? 0) > 1 ? " · \(entry.block.steps?.count ?? 0) time blocks" : ""). Click to change it.")
        .contextMenu {
            Button("Edit…", action: open)
            Button(entry.state == .skipped ? "Don’t Skip Today" : "Skip Today", action: skip)
            Divider()
            Button(entry.block.isRepeating ? "Delete Routine" : "Delete", action: remove)
        }
        .accessibilityAction(named: "Delete", remove)
        .accessibilityLabel("\(entry.occurrence.name), \(Schedule.range(startMinute: entry.occurrence.startMinute, duration: entry.occurrence.duration))")
    }
}

private struct Tag: View {
    enum Style { case strong, soft, plain }
    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(style == .strong ? Color.white : style == .soft ? Theme.accent : Theme.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(style == .strong ? Theme.accent : style == .soft ? Theme.accent.opacity(0.14) : Color.clear))
    }
}

/// Create or change a block: name, drag it on a timeline, length, repeat days.
/// For a repeating block that's on today, a change can be for today only.
private struct BlockEditor: View {
    @ObservedObject var ui: WidgetUIState
    @ObservedObject var schedule: ScheduleStore
    let actions: WidgetActions
    @FocusState private var nameFocused: Bool
    @State private var splitText = ""

    private static let lengths: [TimeInterval] = [900, 1_500, 1_800, 2_700, 3_600, 5_400, 7_200]

    var body: some View {
        if let draft = ui.blockDraft {
            content(draft)
        }
    }

    private func binding<T>(_ key: WritableKeyPath<BlockDraft, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { ui.blockDraft?[keyPath: key] ?? fallback },
                set: { ui.blockDraft?[keyPath: key] = $0 })
    }

    @ViewBuilder
    private func content(_ draft: BlockDraft) -> some View {
        let block = draft.id.flatMap { schedule.block($0) }
        let todayOcc = draft.id.flatMap { schedule.occurrenceToday($0) }
        let key = schedule.dayKey
        let skipped = block?.status[key] == .skipped
        let twoWay = block?.isRepeating == true && todayOcc != nil && draft.changedTime && !draft.changedRepeat
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(draft.id != nil ? (draft.days == nil ? "EDIT WORK SESSION" : "EDIT ROUTINE") : (draft.days == nil ? "PLAN A WORK SESSION" : "NEW ROUTINE"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(IconButtonStyle(size: 22, tint: Theme.secondaryText))
                    .help("Close without saving (esc)")
                    .accessibilityLabel("Close")
            }
            .padding(.bottom, 4)
            TextField("What is it for?", text: binding(\.name, ""))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .semibold))
                .focused($nameFocused)
                .onSubmit { save(todayOnly: false) }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(nameFocused ? Theme.accent : Color.clear, lineWidth: 1))
                .onAppear { if draft.name.isEmpty { DispatchQueue.main.async { nameFocused = true } } }

            // Click a time to type it exactly; drag on the timeline for rough moves.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TimeEntry(minute: draft.startMinute, label: "Start time") { m in
                    ui.blockDraft?.startMinute = m
                    ui.blockDraft?.windowStart = BlockTimeline.window(around: m)
                }
                Text("–").font(Theme.digits(19)).foregroundStyle(Theme.tertiaryText)
                TimeEntry(minute: (draft.startMinute + Int(draft.duration / 60)) % 1_440, label: "End time") { m in
                    var length = m - draft.startMinute
                    if length <= 0 { length += 1_440 }
                    ui.blockDraft?.duration = TimeInterval(max(5, min(16 * 60, length)) * 60)
                }
                Spacer()
                Text(TimeFormatter.compact(draft.duration))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.top, 11)
            .padding(.bottom, 6)

            BlockTimeline(ui: ui, schedule: schedule)

            // − and + move by the step; dragging and scrolling use it too.
            row("Step") {
                HStack(spacing: 2) {
                    ForEach([1, 5, 10], id: \.self) { m in
                        Button("\(m) min") { ui.nudgeStep = m }
                            .buttonStyle(StepTabStyle(selected: ui.nudgeStep == m))
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
            }
            row("Start") {
                nudgeButton("−", "Earlier by \(ui.nudgeStep) min") { ui.nudge(-1, length: false) }
                Text(Schedule.time(draft.startMinute))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
                    .frame(minWidth: 64)
                nudgeButton("+", "Later by \(ui.nudgeStep) min") { ui.nudge(1, length: false) }
            }
            row("Length") {
                nudgeButton("−", "\(ui.nudgeStep) min shorter") { ui.nudge(-1, length: true) }
                Text(TimeFormatter.compact(draft.duration))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
                    .frame(minWidth: 64)
                nudgeButton("+", "\(ui.nudgeStep) min longer") { ui.nudge(1, length: true) }
                ForEach([1_500.0, 2_700, 3_600], id: \.self) { l in lengthChip(l, draft) }
            }
            row("Repeat") {
                Button(onceTitle(draft, key)) {
                    let cal = Calendar.current
                    let nowMinute = cal.component(.hour, from: schedule.now) * 60 + cal.component(.minute, from: schedule.now)
                    ui.blockDraft?.days = nil
                    if draft.startMinute <= nowMinute, let t = cal.date(byAdding: .day, value: 1, to: schedule.now) {
                        ui.blockDraft?.date = Schedule.dayKey(t)
                    } else {
                        ui.blockDraft?.date = key
                    }
                }
                .buttonStyle(PillButtonStyle(selected: draft.days == nil))
                Button("Weekdays") { ui.blockDraft?.days = [1, 2, 3, 4, 5] }
                    .buttonStyle(PillButtonStyle(selected: Set(draft.days ?? []) == Set(1...5)))
                Button("Every day") { ui.blockDraft?.days = Array(0...6) }
                    .buttonStyle(PillButtonStyle(selected: Set(draft.days ?? []) == Set(0...6)))
            }
            row("") {
                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in
                    Button(String(Schedule.shortDayNames[d].prefix(1))) {
                        var set = Set(draft.days ?? [])
                        if set.contains(d) { set.remove(d) } else { set.insert(d) }
                        ui.blockDraft?.days = set.isEmpty ? nil : set.sorted()
                    }
                    .buttonStyle(PillButtonStyle(selected: draft.days?.contains(d) == true, square: true))
                    .help(Schedule.shortDayNames[d])
                }
            }

            splitSection(draft)

            Text(hint(twoWay: twoWay, block: block))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)

            HStack(spacing: 6) {
                if let id = draft.id {
                    Button(draft.days == nil ? "Delete" : "Delete routine") {
                        ui.delete(id, schedule: schedule)
                        actions.releaseFocus()
                    }
                    .buttonStyle(PillButtonStyle(destructive: true))
                }
                if let id = draft.id, todayOcc != nil, !twoWay {
                    Button(skipped ? "Don’t skip" : "Skip today") {
                        schedule.skipToday(id, undo: skipped)
                    }
                    .buttonStyle(PillButtonStyle())
                }
                Spacer()
                Button("Cancel") { close() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if twoWay, let block {
                    Button("Just today") { save(todayOnly: true) }
                        .buttonStyle(PillButtonStyle())
                    Button(allLabel(block)) { save(todayOnly: false) }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(draft.id != nil ? "Save" : draft.days == nil ? "Plan it" : "Add routine") { save(todayOnly: false) }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 12)
        }
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    /// Split the session into time blocks: type them, or 2/3/4 equal parts.
    @ViewBuilder
    private func splitSection(_ draft: BlockDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(draft.steps.map { "\($0.count) time blocks" } ?? "Time blocks")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                if draft.steps != nil {
                    Button("Don’t split") { ui.blockDraft?.steps = nil }
                        .buttonStyle(PillButtonStyle())
                } else {
                    ForEach([2, 3, 4], id: \.self) { n in
                        Button("\(n)") { splitEvenly(n, draft) }
                            .buttonStyle(PillButtonStyle(square: true))
                            .help("Split into \(n) equal parts")
                    }
                }
            }
            if let steps = draft.steps {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { item in
                        HStack(spacing: 6) {
                            Text(Schedule.time(draft.startMinute + Int(steps.prefix(item.offset).reduce(0) { $0 + $1.seconds } / 60), suffix: false))
                                .foregroundStyle(Theme.tertiaryText)
                                .frame(width: 34, alignment: .leading)
                            Text(item.element.name).foregroundStyle(Theme.secondaryText).lineLimit(1)
                            Spacer()
                            Text(TimeFormatter.compact(item.element.seconds)).foregroundStyle(Theme.tertiaryText)
                            Button { removeStep(item.offset) } label: { Image(systemName: "xmark") }
                                .buttonStyle(IconButtonStyle(size: 18))
                                .help("Remove this time block")
                        }
                        .font(.system(size: 11.5).monospacedDigit())
                    }
                }
            }
            TextField(draft.steps == nil ? "Or type them: outline 30m, write 1h, edit 30m" : "Retype them: outline 30m, write 1h", text: $splitText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
                .onSubmit {
                    guard var d = ui.blockDraft else { return }
                    applySplit(&d)
                    ui.blockDraft = d
                }
        }
        .padding(.top, 12)
    }

    private func splitEvenly(_ n: Int, _ draft: BlockDraft) {
        let each = max(60, (draft.duration / Double(n) / 60).rounded(.down) * 60)
        let base = draft.name.isEmpty ? "Part" : draft.name
        ui.blockDraft?.steps = (0..<n).map { i in
            TimeBlock(name: "\(base) \(i + 1)", seconds: i == n - 1 ? draft.duration - each * Double(n - 1) : each)
        }
    }

    private func removeStep(_ i: Int) {
        guard var steps = ui.blockDraft?.steps, steps.indices.contains(i) else { return }
        let gone = steps.remove(at: i)
        if steps.count < 2 {
            ui.blockDraft?.steps = nil
        } else {
            steps[max(0, i - 1)].seconds += gone.seconds
            ui.blockDraft?.steps = steps
        }
    }

    private func onceTitle(_ draft: BlockDraft, _ key: String) -> String {
        guard draft.days == nil else { return "Today" }
        if draft.date == key { return "Today" }
        if let t = Calendar.current.date(byAdding: .day, value: 1, to: schedule.now), draft.date == Schedule.dayKey(t) { return "Tomorrow" }
        return "Once"
    }

    private func nudgeButton(_ title: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(PillButtonStyle(square: true))
            .help(help)
            .accessibilityLabel(help)
    }

    private func stepTitle(_ d: Int) -> String { d > 0 ? "+\(d)" : "−\(-d)" }

    private func hint(twoWay: Bool, block: ScheduledBlock?) -> String {
        guard twoWay, let block else { return "Hover the timeline and scroll to nudge the start (⇧ scroll for the length), drag it, or click a time to type it." }
        let all = allLabel(block)
        return "Save this change for today only, or for " + all.prefix(1).lowercased() + all.dropFirst() + "."
    }

    private func lengthChip(_ l: TimeInterval, _ draft: BlockDraft) -> some View {
        Button(TimeFormatter.compact(l)) { ui.blockDraft?.duration = l }
            .buttonStyle(PillButtonStyle(selected: draft.duration == l))
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 50, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private func allLabel(_ block: ScheduledBlock) -> String {
        switch schedule.describeDays(block) {
        case "Every day": return "Every day"
        case "Weekdays": return "All weekdays"
        case "Weekends": return "All weekends"
        case let d: return "Every " + d.replacingOccurrences(of: ", ", with: "/")
        }
    }

    private func save(todayOnly: Bool) {
        guard var draft = ui.blockDraft else { return }
        if !splitText.trimmingCharacters(in: .whitespaces).isEmpty { applySplit(&draft) }
        let id = schedule.save(draft, todayOnly: todayOnly)
        close()
        if let id { ui.confirmation = .init(blockID: id, updated: draft.id != nil, until: Date().addingTimeInterval(15)) }
    }

    /// "outline 30m, write 1h": the session's time blocks. Unused time becomes a last block.
    private func applySplit(_ draft: inout BlockDraft) {
        var steps = SessionParser.steps(from: splitText)
        guard !steps.isEmpty else { return }
        let total = steps.reduce(0) { $0 + $1.seconds }
        if total < draft.duration - 59 {
            steps.append(TimeBlock(name: draft.name.isEmpty ? "More time" : draft.name, seconds: draft.duration - total))
        } else if total > draft.duration {
            draft.duration = total
        }
        draft.steps = steps.count > 1 ? steps : nil
        splitText = ""
    }

    private func close() {
        ui.blockDraft = nil
        actions.releaseFocus()
    }
}

/// Eight hours around the block. Drag it to move; drag its right edge to resize.
/// Other blocks today show as grey shapes so you can see the gaps.
struct BlockTimeline: View {
    /// Four hours: wide enough to see what's around, close enough to aim.
    static let span = 240

    /// The window that shows `minute` comfortably, keeping `current` if it already does.
    static func window(around minute: Int, current: Int? = nil) -> Int {
        if let current, minute >= current + 15, minute <= current + span - 45 { return current }
        return max(0, min(1_440 - span, (minute - 60) / 30 * 30))
    }
    @ObservedObject var ui: WidgetUIState
    @ObservedObject var schedule: ScheduleStore
    @State private var dragOrigin: (start: Int, duration: TimeInterval)?

    private let width: CGFloat = 320
    private let height: CGFloat = 46

    var body: some View {
        if let draft = ui.blockDraft {
            let w0 = draft.windowStart
            let x: (Int) -> CGFloat = { CGFloat($0 - w0) / CGFloat(Self.span) * width }
            let others = schedule.today().filter { $0.block.id != draft.id }
            let cal = Calendar.current
            let nowMinute = cal.component(.hour, from: schedule.now) * 60 + cal.component(.minute, from: schedule.now)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control)
                ForEach(Array(stride(from: (w0 + 59) / 60 * 60, through: w0 + Self.span, by: 60)), id: \.self) { m in
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: height).offset(x: x(m))
                    Text(Schedule.time(m).replacingOccurrences(of: ":00", with: "").replacingOccurrences(of: " ", with: ""))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiaryText)
                        .offset(x: x(m) + 3, y: 3)
                }
                ForEach(others) { o in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.controlHover)
                        .frame(width: max(4, CGFloat(o.occurrence.duration / 60) / CGFloat(Self.span) * width), height: 22)
                        .offset(x: x(o.occurrence.startMinute), y: 18)
                }
                if nowMinute >= w0 && nowMinute <= w0 + Self.span {
                    Rectangle().fill(Theme.accent.opacity(0.7)).frame(width: 1.5, height: height).offset(x: x(nowMinute))
                }
                block(draft, x: x(draft.startMinute))
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Time")
            .accessibilityValue(Schedule.range(startMinute: draft.startMinute, duration: draft.duration))
            .accessibilityAdjustableAction { direction in
                let d = direction == .increment ? 5 : -5
                ui.blockDraft?.startMinute = max(0, min(1_435, draft.startMinute + d))
            }
        }
    }

    private func block(_ draft: BlockDraft, x: CGFloat) -> some View {
        let w = max(18, CGFloat(draft.duration / 60) / CGFloat(Self.span) * width)
        return ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.accent)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            Text(draft.name.isEmpty ? "Block" : draft.name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Resize grip.
            Capsule()
                .fill(Color.white.opacity(0.75))
                .frame(width: 2, height: 10)
                .padding(.trailing, 4)
                .frame(width: 12, height: 26)
                .contentShape(Rectangle())
                .highPriorityGesture(drag(resizing: true))
        }
        .frame(width: w, height: 26)
        .contentShape(Rectangle())
        .gesture(drag(resizing: false))
        .offset(x: x, y: 16)
    }

    private func drag(resizing: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                guard let draft = ui.blockDraft else { return }
                if dragOrigin == nil { dragOrigin = (draft.startMinute, draft.duration) }
                guard let origin = dragOrigin else { return }
                // Snaps to 5 minutes; hold ⌥ for single minutes.
                let step = NSEvent.modifierFlags.contains(.option) ? 1 : ui.nudgeStep
                let raw = Double(g.translation.width / width * CGFloat(Self.span))
                if resizing {
                    let end = Int(origin.duration / 60) + Int(raw.rounded())
                    let snapped = step == 1 ? end : Int((Double(end) / Double(step)).rounded()) * step
                    ui.blockDraft?.duration = TimeInterval(max(5, min(8 * 60, snapped)) * 60)
                } else {
                    let start = origin.start + Int(raw.rounded())
                    let snapped = step == 1 ? start : Int((Double(start) / Double(step)).rounded()) * step
                    ui.blockDraft?.startMinute = max(0, min(1_440 - 5, snapped))
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                // Keep the block in view after a long drag.
                if let d = ui.blockDraft {
                    ui.blockDraft?.windowStart = BlockTimeline.window(around: d.startMinute, current: d.windowStart)
                }
            }
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var selected = false
    var square = false
    var destructive = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let filled = prominent || selected
        configuration.label
            .font(.system(size: 11.5, weight: prominent ? .semibold : .medium).monospacedDigit())
            .foregroundStyle(filled ? Color.white : destructive ? Color.red : (hovering ? Theme.primaryText : Theme.secondaryText))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, square ? 0 : 9)
            .frame(minWidth: square ? 24 : nil)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(filled ? Theme.accent : destructive ? Color.clear : (configuration.isPressed || hovering ? Theme.controlHover : Theme.control))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A part of the editor's 1 min · 5 min · 10 min step switch.
private struct StepTabStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium).monospacedDigit())
            .foregroundStyle(selected || hovering ? Theme.primaryText : Theme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Theme.surface : Color.clear)
                    .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Type a time into the dial: "30", "45m", "1:30".
private struct DialTypeField: View {
    @ObservedObject var ui: WidgetUIState
    @ObservedObject var store: TimerStore
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(TimeFormatter.compact(ui.dialValue), text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(Theme.digits(30))
            .foregroundStyle(Theme.primaryText)
            .frame(width: 112)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1))
            .focused($focused)
            .onSubmit {
                if let d = DurationParser.parse(text) { ui.setDial(d.seconds, store: store) }
                ui.dialTyping = false
            }
            .onExitCommand { ui.dialTyping = false }
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onChange(of: focused) { f in if !f { ui.dialTyping = false } }
            .accessibilityLabel("Type a time")
    }
}
