import AVFoundation
import Foundation
import QuartzCore

/// The first Set Up Sunlight page's ten seconds of sound, a calm sunrise: a singing bowl and a low, dark
/// open fifth on D whose brightness comes up slowly like light, a soft line climbing A, B, D and wind
/// chimes over it, and at `climax`, the moment the welcome page arrives, one clear, soft chime as the
/// major third blooms in. High rays of sine and a few more chimes glow, the chord settles to plain D
/// major, and it closes on `cadence`: one warm, high D major chord, struck at once, its top D ringing
/// last. Made here, sample by sample, so there's no recording to license.
enum WelcomeMusic {
    static let sampleRate = 44_100.0
    static let duration = 10.0
    /// The bloom, in seconds: when the third arrives and the wizard brings in its first page.
    static let climax = 2.8
    /// The loudest sample, the bloom, at full volume: about −9 dBFS.
    static let peak: Float = 0.35

    private static let playedKey = "SunlightWelcomeMusicPlayed"
    /// Heard once: only the first time the wizard opens on its welcome page.
    static var played: Bool {
        get { UserDefaults.standard.bool(forKey: playedKey) }
        set { UserDefaults.standard.set(newValue, forKey: playedKey) }
    }

    // MARK: The music

    /// The pad before the bloom, low to high, in Hz, with how loud each is: D A E, no third yet.
    static let dawn: [(frequency: Double, level: Double)] = [
        (73.42, 0.5), (146.83, 0.45), (220.00, 0.38), (329.63, 0.3), (440.00, 0.24),
    ]
    /// What the bloom adds: F♯ and C♯, making it D major nine.
    static let bloom: [(frequency: Double, level: Double)] = [
        (369.99, 0.36), (554.37, 0.22), (739.99, 0.15),
    ]

    /// The line: the fifth, the sixth, then the octave just before the bloom, held into it.
    static let line: [(time: Double, frequency: Double)] = [(0.9, 440.00), (1.7, 493.88), (2.45, 587.33)]

    /// The rays after the bloom: when, how high, and where between the speakers (0 left, 1 right).
    static let rays: [(time: Double, frequency: Double, pan: Double)] = [
        (climax + 0.15, 880.00, 0.35), (climax + 0.5, 1108.73, 0.65),
        (climax + 0.85, 1318.51, 0.4), (climax + 1.2, 1479.98, 0.6),
    ]

    /// The chimes, all on D major's pentatonic notes (D E F♯ A B), as irregular as wind: a few before the
    /// bloom, the clearest on it (D6 over D5, ringing longest), then more as it fades, each a little quieter.
    static let chimes: [(time: Double, frequency: Double, pan: Double, level: Double, ring: Double)] = [
        (0.45, 880.00, 0.38, 0.45, 3.5), (1.15, 739.99, 0.64, 0.45, 3.5), (1.62, 1318.51, 0.3, 0.35, 3),
        (2.17, 987.77, 0.58, 0.5, 3.5),
        (climax, 1174.66, 0.5, 1, 5.5), (climax, 587.33, 0.5, 0.6, 5.5),
        (3.38, 1479.98, 0.7, 0.4, 3.5), (3.86, 880.00, 0.33, 0.4, 3.5), (4.4, 739.99, 0.62, 0.3, 3.5),
    ]

    /// The close, after the chimes thin out: D major from A4 to D6, all at once, the top D ringing longest.
    static let cadence = 5.0
    static let cadenceChord: [(frequency: Double, level: Double, ring: Double, pan: Double)] = [
        (440.00, 0.45, 2.2, 0.5), (587.33, 0.8, 2.6, 0.42), (739.99, 0.7, 2.8, 0.58),
        (880.00, 0.6, 3.0, 0.45), (1174.66, 0.75, 4.4, 0.55),
    ]
    /// The singing bowl, low under it all from the start: D4, struck softly, ringing the whole way.
    static let bowl = 293.66

    /// How much of the third sounds at `t`: none before the bloom, all of it a quarter second after.
    static func third(at t: Double) -> Double { smoothstep(climax - 0.05, climax + 0.25, t) }

    /// How full the pad is: a low quarter at first, gathering to the bloom, a little swell on it, settling.
    static func swell(at t: Double) -> Double {
        let gather = 0.35 + 0.65 * pow(min(t / climax, 1), 1.3) * (1 - 0.2 * smoothstep(climax + 0.5, climax + 2.5, t))
        let lift = 0.07 * smoothstep(climax - 0.1, climax + 0.4, t) * (1 - smoothstep(climax + 0.5, climax + 2, t))
        return gather + lift
    }

    /// The light coming up: the pad's filter opens from a dark 300 Hz to a warm 2 kHz by the bloom.
    static func brightness(at t: Double) -> Double {
        300 * pow(2000 / 300, smoothstep(0, climax + 0.5, t))
    }

    /// Everything but the closing chord: in over a third of a second, then from `fadeFrom` a soft
    /// exponential tail. The chord and the room decay on their own, and `end` takes the last whisper.
    static let fadeFrom = 4.2
    static func envelope(at t: Double) -> Double {
        smoothstep(0, 0.35, t) * (t < fadeFrom ? 1 : exp(-(t - fadeFrom) / 1.3))
    }
    /// The very end: silent on the last sample, over the last half second.
    static func end(at t: Double) -> Double { 1 - smoothstep(duration - 0.5, duration, t) }

    /// The pad's E and C♯ (the ninth and seventh) leave before the close, so it settles to plain D major.
    static func colour(at t: Double) -> Double { 1 - smoothstep(cadence - 1.2, cadence, t) }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let u = min(max((x - a) / (b - a), 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// Left and right, `duration` long at `sampleRate`, peaking at `peak`.
    static func render(sampleRate: Double = sampleRate) -> (left: [Float], right: [Float]) {
        let count = Int(duration * sampleRate)
        var padLeft = [Double](repeating: 0, count: count)
        var padRight = [Double](repeating: 0, count: count)
        let tau = 2 * Double.pi
        let times = (0..<count).map { Double($0) / sampleRate }

        // The pad: soft saws, three to a voice, the flat one leaning left and the sharp one right, each
        // drifting a few cents on its own slow wander the way old oscillators do.
        let detunes: [(cents: Double, left: Double, right: Double)] = [(-7, 0.8, 0.2), (0, 0.5, 0.5), (7, 0.2, 0.8)]
        let fullness = times.map(swell)
        let arriving = times.map(third)
        let voices = dawn.map { ($0, false) } + bloom.map { ($0, true) }
        let colouring = times.map(colour)
        for (v, (voice, isThird)) in voices.enumerated() {
            let isColour = voice.frequency == 329.63 || voice.frequency == 554.37
            for (d, detune) in detunes.enumerated() {
                let level = voice.level / Double(detunes.count)
                let wander = 0.07 + 0.031 * Double(v + d), wanderPhase = Double(v * 5 + d * 2)
                var phase = Double(v + d) * 0.37
                for i in 0..<count {
                    let weight = fullness[i] * (isThird ? arriving[i] : 1) * (isColour ? colouring[i] : 1)
                    let cents = detune.cents + 3 * sin(tau * wander * times[i] + wanderPhase)
                    let step = voice.frequency * (1 + cents * 0.000_577_8) / sampleRate
                    phase += step
                    if phase >= 1 { phase -= 1 }
                    guard weight > 0 else { continue }
                    let s = saw(phase, step) * level * weight
                    padLeft[i] += s * detune.left
                    padRight[i] += s * detune.right
                }
            }
        }
        // The light: two gentle low-passes opening with `brightness`, then a little warmth from tanh.
        for channel in 0..<2 {
            var x = channel == 0 ? padLeft : padRight
            var a = 0.0, b = 0.0
            for i in 0..<count {
                let k = 1 - exp(-tau * brightness(at: times[i]) / sampleRate)
                a += k * (x[i] - a)
                b += k * (a - b)
                x[i] = b
            }
            let loudest = x.map(abs).max() ?? 1
            let drive = 1.2
            x = x.map { tanh(drive * $0 / loudest) / tanh(drive) }
            if channel == 0 { padLeft = x } else { padRight = x }
        }
        var left = padLeft, right = padRight

        // The line: a round tone, gliding from note to note, swelling in and fading after the bloom.
        var linePhase = 0.0
        for i in 0..<count {
            let t = times[i]
            var frequency = line[0].frequency
            for (n, note) in line.enumerated().dropFirst() {
                frequency += (note.frequency - line[n - 1].frequency) * smoothstep(note.time - 0.06, note.time + 0.06, t)
            }
            let vibrato = 1 + 0.002 * sin(tau * 4.2 * t) * smoothstep(line[0].time + 0.3, line[0].time + 1, t)
            linePhase += tau * frequency * vibrato / sampleRate
            let amp = 0.11 * smoothstep(line[0].time - 0.2, line[0].time + 0.6, t) * (1 - smoothstep(climax + 0.2, climax + 3, t))
            guard amp > 0 else { continue }
            let s = (sin(linePhase) + 0.15 * sin(2 * linePhase)) * amp
            left[i] += s * 0.55
            right[i] += s * 0.45
        }

        // The rays: high sines that fade in slowly, glow with a slight shimmer, and fade.
        for ray in rays {
            let start = Int(ray.time * sampleRate)
            let l = cos(ray.pan * .pi / 2), r = sin(ray.pan * .pi / 2)
            for k in 0..<(count - min(start, count)) {
                let t = Double(k) / sampleRate
                let amp = 0.04 * smoothstep(0, 0.6, t) * exp(-t / 2.2) * (1 + 0.1 * sin(tau * 4 * t))
                let s = amp * sin(tau * ray.frequency * t)
                left[start + k] += s * l
                right[start + k] += s * r
            }
        }

        // A chime or a bowl: a slow, soft strike (no click), a pure tone with faint bowl overtones at 2.76
        // and 5.4 times that die first, and a long ring. `beat` detunes a second copy for a bowl's slow wah.
        func ring(at time: Double, _ frequency: Double, pan: Double, level: Double, ring: Double,
                  attack: Double = 0.03, beat: Double = 0) {
            let start = Int(time * sampleRate)
            let l = cos(pan * .pi / 2), r = sin(pan * .pi / 2)
            for k in 0..<(count - min(start, count)) {
                let t = Double(k) / sampleRate
                var tone = sin(tau * frequency * t)
                if beat > 0 { tone = 0.5 * (tone + sin(tau * (frequency + beat) * t)) }
                let s = level * smoothstep(0, attack, t) * (tone * exp(-t / ring)
                                                            + 0.16 * sin(tau * 2.76 * frequency * t) * exp(-t / (ring / 4))
                                                            + 0.05 * sin(tau * 5.4 * frequency * t) * exp(-t / (ring / 8)))
                left[start + k] += s * l
                right[start + k] += s * r
            }
        }
        ring(at: 0.05, bowl, pan: 0.5, level: 0.07, ring: 6, attack: 0.04, beat: 0.7)
        for chime in chimes { ring(at: chime.time, chime.frequency, pan: chime.pan, level: 0.08 * chime.level, ring: chime.ring) }

        for i in 0..<count {
            let e = envelope(at: times[i])
            left[i] *= e
            right[i] *= e
        }

        // The close: each note a bell-and-organ tone, a few harmonics (none above 4 kHz) that fade faster
        // the higher they are and a faint chime partial, struck softly, swelling a touch, then a long decay.
        let start = Int(cadence * sampleRate)
        for (n, note) in cadenceChord.enumerated() {
            let l = cos(note.pan * .pi / 2), r = sin(note.pan * .pi / 2)
            let harmonics = (1...5).filter { Double($0) * note.frequency < 4000 }
            for (cents, side) in [(-4.0, 0.6), (4.0, 0.4)] {
                let f = note.frequency * pow(2, cents / 1200)
                for k in 0..<(count - min(start, count)) {
                    let t = Double(k) / sampleRate
                    var tone = 0.0
                    for h in harmonics {
                        let m = Double(h)
                        tone += sin(tau * f * m * t + m * Double(n)) / pow(m, 1.4) * exp(-t * (m - 1) * 0.9)
                    }
                    tone += 0.06 * sin(tau * 2.76 * f * t) * exp(-t / 0.5)
                    let amp = 0.17 * note.level * smoothstep(0, 0.02, t) * (1 + 0.15 * smoothstep(0.02, 0.35, t))
                        * exp(-t / note.ring)
                    let s = tone * amp
                    left[start + k] += s * l * 2 * side
                    right[start + k] += s * r * 2 * (1 - side)
                }
            }
        }

        // The room: a Freeverb-style hall, the right side's delays a little longer than the left's.
        left = reverb(left, spread: 0, sampleRate: sampleRate)
        right = reverb(right, spread: 23, sampleRate: sampleRate)

        var loudest = 0.0
        for i in 0..<count {
            let e = end(at: times[i])
            left[i] *= e
            right[i] *= e
            loudest = max(loudest, abs(left[i]), abs(right[i]))
        }
        let gain = loudest > 0 ? Double(peak) / loudest : 0
        return (left.map { Float($0 * gain) }, right.map { Float($0 * gain) })
    }

    /// A saw with its corner smoothed (PolyBLEP), so the low-passed pad stays clean. `phase` and
    /// `step` in cycles.
    private static func saw(_ phase: Double, _ step: Double) -> Double {
        var s = 2 * phase - 1
        if phase < step {
            let u = phase / step
            s -= u + u - u * u - 1
        } else if phase > 1 - step {
            let u = (phase - 1) / step
            s -= u * u + u + u + 1
        }
        return s
    }

    /// Eight damped combs in parallel and four all-passes after them, mixed with the dry sound.
    private static func reverb(_ input: [Double], spread: Int, sampleRate: Double) -> [Double] {
        let scale = sampleRate / 44_100
        let combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617].map { Int(Double($0 + spread) * scale) }
        let passes = [556, 441, 341, 225].map { Int(Double($0 + spread) * scale) }
        let feedback = 0.86, damping = 0.3, wet = 0.32, dry = 0.7
        var wetSignal = [Double](repeating: 0, count: input.count)
        for length in combs {
            var buffer = [Double](repeating: 0, count: length)
            var index = 0, filtered = 0.0
            for i in 0..<input.count {
                let out = buffer[index]
                filtered = out * (1 - damping) + filtered * damping
                buffer[index] = input[i] * 0.03 + filtered * feedback
                index = (index + 1) % length
                wetSignal[i] += out
            }
        }
        for length in passes {
            var buffer = [Double](repeating: 0, count: length)
            var index = 0
            for i in 0..<wetSignal.count {
                let delayed = buffer[index]
                let out = delayed - wetSignal[i]
                buffer[index] = wetSignal[i] + delayed * 0.5
                index = (index + 1) % length
                wetSignal[i] = out
            }
        }
        return input.indices.map { input[$0] * dry + wetSignal[$0] * wet }
    }

    /// 16-bit stereo WAV of `render()`, for `--welcome-music <file.wav>`.
    static func wav() -> Data {
        let (left, right) = render()
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(left.count * 4)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(2)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 4))
        append(UInt16(4)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for i in left.indices {
            append(Int16(max(-1, min(1, left[i])) * 32767))
            append(Int16(max(-1, min(1, right[i])) * 32767))
        }
        return data
    }

    // MARK: Playing

    /// Plays the music once through the default output, so the Mac's volume and mute apply, and fades
    /// it away early when the person moves on.
    @MainActor
    final class Player {
        private var engine: AVAudioEngine?
        private var node: AVAudioPlayerNode?
        private var fadeTimer: Timer?
        private var cueTimers: [Timer] = []
        /// Things to do at moments in the music. Each runs once: `true` when it's heard at that moment,
        /// `false` when it runs early because the music couldn't play or was stopped.
        private var cues: [(at: TimeInterval, run: (Bool) -> Void)] = []
        private var cancelled = false

        /// Renders off the main thread (well under a second), then plays, with each cue timed against
        /// the audio clock (the moment playback is scheduled on the output, plus its latency).
        func play(cues: [(at: TimeInterval, run: (Bool) -> Void)]) {
            guard engine == nil, self.cues.isEmpty else { return cues.forEach { $0.run(false) } }
            cancelled = false
            self.cues = cues.sorted { $0.at < $1.at }
            DispatchQueue.global(qos: .userInitiated).async {
                let samples = WelcomeMusic.render()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.start(samples) }
                }
            }
        }

        private func start(_ samples: (left: [Float], right: [Float])) {
            defer { if engine == nil { fireCues(heard: false) } }
            guard !cancelled, engine == nil,
                  let format = AVAudioFormat(standardFormatWithSampleRate: WelcomeMusic.sampleRate, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.left.count)),
                  let channels = buffer.floatChannelData else { return }
            buffer.frameLength = buffer.frameCapacity
            samples.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: $0.count) }
            samples.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: $0.count) }

            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.stop() }
                }
            }
            do {
                engine.prepare()
                try engine.start()
            } catch {
                Log.note("Setup: welcome music couldn't start: \(error.localizedDescription)")
                return
            }
            // Starts a moment from now on the host clock, so the start is known exactly; the sound
            // reaches the speakers the output's latency after that.
            let begin = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
            node.play(at: AVAudioTime(hostTime: begin))
            self.engine = engine
            self.node = node
            let heard = AVAudioTime.seconds(forHostTime: begin) + engine.outputNode.presentationLatency
            for cue in cues {
                let timer = Timer(timeInterval: max(heard + cue.at - CACurrentMediaTime(), 0), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fireCues(upTo: cue.at) }
                }
                timer.tolerance = 0
                RunLoop.main.add(timer, forMode: .common)
                cueTimers.append(timer)
            }
        }

        /// Runs the cues due by `upTo` (all of them by default), in order, each once.
        private func fireCues(upTo: TimeInterval = .infinity, heard: Bool = true) {
            while let cue = cues.first, cue.at <= upTo {
                cues.removeFirst()
                cue.run(heard)
            }
            if cues.isEmpty {
                cueTimers.forEach { $0.invalidate() }
                cueTimers = []
            }
        }

        /// The person moved on (the window closed or stepped aside): out over `duration`, then quiet.
        func fadeOut(duration: TimeInterval = 0.8) {
            cancelled = true
            fireCues(heard: false)
            guard let node, fadeTimer == nil else { return }
            let from = node.volume
            let began = Date()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let u = min(Date().timeIntervalSince(began) / duration, 1)
                    self.node?.volume = from * Float(1 - u) * Float(1 - u)
                    if u >= 1 { self.stop() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            fadeTimer = timer
        }

        private func stop() {
            fireCues(heard: false)
            fadeTimer?.invalidate()
            fadeTimer = nil
            node?.stop()
            engine?.stop()
            node = nil
            engine = nil
        }
    }
}
