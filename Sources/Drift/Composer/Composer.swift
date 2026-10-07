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
        panel.setAccessibilityTitle("New Drift timer")
        panel.onEscape = { [weak self] in self?.close() }

        let view = ComposerView(
            model: model,
            settings: settings,
            voice: voice,
            preview: { [weak runner] text in
                runner?.preview(text) ?? CommandRunner.Preview(title: "", detail: nil, isValid: false)
            },
            submit: { [weak self] in self?.submit() },
            startPreset: { [weak self] seconds in self?.startPreset(seconds) },
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

    private func startPreset(_ seconds: TimeInterval) {
        runner.run(.start(seconds: seconds, name: nil))
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
            model.error = "Heard “\(transcript)” — try “start a 25 minute timer”."
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
        let width: CGFloat = 480
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
    @ObservedObject var model: ComposerModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var voice: VoiceController
    let preview: (String) -> CommandRunner.Preview
    let submit: () -> Void
    let startPreset: (TimeInterval) -> Void
    let startPomodoro: () -> Void
    let toggleVoice: () -> Void
    let close: () -> Void
    let resize: (CGSize) -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            statusRow
            presetsRow
        }
        .frame(width: 480)
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
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(voice.transcript.isEmpty ? Theme.tertiaryText : Theme.primaryText)
                        .lineLimit(1)
                        .accessibilityLabel(voice.transcript.isEmpty ? "Listening" : voice.transcript)
                } else {
                    TextField("25m, 1:30, 45m writing…", text: $model.text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Theme.primaryText)
                        .focused($focused)
                        .onSubmit(submit)
                        .onExitCommand(perform: close)
                        .onChange(of: model.text) { _ in model.error = nil }
                        .accessibilityLabel("Timer duration or command")
                        .accessibilityHint("For example 25, 1:30, or 45 minutes writing. Press Return to start.")
                }
            }

            Button(action: toggleVoice) {
                Image(systemName: voice.isListening ? "waveform" : "mic")
                    .foregroundStyle(voice.isListening ? Theme.accent : Theme.secondaryText)
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .help(voiceHelp)
            .accessibilityLabel(voice.isListening ? "Stop listening" : "Speak a command")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    private var voiceHelp: String {
        if let s = settings.shortcuts[.voice] { return "Speak a command (\(s.display))" }
        return "Speak a command"
    }

    private var statusRow: some View {
        let p = preview(voice.isListening && model.text.isEmpty ? voice.transcript : model.text)
        return HStack(spacing: 8) {
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
                Text("Say “25 minutes”, “45 minutes called writing”, “pause”, “add 5 minutes”…")
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                Text(p.title)
                    .foregroundStyle(p.isValid ? Theme.primaryText : Theme.tertiaryText)
                if let detail = p.detail {
                    Text("·").foregroundStyle(Theme.tertiaryText)
                    Text(detail).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer()
                if p.isValid { KeyCaps(text: "↩") }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 34)
        .accessibilityElement(children: .combine)
    }

    private var presetsRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(settings.presets.prefix(5).enumerated()), id: \.offset) { item in
                let index = item.offset
                let seconds = item.element
                Button { startPreset(seconds) } label: {
                    Text(TimeFormatter.compact(seconds))
                }
                .buttonStyle(ChipStyle())
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help("Start \(TimeFormatter.compact(seconds)) (⌘\(index + 1))")
                .accessibilityLabel("Start \(TimeFormatter.spoken(seconds))")
            }
            Button(action: startPomodoro) {
                Text("25 / 5")
            }
            .buttonStyle(ChipStyle())
            .keyboardShortcut("p", modifiers: .command)
            .help("Pomodoro: 25 min focus, 5 min break, repeating (⌘P)")
            .accessibilityLabel("Start a Pomodoro cycle")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 2)
    }
}

private struct ChipStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(hovering ? Theme.primaryText : Theme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed || hovering ? Theme.controlHover : Theme.control)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
