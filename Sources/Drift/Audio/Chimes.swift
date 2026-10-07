import AppKit

/// Drift's UI sounds, synthesised at launch — no audio assets, no licensing.
///
/// - Start: a single soft wooden "tok", barely there.
/// - Complete: two warm bell tones a fourth apart, ringing out over ~2s.
@MainActor
final class Chimes {
    private lazy var startSound: NSSound? = NSSound(data: Chimes.wav(Chimes.renderStart()))
    private lazy var completeSound: NSSound? = NSSound(data: Chimes.wav(Chimes.renderComplete()))

    func playStart(volume: Double) {
        play(startSound, volume: volume * 0.5)
    }

    func playComplete(volume: Double) {
        play(completeSound, volume: volume)
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
        let length = Int(sampleRate * 2.4)
        var out = [Float](repeating: 0, count: length)
        // E5 then A5: an open, resolved interval that doesn't sound like an alarm.
        bell(into: &out, frequency: 659.25, start: 0.0, gain: 0.55)
        bell(into: &out, frequency: 880.0, start: 0.18, gain: 0.45)
        let peak = out.map { abs($0) }.max() ?? 1
        if peak > 0 { out = out.map { $0 / peak * 0.6 } }
        return out
    }

    private static func bell(into buffer: inout [Float], frequency f: Double, start: Double, gain: Double) {
        let offset = Int(start * sampleRate)
        for i in offset..<buffer.count {
            let t = Double(i - offset) / sampleRate
            let attack = min(1, t / 0.004)
            // Fundamental rings longest; inharmonic partials add the bell
            // character and fade quickly so it stays soft.
            var s = sin(2 * .pi * f * t) * exp(-t / 0.85)
            s += 0.22 * sin(2 * .pi * f * 2.0 * t) * exp(-t / 0.35)
            s += 0.08 * sin(2 * .pi * f * 2.76 * t) * exp(-t / 0.16)
            s += 0.03 * sin(2 * .pi * f * 5.4 * t) * exp(-t / 0.06)
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
        append(UInt32(16))       // chunk size
        append(UInt16(1))        // PCM
        append(UInt16(1))        // mono
        append(rate)
        append(rate * 2)         // byte rate
        append(UInt16(2))        // block align
        append(UInt16(16))       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * Float(Int16.max)))
        }
        return data
    }
}
