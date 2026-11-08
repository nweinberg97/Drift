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
            model.text = "Reply to emails 25m"
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

    /// The New Timer shortcut pressed while the launcher is already open.
    /// It always brings the launcher forward with the cursor in it; only a
    /// second press on an empty, focused launcher switches to talking.
    func shortcutPressedAgain() {
        model.error = nil
        if voice.isListening {
            voice.cancel()
            panel.makeKeyAndOrderFront(nil)
            model.focusToken += 1
            return
        }
        if !panel.isKeyWindow {
            panel.makeKeyAndOrderFront(nil)
            model.focusToken += 1
            return
        }
        if settings.featureVoice && model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voice.start()
        } else {
            model.focusToken += 1
        }
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
        if recent.session == true, let saved = settings.savedSession(named: recent.name) {
            runner.run(saved.name)
        } else {
            runner.run(.start(seconds: recent.seconds, name: recent.name))
        }
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
    /// Off only for marketing screenshots, where a focused field shows a selection.
    var autofocus = true

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentPlan: CommandRunner.Plan {
        plan(voice.isListening && model.text.isEmpty ? voice.transcript : model.text)
    }
    private var showRecents: Bool { model.text.isEmpty && !voice.isListening && !settings.recents.isEmpty }
    private var showCoach: Bool { model.text.isEmpty && !voice.isListening && !settings.hasWrittenTask }
    /// Quick lengths only while there's nothing typed, or a task without a time.
    private var showPresets: Bool {
        if voice.isListening { return false }
        switch currentPlan {
        case .empty: return true
        case .start(_, _, true): return true
        default: return false
        }
    }
    private var session: SessionSpec? {
        if case let .session(s) = currentPlan { return s }
        return nil
    }
    private var isLong: Bool { (voice.isListening && model.text.isEmpty ? voice.transcript : model.text).count > 44 }
    private var fieldFont: Font { isLong ? Self.longFieldFont : Self.fieldFont }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            // First time: the coach is the one tip, instead of the hint line too.
            if !(showCoach && currentPlan == .empty && model.error == nil) { statusRow }
            if let session {
                SessionSteps(spec: session)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                startTimes(session)
            }
            if showRecents { recentsList }
            if showCoach { coach.padding(.top, 10) }
            if showPresets { presetsRow }
            HStack {
                Spacer()
                Text("esc or click outside to close")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .padding(.top, showPresets ? -4 : 0)
        }
        .frame(width: Self.width)
        .driftSurface(cornerRadius: 16)
        .fixedSize(horizontal: false, vertical: true)
        .reportSize(resize)
        .onChange(of: model.focusToken) { _ in focusField() }
        .onAppear { if autofocus { focusField() } }
    }

    private func focusField() {
        DispatchQueue.main.async { focused = true }
    }

    // MARK: Rows

    private var inputRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 8, height: 8)
                .scaleEffect(voice.isListening ? 1 + CGFloat(voice.level) * 1.4 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: voice.level)
                .frame(width: 22, height: 30)
                .padding(.top, 17)
                .accessibilityHidden(true)

            ZStack(alignment: .topLeading) {
                if voice.isListening && model.text.isEmpty {
                    Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                        .font(fieldFont)
                        .foregroundStyle(voice.transcript.isEmpty ? Theme.tertiaryText : Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(voice.transcript.isEmpty ? "Listening" : voice.transcript)
                } else {
                    FieldHighlight(text: model.text, plan: currentPlan, suggestion: TimeFormatter.compact(settings.defaultDuration), font: fieldFont)
                    // Wraps onto more lines, so a long list stays in view.
                    TextField("What are you working on?", text: $model.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(fieldFont)
                        .lineLimit(1...6)
                        .foregroundStyle(Theme.primaryText)
                        .focused($focused)
                        .onSubmit(submit)
                        .onExitCommand(perform: close)
                        .onChange(of: model.text) { text in
                            model.error = nil
                            handleNewlines(text)
                        }
                        .accessibilityLabel("What are you working on, and for how long?")
                        .accessibilityHint("For example: Reply to emails 25 minutes. Press Return to start.")
                }
            }
            .padding(.vertical, 17)

            HStack(spacing: 2) {
                if settings.featureVoice {
                    Button(action: toggleVoice) {
                        Image(systemName: voice.isListening ? "waveform" : "mic")
                            .foregroundStyle(voice.isListening ? Theme.accent : Theme.secondaryText)
                    }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .help(voiceHelp)
                    .accessibilityLabel(voice.isListening ? "Stop listening" : "Say a timer")
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Close (esc)")
                .accessibilityLabel("Close")
            }
            .padding(.top, 17)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
    }

    /// Return in a wrapping field can arrive as a newline: treat a single one
    /// at the end as Return. A pasted list (one per line) becomes a comma list.
    private func handleNewlines(_ text: String) {
        guard text.contains("\n") else { return }
        let count = text.filter { $0 == "\n" }.count
        if count == 1 && text.hasSuffix("\n") {
            model.text = String(text.dropLast())
            DispatchQueue.main.async { submit() }
            return
        }
        model.text = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static let fieldFont = Font.system(size: 22, weight: .regular)
    static let longFieldFont = Font.system(size: 18, weight: .regular)

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
                    Text("Write the task and how long, like “Reply to emails 25m”")
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if settings.featureVoice, let s = settings.shortcuts[.newTimer] {
                        KeyCaps(text: s.display)
                        Text("again to talk").foregroundStyle(Theme.tertiaryText)
                    }
                case let .session(spec):
                    MiniSession(spec: spec)
                    if let declared = spec.declared, abs(declared - spec.total) >= 60 {
                        Text("adds up to \(TimeFormatter.compact(spec.total)) of \(TimeFormatter.compact(declared))")
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(spec.schedule == nil ? "Return to start" : "Return to schedule")
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                    KeyCaps(text: "↩")
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
                    Text("Write a task and a time, like “Reply to emails 25m”")
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
            Text("Reply to emails 25m")
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

    // MARK: Start time for a list

    /// "Starts: Now / 2:00 PM / 2:30 PM / 3:00 PM". Tapping rewrites the start
    /// time at the end of the text, so what you see is what runs.
    private func startTimes(_ spec: SessionSpec) -> some View {
        let cal = Calendar.current
        let now = Date()
        let nowMinute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let first = Int((Double(nowMinute + 10) / 30).rounded(.up)) * 30
        let choices = [first, first + 30, first + 60].map { $0 % 1_440 }
        let current = spec.schedule?.startMinute
        return HStack(spacing: 5) {
            Text("Starts").foregroundStyle(Theme.secondaryText)
            Button("Now") { setStart(nil) }
                .buttonStyle(StartTimeChipStyle(selected: spec.schedule == nil))
            ForEach(choices, id: \.self) { m in
                Button(Schedule.time(m)) { setStart(m) }
                    .buttonStyle(StartTimeChipStyle(selected: current == m))
            }
            Text("or type “at 3pm”").foregroundStyle(Theme.tertiaryText)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private static let startPattern = try! NSRegularExpression(
        pattern: "[,\\s]*(?:(?:starting|start|beginning|begin)\\s+)?(?:at|from|@)\\s*\\d{1,2}(?::\\d{2})?\\s*(?:am|pm|a\\.m\\.|p\\.m\\.)?(?:\\s+today)?\\s*$",
        options: [.caseInsensitive])

    private func setStart(_ minute: Int?) {
        let ns = model.text as NSString
        var text = Self.startPattern.stringByReplacingMatches(in: model.text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        if let minute {
            let h = minute / 60, m = minute % 60, h12 = h % 12 == 0 ? 12 : h % 12
            let at = m == 0 ? "\(h12)\(h < 12 ? "am" : "pm")" : String(format: "%d:%02d%@", h12, m, h < 12 ? "am" : "pm")
            text += ", starting at \(at) today"
        }
        model.text = text
        model.focusToken += 1
    }

    private var presetsRow: some View {
        let task: String? = {
            if case let .start(_, name, true) = currentPlan { return name }
            return nil
        }()
        return HStack(spacing: 5) {
            ForEach(settings.quickLengths, id: \.self) { seconds in
                let index = settings.presets.firstIndex(of: seconds) ?? 0
                Button { startPreset(seconds) } label: {
                    Text(TimeFormatter.compact(seconds))
                }
                .buttonStyle(ChipStyle())
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help(task.map { "Start “\($0)” for \(TimeFormatter.compact(seconds)) (⌘\(index + 1))" }
                      ?? "Start \(TimeFormatter.compact(seconds)) (⌘\(index + 1))")
                .accessibilityLabel("Start \(TimeFormatter.spoken(seconds))")
            }
            if settings.featurePomodoro && task == nil {
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
            }
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
    let font: Font

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // One Text, laid out exactly like the field's own text, so the
            // highlight sits under the right characters, line by line.
            (Text(highlighted) + ghost)
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
            if case .start(_, _, true) = plan {
                KeyCaps(text: "tab")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        case let .session(spec):
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

/// The session you're about to start or plan.
struct MiniSession: View {
    let spec: SessionSpec

    var body: some View {
        let detail: String = {
            if let plan = spec.schedule {
                return "\(Schedule.describeDays(plan.days, date: plan.date)) · \(Schedule.range(startMinute: plan.startMinute, duration: spec.total))"
            }
            let end = Date().addingTimeInterval(spec.total)
            let c = Calendar.current.dateComponents([.hour, .minute], from: end)
            return "\(spec.steps.count) time blocks · \(TimeFormatter.compact(spec.total)) · ends \(Schedule.time((c.hour ?? 0) * 60 + (c.minute ?? 0)))"
        }()
        HStack(spacing: 7) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(spec.name).fontWeight(.semibold).foregroundStyle(Theme.primaryText).lineLimit(1)
            Text(detail).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
    }
}

/// Each time block with the clock time it starts: "now Inbox 10m › 9:52 Plan the day 10m".
struct SessionSteps: View {
    let spec: SessionSpec

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let start = spec.schedule.map { Double($0.startMinute) }
            ?? Double(cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now))
        FlowLayout(spacing: 4) {
            ForEach(Array(spec.steps.enumerated()), id: \.offset) { item in
                let at = start + spec.steps.prefix(item.offset).reduce(0) { $0 + $1.seconds } / 60
                HStack(spacing: 5) {
                    Text(item.offset == 0 && spec.schedule == nil ? "now" : Schedule.time(Int(at.rounded()), suffix: false))
                        .foregroundStyle(Theme.tertiaryText)
                    Text(item.element.name).foregroundStyle(Theme.primaryText).lineLimit(1)
                    Text(TimeFormatter.compact(item.element.seconds)).foregroundStyle(Theme.tertiaryText)
                }
                .font(.system(size: 11.5).monospacedDigit())
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.control))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 540
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + spacing
                line = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

private struct StartTimeChipStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(selected ? Color.white : Theme.primaryText)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Theme.accent : (configuration.isPressed || hovering ? Theme.controlHover : Theme.control))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
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
