import AVFoundation
import Foundation

/// The three soundscapes. All are generated live, on device — nothing to
/// download, nothing licensed, works offline, loops forever without a seam.
enum Soundscape: String, CaseIterable, Identifiable {
    case brownNoise
    case rain
    case ambient

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brownNoise: return "Brown Noise"
        case .rain: return "Rain"
        case .ambient: return "Low Ambient"
        }
    }
}

/// Procedural focus audio on an AVAudioEngine. The engine only runs while
/// sound is actually playing, so it costs nothing the rest of the time.
@MainActor
final class FocusSoundPlayer {
    private var engine: AVAudioEngine?
    private var generator: SoundGenerator?
    private var fadeTimer: Timer?
    private var currentVolume: Float = 0
    private var targetVolume: Float = 0
    private(set) var isPlaying = false
    private var soundscape: Soundscape = .brownNoise

    /// Brings playback in line with the desired state, fading in or out.
    func update(shouldPlay: Bool, soundscape: Soundscape, volume: Double) {
        let volume = Float(max(0, min(1, volume)))
        if shouldPlay {
            if !isPlaying || self.soundscape != soundscape {
                start(soundscape)
            }
            fade(to: volume)
        } else if isPlaying {
            fade(to: 0) { [weak self] in self?.stopEngine() }
        }
    }

    private func start(_ soundscape: Soundscape) {
        self.soundscape = soundscape
        if let generator {
            generator.soundscape = soundscape
            if isPlaying { return }
        }

        let engine = AVAudioEngine()
        let generator = generator ?? SoundGenerator(soundscape: soundscape)
        generator.soundscape = soundscape
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else { return }

        let source = Self.makeSource(format: format, generator: generator)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = currentVolume

        do {
            try engine.start()
        } catch {
            NSLog("Drift: focus sound failed to start: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        self.generator = generator
        isPlaying = true
    }

    /// Built outside the main actor: the render block runs on the real-time
    /// audio thread and must not inherit main-actor isolation.
    private nonisolated static func makeSource(format: AVAudioFormat, generator: SoundGenerator) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            generator.render(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
        isPlaying = false
        currentVolume = 0
    }

    /// A short linear ramp — music should never snap on or off.
    private func fade(to target: Float, duration: TimeInterval = 1.4, completion: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        targetVolume = target
        let start = currentVolume
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                let p = Float(min(1, Date().timeIntervalSince(began) / duration))
                self.currentVolume = start + (target - start) * p
                self.engine?.mainMixerNode.outputVolume = self.currentVolume
                if p >= 1 {
                    t.invalidate()
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }
}

/// Runs on the real-time audio thread: no allocation, no locks, no Swift
/// runtime surprises — just arithmetic on preallocated state.
final class SoundGenerator: @unchecked Sendable {
    var soundscape: Soundscape

    private var rngState: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var brown: (Float, Float) = (0, 0)
    private var pink: [Float] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    private var lowpass: (Float, Float) = (0, 0)
    private var drop: (amp: Float, phase: Float, freq: Float) = (0, 0, 0)
    private var t: Double = 0
    private let sampleRate: Double = 44_100

    init(soundscape: Soundscape) {
        self.soundscape = soundscape
    }

    func render(frameCount: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
        else { return }

        let dt = 1.0 / sampleRate
        for i in 0..<frameCount {
            let (l, r): (Float, Float)
            switch soundscape {
            case .brownNoise: (l, r) = brownSample()
            case .rain: (l, r) = rainSample()
            case .ambient: (l, r) = ambientSample()
            }
            left[i] = l
            right[i] = r
            t += dt
        }
    }

    // MARK: Noise primitives

    @inline(__always)
    private func white() -> Float {
        // xorshift64*
        rngState ^= rngState >> 12
        rngState ^= rngState << 25
        rngState ^= rngState >> 27
        let x = rngState &* 0x2545_F491_4F6C_DD1D
        return Float(Double(x >> 11) / Double(1 << 53)) * 2 - 1
    }

    @inline(__always)
    private func brownSample() -> (Float, Float) {
        brown.0 = (brown.0 + 0.02 * white()) / 1.02
        brown.1 = (brown.1 + 0.02 * white()) / 1.02
        return (brown.0 * 3.2, brown.1 * 3.2)
    }

    /// Paul Kellet's economy pink filter, one per channel.
    @inline(__always)
    private func pinkSample(_ o: Int) -> Float {
        let w = white()
        pink[o + 0] = 0.99886 * pink[o + 0] + w * 0.0555179
        pink[o + 1] = 0.99332 * pink[o + 1] + w * 0.0750759
        pink[o + 2] = 0.96900 * pink[o + 2] + w * 0.1538520
        pink[o + 3] = 0.86650 * pink[o + 3] + w * 0.3104856
        pink[o + 4] = 0.55000 * pink[o + 4] + w * 0.5329522
        pink[o + 5] = -0.7616 * pink[o + 5] - w * 0.0168980
        let out = pink[o] + pink[o + 1] + pink[o + 2] + pink[o + 3] + pink[o + 4] + pink[o + 5] + pink[o + 6] + w * 0.5362
        pink[o + 6] = w * 0.115926
        return out * 0.11
    }

    // MARK: Soundscapes

    /// Soft steady rain: low-passed pink noise with a slow swell, plus sparse,
    /// quiet droplets.
    private func rainSample() -> (Float, Float) {
        let swell = Float(0.8 + 0.2 * sin(2 * .pi * t / 11.0))
        lowpass.0 += 0.25 * (pinkSample(0) - lowpass.0)
        lowpass.1 += 0.25 * (pinkSample(7) - lowpass.1)

        if drop.amp < 0.001, white() > 0.99965 {
            drop = (amp: 0.05 + 0.05 * abs(white()), phase: 0, freq: 2_400 + 1_800 * abs(white()))
        }
        var d: Float = 0
        if drop.amp > 0.001 {
            d = drop.amp * sin(drop.phase)
            drop.phase += 2 * .pi * drop.freq / Float(sampleRate)
            drop.amp *= 0.9965
        }
        return (lowpass.0 * swell * 1.1 + d * 0.6, lowpass.1 * swell * 1.1 + d)
    }

    /// A slow, warm drone: open fifths in A with each partial breathing on its
    /// own long cycle, over a whisper of brown noise.
    /// (frequency, gain, breathing period in seconds)
    private let partials: [(Double, Double, Double)] = [
        (110.0, 0.30, 13.0), (164.81, 0.20, 17.0), (220.0, 0.16, 11.0),
        (329.63, 0.08, 19.0), (440.0, 0.035, 23.0),
    ]

    private func ambientSample() -> (Float, Float) {
        var l: Double = 0
        var r: Double = 0
        for index in 0..<partials.count {
            let p = partials[index]
            let breathe = 0.6 + 0.4 * sin(2 * .pi * t / p.2 + Double(index))
            let pan = 0.5 + 0.35 * sin(2 * .pi * t / (p.2 * 1.7) + Double(index) * 1.3)
            let detune = 1 + 0.0015 * sin(2 * .pi * t / 7.0 + Double(index))
            let s = sin(2 * .pi * p.0 * detune * t) * p.1 * breathe
            l += s * (1 - pan)
            r += s * pan
        }
        let (bl, br) = brownSample()
        return (Float(l * 0.55) + bl * 0.08, Float(r * 0.55) + br * 0.08)
    }
}
