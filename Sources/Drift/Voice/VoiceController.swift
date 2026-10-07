import AVFoundation
import Foundation
import Speech

/// Push-to-talk voice commands.
///
/// Why not an always-listening "Hey Drift"? A custom wake word means keeping
/// the microphone open all day, which costs battery and trust for very little
/// gain. Instead: press the voice shortcut (or the mic in the composer), speak,
/// and Drift stops listening on its own when you pause. Recognition runs
/// on-device whenever the Mac supports it; audio is never stored or sent by
/// Drift.
@MainActor
final class VoiceController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case requesting
        case listening
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    /// 0…1 input level for the listening indicator.
    @Published private(set) var level: Float = 0

    /// Called once with the final transcript.
    var onFinish: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var limitTimer: Timer?
    private var delivered = false

    var isListening: Bool { phase == .listening }

    func toggle() {
        if isListening { finish() } else { start() }
    }

    func start() {
        guard phase != .listening, phase != .requesting else { return }
        transcript = ""
        delivered = false
        phase = .requesting

        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.phase = .failed("Allow Speech Recognition for Drift in System Settings → Privacy & Security.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.phase = .failed("Allow Microphone access for Drift in System Settings → Privacy & Security.")
                            return
                        }
                        self.beginListening()
                    }
                }
            }
        }
    }

    func cancel() {
        delivered = true
        teardown()
        phase = .idle
        transcript = ""
    }

    private func beginListening() {
        guard let recognizer, recognizer.isAvailable else {
            phase = .failed("Speech recognition isn't available right now.")
            return
        }

        // Drift has no network access at all (it's sandboxed without it), so
        // recognition must happen on this Mac. Your voice never leaves it.
        guard recognizer.supportsOnDeviceRecognition else {
            phase = .failed("On-device speech isn't set up. Turn on Dictation in System Settings → Keyboard, then try again.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = ["minutes", "timer", "pomodoro", "pause", "resume", "cancel", "add", "focus", "break"]
        if #available(macOS 13.0, *) {
            request.addsPunctuation = false
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            phase = .failed("No microphone found.")
            return
        }

        Self.installTap(on: input, format: format, request: request) { [weak self] level in
            guard let self else { return }
            Task { @MainActor in self.level = level }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            phase = .failed("Couldn't start the microphone.")
            return
        }

        self.engine = engine
        self.request = request
        phase = .listening

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            guard let self else { return }
            Task { @MainActor in
                guard !self.delivered else { return }
                if let text, !text.isEmpty {
                    self.transcript = text
                    self.armSilenceTimer()
                }
                if isFinal || (failed && !self.transcript.isEmpty) {
                    self.deliver()
                } else if failed {
                    self.teardown()
                    self.phase = .failed("Didn't catch that.")
                }
            }
        }

        // Stop on our own if nothing is said, and never listen for long.
        armSilenceTimer(interval: 4)
        limitTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.finish() }
        }
    }

    /// Stop listening and use what we have.
    func finish() {
        guard phase == .listening else { return }
        request?.endAudio()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        // Give the recognizer a moment to produce its final result.
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.deliver() }
        }
    }

    private func deliver() {
        guard !delivered else { return }
        delivered = true
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        if text.isEmpty {
            phase = .failed("Didn't hear anything.")
        } else {
            phase = .idle
            onFinish?(text)
        }
    }

    private func armSilenceTimer(interval: TimeInterval = 1.3) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.finish() }
        }
    }

    private func teardown() {
        silenceTimer?.invalidate()
        limitTimer?.invalidate()
        silenceTimer = nil
        limitTimer = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        level = 0
    }

    /// The tap block runs on an audio thread, so it's built outside the main actor.
    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest,
        level: @escaping @Sendable (Float) -> Void
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = (sum / Float(n)).squareRoot()
            level(min(1, rms * 12))
        }
    }
}
