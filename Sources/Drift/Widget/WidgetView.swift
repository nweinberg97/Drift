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
}

struct WidgetActions {
    var openComposer: () -> Void
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
    @State private var hovering = false

    private var scale: CGFloat { settings.widgetSize.scale }
    private var expandedWidth: CGFloat { 244 * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let primary = store.primary {
                PrimaryRow(timer: primary, store: store, ui: ui, scale: scale, hovering: hovering,
                           othersCount: store.others.count, actions: actions)
            } else {
                IdleRow(store: store, settings: settings, ui: ui, scale: scale, actions: actions)
            }

            if ui.expanded {
                ExpandedSection(store: store, settings: settings, ui: ui, scale: scale, actions: actions)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: ui.expanded ? expandedWidth : nil, alignment: .leading)
        .driftSurface(cornerRadius: Theme.cornerRadius * min(scale, 1.15), opacity: settings.widgetOpacity)
        .onHover { h in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovering = h }
        }
        .contextMenu { contextMenu }
        .animation(reduceMotion ? nil : Theme.quick, value: ui.expanded)
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
                Button("Add 5 Minutes") { store.adjust(t.id, by: 300) }
                Button("Dismiss") { store.remove(t.id) }
            } else {
                Button(t.isRunning ? "Pause" : "Resume") { store.toggle(t.id) }
                Button("Add 5 Minutes") { store.adjust(t.id, by: 300) }
                Button("Remove 5 Minutes") { store.adjust(t.id, by: -300) }
                    .disabled(t.remaining(at: store.now) <= 300)
                Button("Edit Time…") { beginEdit(t) }
                Button("Rename…") { beginRename(t) }
                Button("Duplicate") { store.duplicate(t.id) }
                Divider()
                Button("Cancel Timer") { store.remove(t.id) }
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
    let hovering: Bool
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
                        .foregroundStyle(Theme.secondaryText)
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
                if let cycle = timer.pomodoro, cycle.round > 1 {
                    Text("\(cycle.round)")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { ui.expanded.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(ui.expanded ? "Collapses timer controls" : "Shows timer controls")
            .accessibilityAction { ui.expanded.toggle() }

            Spacer(minLength: 2)

            HStack(spacing: 2) {
                if othersCount > 0 && !ui.expanded {
                    Button { ui.expanded = true } label: {
                        Text("+\(othersCount)")
                            .font(.system(size: 10.5 * scale, weight: .semibold).monospacedDigit())
                    }
                    .buttonStyle(IconButtonStyle(size: 24 * scale, tint: Theme.tertiaryText))
                    .help("Show all timers")
                    .accessibilityLabel("\(othersCount) more \(othersCount == 1 ? "timer" : "timers")")
                }

                if timer.isFinished {
                    Button { store.remove(timer.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 26 * scale))
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss finished timer")
                } else {
                    Button { store.toggle(timer.id) } label: {
                        Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                            .offset(x: timer.isRunning ? 0 : 0.5)
                    }
                    .buttonStyle(IconButtonStyle(size: 26 * scale, tint: timer.isRunning ? Theme.tertiaryText : Theme.accent))
                    .help(timer.isRunning ? "Pause" : "Resume")
                    .accessibilityLabel(timer.isRunning ? "Pause" : "Resume")
                }

                if hovering && !ui.expanded {
                    Button { actions.hide() } label: { Image(systemName: "minus") }
                        .buttonStyle(IconButtonStyle(size: 22 * scale, tint: Theme.tertiaryText))
                        .help("Hide widget — timers keep running")
                        .accessibilityLabel("Hide widget")
                        .transition(.opacity)
                }
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

            if !settings.hasLearnedShortcut, let shortcut = settings.shortcuts[.newTimer] {
                HStack(spacing: 6) {
                    KeyCaps(text: shortcut.display)
                    Text("new timer from anywhere")
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
            HStack(spacing: 6) {
                Button { actions.openComposer() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("New timer")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                if let shortcut = settings.shortcuts[.newTimer] {
                    KeyCaps(text: shortcut.display)
                }
                Spacer()
                Button { actions.hide() } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(IconButtonStyle(size: 22, tint: Theme.tertiaryText))
                    .help("Hide widget — timers keep running")
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
                Button("+5m") { store.adjust(t.id, by: 300) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Snooze for 5 minutes")
                Button("Restart") { store.resume(t.id) }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Dismiss") { store.remove(t.id) }
                    .buttonStyle(QuietButtonStyle(prominent: true))
            } else {
                Button("−5m") { store.adjust(t.id, by: -300) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(t.remaining(at: store.now) <= 301)
                    .accessibilityLabel("Remove 5 minutes")
                Button("+5m") { store.adjust(t.id, by: 300) }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Add 5 minutes")
                Button("Edit") { beginEdit(t) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Set the remaining time, e.g. 10m or 1:30")
                Spacer()
                Button("Cancel") { store.remove(t.id) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Cancel this timer")
            }
        }
        .padding(.horizontal, 7 * scale)
        .padding(.vertical, 5)
    }

    private func editField(for t: DriftTimer) -> some View {
        let renaming = ui.renamingID == t.id
        return HStack(spacing: 6) {
            TextField(renaming ? "Name" : "e.g. 10m, 1:30, 45m writing", text: $ui.draft)
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
            Button("Done") { commit(t, renaming: renaming) }
                .buttonStyle(QuietButtonStyle(prominent: true))
        }
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 6)
        .onAppear {
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private func beginEdit(_ t: DriftTimer) {
        ui.draft = TimeFormatter.compact(t.remaining(at: Date()))
        ui.editingID = t.id
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

private struct OtherTimerRow: View {
    let timer: DriftTimer
    @ObservedObject var store: TimerStore
    let scale: CGFloat
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(timer: timer, size: 6 * scale)
            Text(timer.displayName ?? TimeFormatter.compact(timer.duration))
                .font(.system(size: 12 * scale, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(timer.isFinished ? "Done" : TimeFormatter.clock(timer.remaining(at: store.now)))
                .font(Theme.digits(13 * scale))
                .foregroundStyle(timer.isFinished ? Theme.accent : (timer.isPaused ? Theme.tertiaryText : Theme.primaryText))
            if hovering {
                if !timer.isFinished {
                    Button { store.toggle(timer.id) } label: {
                        Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(IconButtonStyle(size: 20 * scale))
                    .accessibilityLabel(timer.isRunning ? "Pause" : "Resume")
                }
                Button { store.remove(timer.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 20 * scale))
                    .accessibilityLabel(timer.isFinished ? "Dismiss" : "Cancel")
            }
        }
        .frame(height: 26 * scale)
        .padding(.horizontal, 13 * scale)
        .background(hovering ? Theme.control : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.makePrimary(timer.id) }
        .help("Click to feature this timer")
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Feature") { store.makePrimary(timer.id) }
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
