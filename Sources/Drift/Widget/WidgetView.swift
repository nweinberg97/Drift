import AppKit
import DriftCore
import SwiftUI

@MainActor
final class WidgetUIState: ObservableObject {
    @Published var expanded = false
    @Published var editingID: UUID?
    @Published var renamingID: UUID?
    @Published var draft = ""
    @Published var editError = false
    /// Shown for a moment after hiding, so the widget never just vanishes.
    @Published var hideHint = false
    /// A finished timer is chiming; the widget pulses until it's handled.
    @Published var alerting = false
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

            if ui.expanded && !ui.hideHint {
                ExpandedSection(store: store, settings: settings, ui: ui, scale: scale, actions: actions)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: ui.expanded && !ui.hideHint ? expandedWidth : nil, alignment: .leading)
        .driftSurface(cornerRadius: Theme.cornerRadius * min(scale, 1.15), opacity: settings.widgetOpacity)
        .overlay(AlertPulse(active: ui.alerting, cornerRadius: Theme.cornerRadius * min(scale, 1.15)))
        .contextMenu { contextMenu }
        .animation(reduceMotion ? nil : Theme.quick, value: ui.expanded)
        .animation(reduceMotion ? nil : Theme.quick, value: ui.hideHint)
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
                Button("Edit Time…") { beginEdit(t) }
                Button("Name…") { beginRename(t) }
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

    private func beginEdit(_ t: DriftTimer) {
        ui.expanded = true
        ui.renamingID = nil
        ui.draft = TimeFormatter.compact(t.remaining(at: Date()))
        ui.editingID = t.id
        actions.focusPanel()
    }

    private func beginRename(_ t: DriftTimer) {
        ui.expanded = true
        ui.editingID = nil
        ui.draft = t.name ?? ""
        ui.renamingID = t.id
        actions.focusPanel()
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
                if let name = timer.displayName {
                    Text(name)
                        .font(.system(size: 12 * scale, weight: .medium))
                        .foregroundStyle(timer.pomodoro?.isBreak == true ? Theme.accent : Theme.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: 96 * scale, alignment: .leading)
                }
                if timer.isFinished {
                    Text("Done")
                        .font(Theme.digits(22 * scale))
                        .foregroundStyle(Theme.accent)
                } else {
                    TimeText(remaining: remaining, size: 22 * scale, color: timeColor)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { actions.acknowledge(); ui.expanded.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(ui.expanded ? "Collapses timer controls" : "Shows timer controls")
            .accessibilityAction { ui.expanded.toggle() }

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
                    Text("type or say a timer, from any app")
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

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let t = store.primary {
                ProgressLine(progress: t.progress(at: store.now), active: t.isRunning)
                    .padding(.horizontal, 13 * scale)

                if ui.editingID == t.id || ui.renamingID == t.id {
                    editField(for: t)
                } else {
                    if let cycle = t.pomodoro {
                        PomodoroStrip(cycle: cycle, scale: scale)
                    } else if !t.isFinished {
                        nameLine(for: t)
                    }
                    controls(for: t)
                }
            }

            let others = store.others
            if !others.isEmpty {
                Hairline()
                VStack(spacing: 0) {
                    ForEach(others) { other in
                        OtherTimerRow(timer: other, store: store, scale: scale)
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

    /// "Add a name" is right there, so naming is discoverable.
    private func nameLine(for t: DriftTimer) -> some View {
        Button { beginRename(t) } label: {
            HStack(spacing: 5) {
                Image(systemName: "pencil").font(.system(size: 10, weight: .semibold))
                Text(t.name ?? "Name this timer")
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(t.name == nil ? Theme.tertiaryText : Theme.secondaryText)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 13 * scale)
        .padding(.top, 2)
        .help("Give this timer a name, like Email or Laundry")
        .accessibilityLabel(t.name.map { "Name: \($0). Rename" } ?? "Name this timer")
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
                Button("Edit time") { beginEdit(t) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Set the time left, e.g. 10m or 1:30")
                Spacer()
            }
        }
        .padding(.horizontal, 7 * scale)
        .padding(.vertical, 5)
    }

    private func editField(for t: DriftTimer) -> some View {
        let renaming = ui.renamingID == t.id
        return HStack(spacing: 6) {
            TextField(renaming ? "Name, e.g. Email" : "Time left, e.g. 10m or 1:30", text: $ui.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($fieldFocused)
                .onSubmit { commit(t, renaming: renaming) }
                .onExitCommand { endEditing() }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(ui.editError ? Theme.accent : Color.clear, lineWidth: 1)
                )
            Button("Save") { commit(t, renaming: renaming) }
                .buttonStyle(QuietButtonStyle(prominent: true))
        }
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 6)
        .onAppear {
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private func beginEdit(_ t: DriftTimer) {
        ui.renamingID = nil
        ui.draft = TimeFormatter.compact(t.remaining(at: Date()))
        ui.editingID = t.id
        actions.focusPanel()
    }

    private func beginRename(_ t: DriftTimer) {
        ui.editingID = nil
        ui.draft = t.name ?? ""
        ui.renamingID = t.id
        actions.focusPanel()
    }

    private func commit(_ t: DriftTimer, renaming: Bool) {
        if renaming {
            store.rename(t.id, to: ui.draft)
            endEditing()
            return
        }
        guard let parsed = DurationParser.parse(ui.draft) else {
            ui.editError = true
            NSSound.beep()
            return
        }
        store.setRemaining(t.id, seconds: parsed.seconds)
        if let label = parsed.label { store.rename(t.id, to: label) }
        endEditing()
    }

    private func endEditing() {
        ui.editingID = nil
        ui.renamingID = nil
        ui.editError = false
        ui.draft = ""
        actions.releaseFocus()
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
    let scale: CGFloat
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(timer: timer, size: 6 * scale)
            Text(timer.displayName ?? TimeFormatter.compact(timer.duration) + " timer")
                .font(.system(size: 12 * scale, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(timer.isFinished ? "Done" : TimeFormatter.clock(timer.remaining(at: store.now)))
                .font(Theme.digits(13 * scale))
                .foregroundStyle(timer.isFinished ? Theme.accent : (timer.isPaused ? Theme.tertiaryText : Theme.primaryText))
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
        .accessibilityElement(children: .combine)
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
