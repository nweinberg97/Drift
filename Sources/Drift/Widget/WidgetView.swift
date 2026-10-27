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
    /// Shown for a moment after hiding, so the widget never just vanishes.
    @Published var hideHint = false
    /// A finished timer is chiming; the widget pulses until it's handled.
    @Published var alerting = false
}

extension WidgetUIState {
    static let dialMaximum: TimeInterval = 12 * 3_600

    func beginRename(_ t: DriftTimer) {
        guard t.pomodoro == nil else { return }
        closeDial(commit: true, store: nil)
        draft = t.name ?? ""
        renamingID = t.id
    }

    func openDial(_ t: DriftTimer, now: Date) {
        guard !t.isFinished else { return }
        renamingID = nil
        dialOriginal = t.remaining(at: now)
        dialValue = max(60, (dialOriginal / 60).rounded() * 60)
        dialID = t.id
    }

    /// Moves the dial; the timer follows live, a minute at a time.
    func setDial(_ value: TimeInterval, store: TimerStore) {
        guard let id = dialID else { return }
        let next = min(Self.dialMaximum, max(60, (value / 60).rounded() * 60))
        guard next != dialValue else { return }
        dialValue = next
        store.setRemaining(id, seconds: next)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Done keeps the new time; Cancel puts the old one back.
    func closeDial(commit: Bool, store: TimerStore?) {
        guard let id = dialID else { return }
        if !commit, let store, store.timer(id) != nil {
            store.setRemaining(id, seconds: dialOriginal)
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
    let actions: WidgetActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var scale: CGFloat { settings.widgetSize.scale }
    private var expandedWidth: CGFloat { 272 * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if ui.hideHint {
                HideHint(settings: settings, scale: scale)
            } else if let primary = store.primary {
                PrimaryRow(timer: primary, store: store, ui: ui, scale: scale,
                           othersCount: store.others.count, actions: actions)
            } else {
                IdleRow(store: store, settings: settings, ui: ui, scale: scale, actions: actions)
            }

            if let id = ui.dialID, let t = store.timer(id), !ui.hideHint {
                DialSection(timer: t, store: store, settings: settings, ui: ui, actions: actions)
                    .transition(.opacity)
            } else if ui.expanded && !ui.hideHint {
                ExpandedSection(store: store, settings: settings, ui: ui, scale: scale, actions: actions)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: (ui.expanded || ui.dialID != nil) && !ui.hideHint ? expandedWidth : nil, alignment: .leading)
        .driftSurface(cornerRadius: Theme.cornerRadius * min(scale, 1.15), opacity: settings.widgetOpacity)
        .overlay(AlertPulse(active: ui.alerting, cornerRadius: Theme.cornerRadius * min(scale, 1.15)))
        .contextMenu { contextMenu }
        .animation(reduceMotion ? nil : Theme.quick, value: ui.expanded)
        .animation(reduceMotion ? nil : Theme.quick, value: ui.hideHint)
        .animation(reduceMotion ? nil : Theme.quick, value: ui.dialID)
        .animation(reduceMotion ? nil : Theme.quick, value: store.timers.map(\.id))
        .fixedSize()
        .reportSize(actions.resize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drift timer")
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let t = store.primary {
            if t.isFinished {
                Button("Add 5 Minutes") { actions.acknowledge(); store.adjust(t.id, by: 300) }
                Button("Dismiss") { actions.acknowledge(); store.remove(t.id) }
            } else {
                Button(t.isRunning ? "Pause" : "Resume") { store.toggle(t.id) }
                Button("Add 5 Minutes") { store.adjust(t.id, by: 300) }
                Button("Remove 5 Minutes") { store.adjust(t.id, by: -300) }
                    .disabled(t.remaining(at: store.now) <= 300)
                Button("Change Time…") { ui.openDial(t, now: Date()); actions.focusPanel() }
                if t.pomodoro == nil { Button(t.name == nil ? "Add Task…" : "Rename…") { ui.beginRename(t); actions.focusPanel() } }
                if let cycle = t.pomodoro {
                    Button("Skip to \(cycle.upNext.name)") { store.skipPhase(t.id) }
                }
                Button("Duplicate") { store.duplicate(t.id) }
                Divider()
                Button(t.pomodoro == nil ? "Cancel Timer" : "End Pomodoro") { store.remove(t.id) }
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

    private var remaining: TimeInterval { timer.remaining(at: store.now) }
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
                } else {
                    Button { toggleDial() } label: {
                        TimeText(remaining: remaining, size: 22 * scale, color: timeColor)
                    }
                    .buttonStyle(EditableTextStyle(active: ui.dialID == timer.id))
                    .help("Click to change the time")
                    .accessibilityLabel(accessibilityText)
                    .accessibilityHint("Opens a dial to change the time")
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
                            .help(timer.pomodoro == nil ? "Cancel this timer" : "End Pomodoro")
                            .accessibilityLabel(timer.pomodoro == nil ? "Cancel timer" : "End Pomodoro")
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
            ui.openDial(timer, now: Date())
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
private struct ExpandButtonStyle: ButtonStyle {
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

// MARK: - Idle (no timers)

private struct IdleRow: View {
    @ObservedObject var store: TimerStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: WidgetUIState
    let scale: CGFloat
    let actions: WidgetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack(spacing: 9 * scale) {
                Circle()
                    .strokeBorder(Theme.tertiaryText, lineWidth: 1.25)
                    .frame(width: 7 * scale, height: 7 * scale)
                    .frame(width: 11 * scale, height: 11 * scale)

                TimeText(remaining: settings.defaultDuration, size: 22 * scale, color: Theme.secondaryText)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.openComposer() }
                    .help("Choose a duration")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("New timer")
                    .accessibilityAction { actions.openComposer() }

                Spacer(minLength: 6)

                Button { store.create(seconds: settings.defaultDuration) } label: {
                    Image(systemName: "play.fill").offset(x: 0.5)
                }
                .buttonStyle(IconButtonStyle(size: 26 * scale, tint: Theme.accent))
                .help("Start \(TimeFormatter.compact(settings.defaultDuration))")
                .accessibilityLabel("Start \(TimeFormatter.spoken(settings.defaultDuration)) timer")
            }

            if let shortcut = settings.shortcuts[.newTimer] {
                HStack(spacing: 6) {
                    KeyCaps(text: shortcut.display)
                    Text("write a task and a time, from any app")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.leading, 20 * scale)
                .transition(.opacity)
            }
        }
        .padding(.leading, 13 * scale)
        .padding(.trailing, 7 * scale)
        .padding(.vertical, 7 * scale)
    }
}

// MARK: - Expanded

private struct ExpandedSection: View {
    @ObservedObject var store: TimerStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: WidgetUIState
    let scale: CGFloat
    let actions: WidgetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let t = store.primary {
                ProgressLine(progress: t.progress(at: store.now), active: t.isRunning)
                    .padding(.horizontal, 13 * scale)

                if let cycle = t.pomodoro {
                    PomodoroStrip(cycle: cycle, scale: scale)
                }
                controls(for: t)
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

            Hairline()
            FocusSoundRow(settings: settings, scale: scale)

            Hairline()
            HStack(spacing: 4) {
                Button { actions.openComposer() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("New timer")
                    }
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .help("Type a time like 25m or 45m writing")
                if let shortcut = settings.shortcuts[.newTimer] {
                    KeyCaps(text: shortcut.display)
                }
                Button { actions.openVoice() } label: { Image(systemName: "mic") }
                    .buttonStyle(IconButtonStyle(size: 24, tint: Theme.secondaryText))
                    .help("Say it: \"25 minutes for email\"")
                    .accessibilityLabel("Speak a timer")
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

    @ViewBuilder
    private func controls(for t: DriftTimer) -> some View {
        HStack(spacing: 2) {
            if t.isFinished {
                Button("+5 min") { actions.acknowledge(); store.adjust(t.id, by: 300) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Snooze for 5 minutes")
                Button("Restart") { actions.acknowledge(); store.resume(t.id) }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Dismiss") { actions.acknowledge(); store.remove(t.id) }
                    .buttonStyle(QuietButtonStyle(prominent: true))
            } else if let cycle = t.pomodoro {
                Button("Skip to \(cycle.upNext.name.lowercased())") { store.skipPhase(t.id) }
                    .buttonStyle(QuietButtonStyle())
                    .help("End this \(cycle.phaseName.lowercased()) now and start the \(cycle.upNext.name.lowercased())")
                Button("+5 min") { store.adjust(t.id, by: 300) }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
            } else {
                Button("−5 min") { store.adjust(t.id, by: -300) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(t.remaining(at: store.now) <= 301)
                    .accessibilityLabel("Remove 5 minutes")
                Button("+5 min") { store.adjust(t.id, by: 300) }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Add 5 minutes")
                Button("Set time…") { ui.openDial(t, now: Date()); actions.focusPanel() }
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
                    ui.openDial(timer, now: Date())
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
                if let name = timer.name {
                    Text(name)
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: size - 2, weight: .bold))
                        Text("Add task")
                    }
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                }
            }
            .buttonStyle(EditableTextStyle(active: false))
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: timer.name == nil, vertical: false)
            .help(timer.name == nil ? "Add what this timer is for" : "Click to rename")
            .accessibilityLabel(timer.name.map { "Task: \($0). Rename" } ?? "Add task")
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
private struct EditableTextStyle: ButtonStyle {
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
    let timer: DriftTimer
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
                Text(timer.displayName ?? "Timer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("drag, scroll or use arrows")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            DialFace(value: ui.dialValue)
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
                .gesture(turn)
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
                Button("Done") { finish(commit: true) }
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
        ui.closeDial(commit: commit, store: store)
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
                        .fill(Theme.tertiaryText.opacity(i % 5 == 0 ? 1 : 0.55))
                        .frame(width: i % 5 == 0 ? 1.6 : 0.9, height: i % 5 == 0 ? 6 : 3.5)
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
                    Text(hours > 0 ? "\(hours) h + minutes on the ring" : "Turn to adjust")
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
