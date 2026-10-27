import AppKit

/// Drift's UI sounds, synthesised at launch — no audio assets, no licensing.
///
/// - Start: a single soft wooden "tok", barely there.
/// - Complete: a bright three-note bell (G5 · C6 · E6) that's easy to notice
///   across a room but never harsh. Repeats until dismissed by default.
/// - Phase: two gentle notes for Pomodoro focus ↔ break changes.
@MainActor
final class Chimes {
    private lazy var startSound: NSSound? = NSSound(data: Chimes.wav(Chimes.renderStart()))
    private lazy var completeSound: NSSound? = NSSound(data: Chimes.wav(Chimes.renderComplete()))
    private lazy var phaseSound: NSSound? = NSSound(data: Chimes.wav(Chimes.renderPhase()))

    private var ringTimer: Timer?
    private var ringStarted: Date?
    /// Called when ringing stops on its own (time limit reached).
    var onRingingEnded: (() -> Void)?

    var isRinging: Bool { ringTimer != nil }

    func playStart(volume: Double) {
        play(startSound, volume: volume * 0.45)
    }

    func playComplete(volume: Double) {
        play(completeSound, volume: volume)
    }

    func playPhase(volume: Double) {
        play(phaseSound, volume: volume * 0.8)
    }

    /// Chimes now, then every `interval` seconds until `stopRinging()` or
    /// `limit` seconds pass.
    func startRinging(volume: Double, interval: TimeInterval = 4, limit: TimeInterval = 120) {
        stopRinging()
        ringStarted = Date()
        playComplete(volume: volume)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let started = self.ringStarted else { return }
                if Date().timeIntervalSince(started) >= limit {
                    self.stopRinging()
                    self.onRingingEnded?()
                } else {
                    self.playComplete(volume: volume)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ringTimer = timer
    }

    func stopRinging() {
        ringTimer?.invalidate()
        ringTimer = nil
        ringStarted = nil
    }

    private func play(_ sound: NSSound?, volume: Double) {
        guard let sound else { return }
        sound.stop()
        sound.volume = Float(max(0, min(1, volume)))
        sound.play()
    }

    // MARK: - Synthesis

    private static let sampleRate: Double = 44_100

    private static func renderStart() -> [Float] {
        let length = Int(sampleRate * 0.14)
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let t = Double(i) / sampleRate
            let attack = min(1, t / 0.002)
            let body = sin(2 * .pi * 880 * t) * exp(-t / 0.035)
            let click = sin(2 * .pi * 1_760 * t) * exp(-t / 0.012) * 0.25
            out[i] = Float((body + click) * attack * 0.35)
        }
        return out
    }

    private static func renderComplete() -> [Float] {
        var out = [Float](repeating: 0, count: Int(sampleRate * 2.6))
        // A rising major triad: reads as "done", not "error".
        bell(into: &out, frequency: 783.99, start: 0.00, gain: 0.55, decay: 1.1)   // G5
        bell(into: &out, frequency: 1_046.50, start: 0.16, gain: 0.50, decay: 1.2)  // C6
        bell(into: &out, frequency: 1_318.51, start: 0.32, gain: 0.55, decay: 1.5)  // E6
        normalize(&out, to: 0.9)
        return out
    }

    private static func renderPhase() -> [Float] {
        var out = [Float](repeating: 0, count: Int(sampleRate * 1.8))
        bell(into: &out, frequency: 659.25, start: 0.0, gain: 0.5, decay: 0.8)   // E5
        bell(into: &out, frequency: 987.77, start: 0.2, gain: 0.45, decay: 1.0)   // B5
        normalize(&out, to: 0.7)
        return out
    }

    private static func normalize(_ out: inout [Float], to level: Float) {
        let peak = out.map { abs($0) }.max() ?? 1
        if peak > 0 { out = out.map { $0 / peak * level } }
    }

    private static func bell(into buffer: inout [Float], frequency f: Double, start: Double, gain: Double, decay: Double) {
        let offset = Int(start * sampleRate)
        guard offset < buffer.count else { return }
        for i in offset..<buffer.count {
            let t = Double(i - offset) / sampleRate
            let attack = min(1, t / 0.003)
            // Fundamental rings longest; inharmonic partials give the bell
            // character and fade fast so it stays clean.
            var s = sin(2 * .pi * f * t) * exp(-t / decay)
            s += 0.30 * sin(2 * .pi * f * 2.0 * t) * exp(-t / (decay * 0.4))
            s += 0.12 * sin(2 * .pi * f * 2.76 * t) * exp(-t / (decay * 0.18))
            s += 0.05 * sin(2 * .pi * f * 5.4 * t) * exp(-t / (decay * 0.07))
            buffer[i] += Float(s * attack * gain)
        }
    }

    /// 16-bit mono PCM WAV.
    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        let rate = UInt32(sampleRate)
        let dataSize = UInt32(samples.count * 2)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * Float(Int16.max)))
        }
        return data
    }
}
