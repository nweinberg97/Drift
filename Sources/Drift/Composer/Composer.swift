import AppKit
import Combine
import DriftCore
import SwiftUI

@MainActor
final class ComposerModel: ObservableObject {
    @Published var text = ""
    @Published var error: String?
    @Published var focusToken = 0
}

/// The Spotlight-style launcher: ⌥⌘T from anywhere, type "45m writing",
/// press Return. Also hosts voice input.
@MainActor
final class ComposerController: NSObject, NSWindowDelegate {
    let model = ComposerModel()
    private let panel = FloatingPanel()
    private let runner: CommandRunner
    private let settings: AppSettings
    private let voice: VoiceController
    private var cancellables = Set<AnyCancellable>()
    private var contentSize: CGSize = .zero
    private var anchorTop: CGFloat = 0

    init(runner: CommandRunner, settings: AppSettings, voice: VoiceController) {
        self.runner = runner
        self.settings = settings
        self.voice = voice
        super.init()

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.draggable = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.setAccessibilityTitle("New \(AppInfo.name) timer")
        panel.onEscape = { [weak self] in self?.close() }

        let view = ComposerView(
            model: model,
            settings: settings,
            voice: voice,
            preview: { [weak runner] text in
                runner?.preview(text) ?? CommandRunner.Preview(title: "", detail: nil, isValid: false)
            },
            plan: { [weak runner] text in runner?.plan(text) ?? .invalid },
            submit: { [weak self] in self?.submit() },
            startPreset: { [weak self] seconds in self?.startPreset(seconds) },
            startRecent: { [weak self] recent in self?.startRecent(recent) },
            startPomodoro: { [weak self] in self?.startPomodoro() },
            toggleVoice: { [weak self] in self?.toggleVoice() },
            close: { [weak self] in self?.close() },
            resize: { [weak self] size in self?.resize(to: size) }
        )
        let hosting = PanelHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting

        voice.onFinish = { [weak self] transcript in
            self?.handleTranscript(transcript)
        }

        // Tab takes the suggested length (or, the first time, the example).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, event.keyCode == 48,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            else { return event }
            return self.acceptSuggestion() ? nil : event
        }
    }

    private var keyMonitor: Any?

    /// Fills in what the launcher is suggesting. Returns false if there was nothing to take.
    func acceptSuggestion() -> Bool {
        let text = model.text
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            guard !settings.hasWrittenTask else { return false }
            model.text = "Write intro 25m"
            return true
        }
        if case .start(_, _, true) = runner.plan(text) {
            let base = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            model.text = base + " " + TimeFormatter.compact(settings.defaultDuration)
            return true
        }
        return false
    }

    var isOpen: Bool { panel.isVisible }

    func show(listening: Bool = false) {
        model.error = nil
        if !panel.isVisible {
            model.text = ""
            position()
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.makeKey()
        }
        model.focusToken += 1
        if listening && !voice.isListening { voice.start() }
    }

    func toggle(listening: Bool = false) {
        if panel.isVisible && panel.isKeyWindow && !listening {
            close()
        } else {
            show(listening: listening)
        }
    }

    /// The New Timer shortcut pressed while the launcher is already open:
    /// once to type, twice to talk.
    func shortcutPressedAgain() {
        panel.makeKey()
        model.error = nil
        if voice.isListening { voice.finish() } else { voice.start() }
    }

    func close() {
        voice.cancel()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.text = ""
        model.error = nil
    }

    // MARK: - Actions

    private func submit() {
        if voice.isListening { voice.finish(); return }
        switch runner.run(model.text) {
        case .done:
            settings.hasLearnedShortcut = true
            close()
        case let .failed(message):
            model.error = message
            NSSound.beep()
        }
    }

    /// A preset chip starts the task you've written (if any) for that long.
    private func startPreset(_ seconds: TimeInterval) {
        var name: String?
        if case let .start(_, task, true) = runner.plan(model.text) { name = task }
        runner.run(.start(seconds: seconds, name: name))
        close()
    }

    private func startRecent(_ recent: AppSettings.RecentTask) {
        runner.run(.start(seconds: recent.seconds, name: recent.name))
        close()
    }

    private func startPomodoro() {
        runner.run(.pomodoro(focus: CommandParser.defaultPomodoro.focus, rest: CommandParser.defaultPomodoro.rest))
        close()
    }

    private func toggleVoice() {
        model.error = nil
        voice.toggle()
    }

    private func handleTranscript(_ transcript: String) {
        model.text = transcript
        let preview = runner.preview(transcript)
        guard preview.isValid else {
            model.error = "Heard “\(transcript)”. Try “twenty five minutes for email”."
            model.focusToken += 1
            return
        }
        // A beat so you can see what was understood, then do it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.panel.isVisible, self.model.text == transcript else { return }
            self.submit()
        }
    }

    // MARK: - Layout

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let width: CGFloat = ComposerView.width
        let height = max(contentSize.height, 120)
        anchorTop = visible.maxY - visible.height * 0.2
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: anchorTop - height, width: width, height: height), display: false)
    }

    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        contentSize = CGSize(width: ceil(size.width), height: ceil(size.height))
        let frame = panel.frame
        let top = panel.isVisible ? frame.maxY : (anchorTop > 0 ? anchorTop : frame.maxY)
        panel.setFrame(NSRect(x: frame.minX, y: top - contentSize.height, width: contentSize.width, height: contentSize.height), display: true)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else dismisses, like Spotlight. Keep it open while
        // a permission prompt from voice is up.
        if voice.phase == .requesting { return }
        close()
    }
}

// MARK: - View

struct ComposerView: View {
    static let width: CGFloat = 580

    @ObservedObject var model: ComposerModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var voice: VoiceController
    let preview: (String) -> CommandRunner.Preview
    let plan: (String) -> CommandRunner.Plan
    let submit: () -> Void
    let startPreset: (TimeInterval) -> Void
    let startRecent: (AppSettings.RecentTask) -> Void
    let startPomodoro: () -> Void
    let toggleVoice: () -> Void
    let close: () -> Void
    let resize: (CGSize) -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentPlan: CommandRunner.Plan {
        plan(voice.isListening && model.text.isEmpty ? voice.transcript : model.text)
    }
    private var showRecents: Bool { model.text.isEmpty && !voice.isListening && !settings.recents.isEmpty }
    private var showCoach: Bool { model.text.isEmpty && !voice.isListening && !settings.hasWrittenTask }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            statusRow
            if showRecents { recentsList }
            if showCoach { coach }
            presetsRow
        }
        .frame(width: Self.width)
        .driftSurface(cornerRadius: 16)
        .fixedSize(horizontal: false, vertical: true)
        .reportSize(resize)
        .onChange(of: model.focusToken) { _ in focusField() }
        .onAppear { focusField() }
    }

    private func focusField() {
        DispatchQueue.main.async { focused = true }
    }

    // MARK: Rows

    private var inputRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 8, height: 8)
                .scaleEffect(voice.isListening ? 1 + CGFloat(voice.level) * 1.4 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: voice.level)
                .frame(width: 22)
                .accessibilityHidden(true)

            ZStack(alignment: .leading) {
                if voice.isListening && model.text.isEmpty {
                    Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                        .font(Self.fieldFont)
                        .foregroundStyle(voice.transcript.isEmpty ? Theme.tertiaryText : Theme.primaryText)
                        .lineLimit(1)
                        .accessibilityLabel(voice.transcript.isEmpty ? "Listening" : voice.transcript)
                } else {
                    FieldHighlight(text: model.text, plan: currentPlan, suggestion: TimeFormatter.compact(settings.defaultDuration))
                    TextField("What are you working on?", text: $model.text)
                        .textFieldStyle(.plain)
                        .font(Self.fieldFont)
                        .foregroundStyle(Theme.primaryText)
                        .focused($focused)
                        .onSubmit(submit)
                        .onExitCommand(perform: close)
                        .onChange(of: model.text) { _ in model.error = nil }
                        .accessibilityLabel("What are you working on, and for how long?")
                        .accessibilityHint("For example: Write intro 25 minutes. Press Return to start.")
                }
            }

            Button(action: toggleVoice) {
                Image(systemName: voice.isListening ? "waveform" : "mic")
                    .foregroundStyle(voice.isListening ? Theme.accent : Theme.secondaryText)
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .help(voiceHelp)
            .accessibilityLabel(voice.isListening ? "Stop listening" : "Say a timer")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    static let fieldFont = Font.system(size: 22, weight: .regular)

    private var voiceHelp: String {
        if let s = settings.shortcuts[.voice] { return "Say it (\(s.display))" }
        return "Say it"
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if let error = model.error {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Theme.accent)
                Text(error)
                    .foregroundStyle(Theme.secondaryText)
            } else if case let .failed(message) = voice.phase {
                Image(systemName: "mic.slash")
                    .foregroundStyle(Theme.accent)
                Text(message)
                    .foregroundStyle(Theme.secondaryText)
            } else if voice.isListening && voice.transcript.isEmpty {
                Text("Say what and how long: “twenty five minutes for email”")
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                switch currentPlan {
                case .empty:
                    Text("Write the task, then how long, or when: “Deep work 9–10:30 weekdays”.")
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("or press").foregroundStyle(Theme.tertiaryText)
                    if let s = settings.shortcuts[.newTimer] { KeyCaps(text: s.display) }
                    Text("again to talk").foregroundStyle(Theme.tertiaryText)
                case let .start(seconds, name, suggested):
                    MiniTimer(name: name, seconds: seconds)
                    Spacer(minLength: 8)
                    Text(suggested ? "Tab for \(TimeFormatter.compact(seconds)), or type a time"
                         : (name == nil ? "Add what it’s for, or Return to start" : "Return to start"))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                    KeyCaps(text: "↩")
                case let .command(p):
                    Text(p.title)
                        .foregroundStyle(p.isValid ? Theme.primaryText : Theme.tertiaryText)
                    if let detail = p.detail {
                        Text("·").foregroundStyle(Theme.tertiaryText)
                        Text(detail).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    if p.isValid { KeyCaps(text: "↩") }
                case let .schedule(spec):
                    MiniSchedule(spec: spec)
                    Spacer(minLength: 8)
                    Text("Return to schedule")
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                    KeyCaps(text: "↩")
                case .invalid:
                    Text("Write a task and a time, like “Write intro 25m”")
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 38)
        .accessibilityElement(children: .combine)
    }

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 10)
                .padding(.bottom, 3)
            ForEach(settings.recents) { recent in
                Button { startRecent(recent) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                        Text(recent.name).foregroundStyle(Theme.primaryText).lineLimit(1)
                        Spacer()
                        Text(TimeFormatter.compact(recent.seconds))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .buttonStyle(RowButtonStyle())
                .help("Start “\(recent.name)” for \(TimeFormatter.compact(recent.seconds))")
                .accessibilityLabel("Start \(recent.name), \(TimeFormatter.spoken(recent.seconds))")
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var coach: some View {
        HStack(spacing: 8) {
            Text("Write what you’re working on, then how long:")
                .foregroundStyle(Theme.primaryText)
            Text("Write intro 25m")
                .fontWeight(.semibold)
                .foregroundStyle(Theme.accent)
            Spacer(minLength: 6)
            KeyCaps(text: "tab")
            Text("to try it").foregroundStyle(Theme.secondaryText)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private var presetsRow: some View {
        let task: String? = {
            if case let .start(_, name, true) = currentPlan { return name }
            return nil
        }()
        return HStack(spacing: 5) {
            ForEach(Array(settings.presets.prefix(9).enumerated()), id: \.offset) { item in
                let index = item.offset
                let seconds = item.element
                Button { startPreset(seconds) } label: {
                    Text(TimeFormatter.compact(seconds))
                }
                .buttonStyle(ChipStyle())
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help(task.map { "Start “\($0)” for \(TimeFormatter.compact(seconds)) (⌘\(index + 1))" }
                      ?? "Start \(TimeFormatter.compact(seconds)) (⌘\(index + 1))")
                .accessibilityLabel("Start \(TimeFormatter.spoken(seconds))")
            }
            Button(action: startPomodoro) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                    Text("Pomodoro")
                }
            }
            .buttonStyle(ChipStyle())
            .keyboardShortcut("p", modifiers: .command)
            .help("25 min focus, then a 5 min break, on repeat. Every 4th break is 15 min. (⌘P)")
            .accessibilityLabel("Start a Pomodoro cycle")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 2)
    }
}

/// Drawn behind the text field: a soft pill under the time you typed, and the
/// suggested length in grey after a task with no time.
private struct FieldHighlight: View {
    let text: String
    let plan: CommandRunner.Plan
    let suggestion: String

    var body: some View {
        HStack(spacing: 8) {
            // One Text, laid out exactly like the field's own text, so the
            // highlight sits under the right characters.
            (Text(highlighted) + ghost)
                .font(ComposerView.fieldFont)
                .lineLimit(1)
            if case .start(_, _, true) = plan {
                KeyCaps(text: "tab")
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var highlighted: AttributedString {
        var a = AttributedString(text)
        a.swiftUI.foregroundColor = Color.clear
        var marks: [(Range<String.Index>, Color)] = []
        switch plan {
        case .start(_, _, false):
            marks = LauncherText.timeRanges(in: text).map { ($0, Theme.accent.opacity(0.22)) }
        case let .schedule(spec):
            // When it happens in blue, how long in ember.
            marks = spec.whenRanges.map { ($0, Theme.schedule.opacity(0.2)) } + spec.lengthRanges.map { ($0, Theme.accent.opacity(0.22)) }
        default:
            break
        }
        for (r, color) in marks {
            guard r.upperBound <= text.endIndex,
                  let lower = AttributedString.Index(r.lowerBound, within: a),
                  let upper = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lower..<upper].swiftUI.backgroundColor = color
        }
        return a
    }

    private var ghost: Text {
        guard case .start(_, _, true) = plan else { return Text("") }
        return Text(text.hasSuffix(" ") ? suggestion : " " + suggestion)
            .foregroundColor(Theme.tertiaryText)
    }
}

/// The block you're about to schedule: what, which days, when.
struct MiniSchedule: View {
    let spec: ScheduleSpec

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(spec.name).fontWeight(.semibold).foregroundStyle(Theme.primaryText).lineLimit(1)
            Text("\(Schedule.describeDays(spec.days, date: spec.date)) · \(Schedule.range(startMinute: spec.startMinute, duration: spec.duration))")
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
    }
}

/// The timer you're about to start, as it will look in the widget.
struct MiniTimer: View {
    let name: String?
    let seconds: TimeInterval

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
            if let name {
                Text(name).fontWeight(.semibold).foregroundStyle(Theme.primaryText).lineLimit(1)
            } else {
                Text("+ Add task").foregroundStyle(Theme.tertiaryText)
            }
            Text(TimeFormatter.clock(seconds))
                .font(Theme.digits(13))
                .foregroundStyle(Theme.primaryText)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 24)
        .frame(maxWidth: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
    }
}

private struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed || hovering ? Theme.control : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct ChipStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(hovering ? Theme.primaryText : Theme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed || hovering ? Theme.controlHover : Theme.control)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
