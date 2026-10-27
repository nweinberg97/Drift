import AVFoundation
import Foundation

/// Focus soundscapes. All are generated live on the Mac: nothing to download,
/// nothing licensed, works offline, and they loop forever without a seam.
/// The reference implementation (and preview renderer) is
/// `tools/soundscapes/scapes.c`; keep the two in step.
enum Soundscape: String, CaseIterable, Identifiable {
    case rain
    case ocean
    case fireplace
    /// Raw value kept from v1 so saved preferences carry over.
    case ambient
    case brownNoise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rain: return "Rain"
        case .ocean: return "Ocean"
        case .fireplace: return "Fireplace"
        case .ambient: return "Soft Pad"
        case .brownNoise: return "Brown Noise"
        }
    }

    var symbol: String {
        switch self {
        case .rain: return "cloud.rain"
        case .ocean: return "water.waves"
        case .fireplace: return "flame"
        case .ambient: return "music.note"
        case .brownNoise: return "waveform"
        }
    }

    /// Loudness-matching gains measured from the reference renders
    /// (A-weighted, target ≈ −26 dB).
    var gain: Double {
        switch self {
        case .brownNoise: return 1.06
        case .rain: return 0.73
        case .ocean: return 1.97
        case .fireplace: return 1.65
        case .ambient: return 1.34
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
    private var soundscape: Soundscape = .rain

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
        activeFade = Fade(from: currentVolume, to: target, began: Date(), duration: duration, completion: completion)
        targetVolume = target
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.fadeStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private struct Fade {
        var from: Float
        var to: Float
        var began: Date
        var duration: TimeInterval
        var completion: (() -> Void)?
    }

    private var activeFade: Fade?

    private func fadeStep() {
        guard let fade = activeFade else {
            fadeTimer?.invalidate()
            return
        }
        let p = Float(min(1, Date().timeIntervalSince(fade.began) / fade.duration))
        currentVolume = fade.from + (fade.to - fade.from) * p
        engine?.mainMixerNode.outputVolume = currentVolume
        if p >= 1 {
            fadeTimer?.invalidate()
            fadeTimer = nil
            activeFade = nil
            fade.completion?()
        }
    }
}

/// Runs on the real-time audio thread: no allocation, no locks — just
/// arithmetic on state allocated up front. Mirrors scapes.c line for line.
final class SoundGenerator: @unchecked Sendable {
    var soundscape: Soundscape

    private static let fs = 44_100.0
    private static let tau = 2 * Double.pi

    // MARK: Primitives

    /// xorshift64*, as in the C reference.
    struct Rng {
        var s: UInt64 = 0x9E37_79B9_7F4A_7C15
        @inline(__always) mutating func next01() -> Double {
            s ^= s >> 12
            s ^= s << 25
            s ^= s >> 27
            return Double((s &* 0x2545_F491_4F6C_DD1D) >> 11) / 9_007_199_254_740_992.0
        }
    }

    private var rng = Rng()

    @inline(__always) private func rnd01() -> Double { rng.next01() }

    @inline(__always) private func white() -> Double { rnd01() * 2 - 1 }

    struct OnePole {
        var y = 0.0
        var a = 0.0
        init(_ fc: Double = 1000) { set(fc) }
        mutating func set(_ fc: Double) { a = 1 - exp(-SoundGenerator.tau * fc / SoundGenerator.fs) }
        @inline(__always) mutating func lp(_ x: Double) -> Double { y += a * (x - y); return y }
        @inline(__always) mutating func hp(_ x: Double) -> Double { x - lp(x) }
    }

    struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
        static func lowpass(_ fc: Double, _ q: Double) -> Biquad { var b = Biquad(); b.setLowpass(fc, q); return b }
        static func highpass(_ fc: Double, _ q: Double) -> Biquad { var b = Biquad(); b.setHighpass(fc, q); return b }
        mutating func setLowpass(_ fc: Double, _ q: Double) {
            let w = SoundGenerator.tau * fc / SoundGenerator.fs, c = cos(w), s = sin(w), al = s / (2 * q), a0 = 1 + al
            b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = (1 - c) / 2 / a0; a1 = -2 * c / a0; a2 = (1 - al) / a0
        }
        mutating func setHighpass(_ fc: Double, _ q: Double) {
            let w = SoundGenerator.tau * fc / SoundGenerator.fs, c = cos(w), s = sin(w), al = s / (2 * q), a0 = 1 + al
            b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = (1 + c) / 2 / a0; a1 = -2 * c / a0; a2 = (1 - al) / a0
        }
        @inline(__always) mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    struct Pink {
        var p0 = 0.0, p1 = 0.0, p2 = 0.0, p3 = 0.0, p4 = 0.0, p5 = 0.0, p6 = 0.0
        @inline(__always) mutating func next(_ w: Double) -> Double {
            p0 = 0.99886 * p0 + w * 0.0555179
            p1 = 0.99332 * p1 + w * 0.0750759
            p2 = 0.96900 * p2 + w * 0.1538520
            p3 = 0.86650 * p3 + w * 0.3104856
            p4 = 0.55000 * p4 + w * 0.5329522
            p5 = -0.7616 * p5 - w * 0.0168980
            let out = p0 + p1 + p2 + p3 + p4 + p5 + p6 + w * 0.5362
            p6 = w * 0.115926
            return out * 0.11
        }
    }

    struct Brown {
        var y = 0.0
        @inline(__always) mutating func next(_ w: Double) -> Double { y = (y + 0.02 * w) / 1.02; return y * 3.5 }
    }

    /// Smooth random wander in 0…1 (cosine interpolation between random points).
    struct Wander {
        var a = 0.5, b = 0.5, t = 0.0, step = 0.0
        init(seconds: Double, a: Double, b: Double) { self.a = a; self.b = b; step = 1 / (seconds * SoundGenerator.fs) }
        @inline(__always) mutating func next(_ rng: inout Rng) -> Double {
            t += step
            if t >= 1 { t -= 1; a = b; b = rng.next01() }
            let m = (1 - cos(t * .pi)) * 0.5
            return a + (b - a) * m
        }
    }

    /// Freeverb-style reverb: 4 combs + 2 all-passes per channel.
    final class Reverb {
        private static let combLengths = [1116, 1188, 1277, 1356]
        private static let allPassLengths = [556, 441]
        private static let spread = 23

        private struct Line {
            let buf: UnsafeMutablePointer<Float>
            let len: Int
            var idx = 0
            var store = 0.0
        }

        private var combs: [[Line]]
        private var allPasses: [[Line]]
        let feedback: Double
        let damp: Double

        init(feedback: Double, damp: Double) {
            self.feedback = feedback
            self.damp = damp
            func line(_ n: Int) -> Line {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
                p.initialize(repeating: 0, count: n)
                return Line(buf: p, len: n)
            }
            combs = (0..<2).map { ch in Reverb.combLengths.map { line($0 + ch * Reverb.spread) } }
            allPasses = (0..<2).map { ch in Reverb.allPassLengths.map { line($0 + ch * Reverb.spread) } }
        }

        deinit {
            for row in combs + allPasses { for l in row { l.buf.deallocate() } }
        }

        @inline(__always) func run(_ ch: Int, _ input: Double) -> Double {
            var out = 0.0
            for i in 0..<4 {
                let y = Double(combs[ch][i].buf[combs[ch][i].idx])
                combs[ch][i].store = y * (1 - damp) + combs[ch][i].store * damp
                combs[ch][i].buf[combs[ch][i].idx] = Float(input + combs[ch][i].store * feedback)
                combs[ch][i].idx += 1
                if combs[ch][i].idx >= combs[ch][i].len { combs[ch][i].idx = 0 }
                out += y
            }
            for i in 0..<2 {
                let b = Double(allPasses[ch][i].buf[allPasses[ch][i].idx])
                allPasses[ch][i].buf[allPasses[ch][i].idx] = Float(out + b * 0.5)
                out = b - out
                allPasses[ch][i].idx += 1
                if allPasses[ch][i].idx >= allPasses[ch][i].len { allPasses[ch][i].idx = 0 }
            }
            return out
        }
    }

    /// Short one-shot voices: rain drops (tonal) and fire pops (noise).
    struct Voice {
        var amp = 0.0, decay = 0.0, freq = 0.0, phase = 0.0, glide = 1.0, pan = 0.5
        var tonal = true
        var hp = OnePole(1000)
    }

    private var voices = [Voice](repeating: Voice(), count: 24)

    private func spawn(amp: Double, tau: Double, freq: Double, glide: Double, pan: Double, tonal: Bool, hpHz: Double) {
        for i in 0..<voices.count where voices[i].amp < 1e-4 {
            voices[i] = Voice(amp: amp, decay: exp(-1 / (tau * Self.fs)), freq: freq, phase: 0, glide: glide, pan: pan, tonal: tonal, hp: OnePole(hpHz))
            return
        }
    }

    @inline(__always) private func voicesTick() -> (Double, Double) {
        var l = 0.0, r = 0.0
        for i in 0..<voices.count where voices[i].amp >= 1e-4 {
            var s: Double
            if voices[i].tonal {
                s = sin(voices[i].phase)
                voices[i].phase += Self.tau * voices[i].freq / Self.fs
                voices[i].freq *= voices[i].glide
            } else {
                s = voices[i].hp.hp(white())
            }
            s *= voices[i].amp
            voices[i].amp *= voices[i].decay
            l += s * (1 - voices[i].pan)
            r += s * voices[i].pan
        }
        return (l, r)
    }

    // MARK: Scape state

    // Brown
    private var bnL = Brown(), bnR = Brown()
    private var bnLpL = OnePole(700), bnLpR = OnePole(700)
    private var bnW: Wander

    // Rain
    private var rnPL = Pink(), rnPR = Pink()
    private var rnHpL = Biquad.highpass(420, 0.6), rnHpR = Biquad.highpass(420, 0.6)
    private var rnLpL = Biquad.lowpass(6500, 0.6), rnLpR = Biquad.lowpass(6500, 0.6)
    private var rnB = Brown()
    private var rnRum = OnePole(180)
    private var rnW: Wander
    private let rnRv = Reverb(feedback: 0.80, damp: 0.4)

    // Ocean
    private var ocPhase = [0.0, 0.55], ocPeriod = [10.5, 11.7]
    private var ocB = [Brown(), Brown()], ocP = [Pink(), Pink()]
    private var ocLp = [Biquad.lowpass(400, 0.5), Biquad.lowpass(400, 0.5)]
    private var ocFoam = [OnePole(2500), OnePole(2500)]
    private let ocRv = Reverb(feedback: 0.78, damp: 0.5)
    private var ocCount = 0

    // Fireplace
    private var fpB = Brown(), fpB2 = Brown()
    private var fpLp = OnePole(420), fpLp2 = OnePole(420), fpHiss = OnePole(3500)
    private var fpP = Pink(), fpFlameP = Pink()
    private var fpFlameHp = Biquad.highpass(350, 0.7), fpFlameLp = Biquad.lowpass(1400, 0.7)
    private var fpFlick: Wander
    private let fpRv = Reverb(feedback: 0.70, damp: 0.5)
    private var fpCluster = 0
    private var fpGap = 0.0

    // Soft pad
    private static let chords: [[Double]] = [
        [146.83, 220.00, 277.18, 329.63, 369.99], // Dmaj9
        [123.47, 185.00, 220.00, 277.18, 293.66], // Bm9
        [98.00, 146.83, 185.00, 220.00, 246.94],  // Gmaj9
        [110.00, 164.81, 220.00, 246.94, 277.18], // A6/9
    ]
    private var padPhase = [[Double]](repeating: [0, 0], count: 5)
    private var padW: [Wander]
    private var padLp = [Biquad.lowpass(1600, 0.6), Biquad.lowpass(1600, 0.6)]
    private let padRv = Reverb(feedback: 0.88, damp: 0.35)
    private var padT = 0.0
    private var padAir = Brown()

    // Master
    private var dcL = Biquad.highpass(35, 0.707), dcR = Biquad.highpass(35, 0.707)

    init(soundscape: Soundscape) {
        self.soundscape = soundscape
        bnW = Wander(seconds: 19, a: 0.4, b: 0.7)
        rnW = Wander(seconds: 13, a: 0.6, b: 0.3)
        fpFlick = Wander(seconds: 1.7, a: 0.5, b: 0.8)
        padW = (0..<5).map { Wander(seconds: 6 + Double($0) * 1.7, a: 0.5, b: 0.8) }
    }

    func render(frameCount: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
        else { return }

        let scape = soundscape
        let gain = scape.gain
        for i in 0..<frameCount {
            var (l, r): (Double, Double)
            switch scape {
            case .brownNoise: (l, r) = brownTick()
            case .rain: (l, r) = rainTick()
            case .ocean: (l, r) = oceanTick()
            case .fireplace: (l, r) = fireTick()
            case .ambient: (l, r) = padTick()
            }
            l = Self.softclip(dcL.run(l) * gain)
            r = Self.softclip(dcR.run(r) * gain)
            left[i] = Float(l)
            right[i] = Float(r)
        }
    }

    /// Transparent below 0.7; rounds peaks off smoothly above (never exceeds 1).
    @inline(__always) private static func softclip(_ x: Double) -> Double {
        let a = abs(x)
        if a <= 0.7 { return x }
        let y = 0.7 + 0.3 * tanh((a - 0.7) / 0.3)
        return x < 0 ? -y : y
    }

    // MARK: Scapes

    private func brownTick() -> (Double, Double) {
        let a = bnL.next(white()), b = bnR.next(white())
        let g = 0.88 + 0.12 * bnW.next(&rng)
        let l = bnLpL.lp(a * 0.8 + b * 0.2), r = bnLpR.lp(b * 0.8 + a * 0.2)
        return (l * g * 1.25, r * g * 1.25)
    }

    private func rainTick() -> (Double, Double) {
        let intensity = 0.8 + 0.2 * rnW.next(&rng)
        let l = rnLpL.run(rnHpL.run(rnPL.next(white()))) * intensity * 1.1
        let r = rnLpR.run(rnHpR.run(rnPR.next(white()))) * intensity * 1.1
        let rum = rnRum.lp(rnB.next(white())) * 0.22
        if rnd01() < 55 * intensity / Self.fs {
            let u = rnd01()
            spawn(amp: 0.02 + 0.12 * u * u * u, tau: 0.0025 + 0.004 * rnd01(), freq: 1900 + 2600 * rnd01(),
                  glide: 1.00004, pan: rnd01(), tonal: true, hpHz: 1000)
        }
        let (dl, dr) = voicesTick()
        let wetIn = (l + r) * 0.5 + (dl + dr) * 0.5
        let wl = rnRv.run(0, wetIn * 0.015), wr = rnRv.run(1, wetIn * 0.015)
        return (l + rum + dl + wl, r + rum + dr + wr)
    }

    private func waveEnvelope(_ c: Int) -> Double {
        ocPhase[c] += 1 / (ocPeriod[c] * Self.fs)
        if ocPhase[c] >= 1 { ocPhase[c] -= 1; ocPeriod[c] = 8.5 + 4.5 * rnd01() }
        let p = ocPhase[c]
        if p < 0.38 { let x = p / 0.38; return x * x * (3 - 2 * x) }
        return exp(-(p - 0.38) * 4.2)
    }

    private func oceanTick() -> (Double, Double) {
        var out = (0.0, 0.0)
        for c in 0..<2 {
            let e = waveEnvelope(c)
            if ocCount & 31 == 0 { ocLp[c].setLowpass(260 + 2400 * pow(e, 1.6), 0.55) }
            let src = 0.65 * ocB[c].next(white()) + 0.5 * ocP[c].next(white())
            let body = ocLp[c].run(src) * (0.14 + 0.86 * e)
            let foam = ocFoam[c].hp(white()) * e * e * e * 0.05
            let v = (body + foam) * 1.15
            if c == 0 { out.0 = v } else { out.1 = v }
        }
        ocCount &+= 1
        let wl = ocRv.run(0, (out.0 + out.1) * 0.012), wr = ocRv.run(1, (out.0 + out.1) * 0.012)
        return (out.0 * 0.85 + out.1 * 0.15 + wl, out.1 * 0.85 + out.0 * 0.15 + wr)
    }

    private func fireTick() -> (Double, Double) {
        let flick = 0.8 + 0.2 * fpFlick.next(&rng)
        let roarL = fpLp.lp(fpB.next(white())) * 0.35 * flick
        let roarR = fpLp2.lp(fpB2.next(white())) * 0.35 * flick
        let flame = fpFlameLp.run(fpFlameHp.run(fpFlameP.next(white()))) * 0.55 * flick * flick
        let hiss = fpHiss.hp(fpP.next(white())) * 0.08 * flick
        if fpCluster > 0 {
            fpGap -= 1
            if fpGap <= 0 {
                let u = rnd01()
                spawn(amp: 0.12 + 0.55 * u * u * u, tau: 0.0006 + 0.003 * rnd01(), freq: 0, glide: 1,
                      pan: 0.2 + 0.6 * rnd01(), tonal: false, hpHz: 900 + 2500 * rnd01())
                fpCluster -= 1
                fpGap = (0.004 + 0.03 * rnd01()) * Self.fs
            }
        } else if rnd01() < 3.4 / Self.fs {
            fpCluster = 1 + Int(rnd01() * rnd01() * 6)
            fpGap = 0
        } else if rnd01() < 9 / Self.fs {
            spawn(amp: 0.05 + 0.14 * rnd01(), tau: 0.0005 + 0.0015 * rnd01(), freq: 0, glide: 1,
                  pan: rnd01(), tonal: false, hpHz: 2500)
        }
        let (cl, cr) = voicesTick()
        let wl = fpRv.run(0, (cl + cr) * 0.02), wr = fpRv.run(1, (cl + cr) * 0.02)
        return (roarL + flame + hiss + cl + wl, roarR + flame + hiss + cr + wr)
    }

    @inline(__always) private static func padOsc(_ ph: Double) -> Double {
        sin(ph) + 0.22 * sin(2 * ph) + 0.07 * sin(3 * ph)
    }

    private func padTick() -> (Double, Double) {
        let chordLength = 14.0, fade = 5.0
        padT += 1 / Self.fs
        let pos = padT.truncatingRemainder(dividingBy: chordLength * 4)
        let ci = Int(pos / chordLength) % 4, ni = (ci + 1) % 4
        let into = pos - Double(ci) * chordLength
        var mix = 0.0
        if into > chordLength - fade { mix = (1 - cos((into - (chordLength - fade)) / fade * .pi)) * 0.5 }
        let startGain = padT < 4 ? padT / 4 : 1
        var sumL = 0.0, sumR = 0.0
        for v in 0..<5 {
            let f = Self.chords[ci][v] * (1 - mix) + Self.chords[ni][v] * mix
            let amp = (0.55 + 0.45 * padW[v].next(&rng)) * (v == 0 ? 0.32 : 0.2)
            let pan = 0.25 + 0.5 * (Double(v) / 4)
            for d in 0..<2 {
                let det = d == 0 ? 0.9983 : 1.0017
                padPhase[v][d] += Self.tau * f * det / Self.fs
                if padPhase[v][d] > Self.tau { padPhase[v][d] -= Self.tau }
                let s = Self.padOsc(padPhase[v][d]) * amp * 0.5
                sumL += s * (1 - pan) * 2
                sumR += s * pan * 2
            }
        }
        let air = padAir.next(white()) * 0.015
        let l = padLp[0].run(sumL) * startGain + air, r = padLp[1].run(sumR) * startGain + air
        let wl = padRv.run(0, (l + r) * 0.02), wr = padRv.run(1, (l + r) * 0.02)
        return ((l * 0.55 + wl) * 0.9, (r * 0.55 + wr) * 0.9)
    }
}
