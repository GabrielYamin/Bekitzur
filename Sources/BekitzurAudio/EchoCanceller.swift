import Accelerate

/// Takes the other side of a call out of the microphone, where laptop speakers put a copy of it: on November 2 the copy
/// was only 2 dB quieter than the system audio, and silencing the microphone whenever the other side talked lost what
/// the user said over them.
///
/// The copy is predicted from the system audio, frequency by frequency, through each frequency's echo path over the last
/// 128 ms, fitted to the call by least squares where the other side talks, then fitted again on the moments the first fit
/// explains, since the others hold the user. The prediction is subtracted, and what's left of the copy is turned down
/// where nothing louder is left, frequency by frequency, before the microphone is put back together.
public enum EchoCanceller {
    public struct Result: Sendable {
        /// The microphone without the copy, 16 kHz like the input.
        public let microphone: [Float]
        /// Per frame of `frameSeconds`, in the speech band: the predicted copy's power and the rest's, and the room's
        /// noise, for telling where the microphone has speech of its own.
        public let copy: [Double]
        public let rest: [Double]
        public let noise: Double
        /// Whether the other side talks in each frame.
        public let talking: [Bool]

        /// Frame `t` is centered `t` frames into the microphone.
        public static let frameSeconds = Double(hop) / 16_000

        /// Where the microphone has speech of its own: what's left is above the predicted copy by `copyMargin` and the
        /// noise by `noiseMargin` (powers), in most of the five frames around.
        public func ownSpeech(copyMargin: Double = 1, noiseMargin: Double = 10) -> [Bool] {
            let raw = copy.indices.map { rest[$0] > max(copyMargin * copy[$0], noiseMargin * noise) }
            return raw.indices.map { t in raw[max(0, t - 2)...min(raw.count - 1, t + 2)].filter { $0 }.count >= 3 }
        }

        /// The microphone silenced where the other side talks and it has no speech of its own (9 dB above what's left of
        /// the copy and 20 dB above the noise), with 50 ms more on each side of its own speech so words keep their edges.
        /// What's left of the copy is quiet but still a voice to a speaker separator: separated on its own, the cleaned
        /// microphone of the November 2 call had 42 seconds of the other person.
        public func ownSpeechOnly() -> [Float] {
            let silenced = silenced()
            guard !silenced.isEmpty else { return microphone }
            var result = microphone
            let fade = 64
            for (i, sample) in microphone.enumerated() {
                let t = min(silenced.count - 1, (i + hop / 2) / hop)
                guard silenced[t] else { continue }
                // Into and out of a silenced stretch over 4 ms, so its edges don't click.
                let before = t > 0 && !silenced[t - 1] ? i - (t * hop - hop / 2) : fade
                let after = t + 1 < silenced.count && !silenced[t + 1] ? (t * hop + hop / 2) - i : fade
                result[i] = sample * max(0, 1 - Float(min(before, after, fade)) / Float(fade))
            }
            return result
        }

        /// Where `ownSpeechOnly()` has speech left, in seconds: above what's left of the copy and 10 dB above the noise,
        /// outside what it silences. Speech recognition writes words into silence and near silence: "תודה רבה לך, אדוני
        /// היושב-ראש" where the microphone was silenced on November 2, and in a quiet moment on November 1.
        public func speech() -> [ClosedRange<Double>] {
            let own = ownSpeech(), silenced = silenced()
            var stretches: [ClosedRange<Double>] = []
            var first: Int?
            for t in 0...own.count {
                let speaking = t < own.count && own[t] && !silenced[t]
                if speaking, first == nil { first = t }
                if !speaking, let start = first {
                    stretches.append(max(0, (Double(start) - 0.5) * Self.frameSeconds)...(Double(t) - 0.5) * Self.frameSeconds)
                    first = nil
                }
            }
            return stretches
        }

        /// Each frame where the other side talks and the microphone has no speech of its own within 50 ms.
        private func silenced() -> [Bool] {
            let own = ownSpeech(copyMargin: 8, noiseMargin: 100), reach = 3
            return own.indices.map { t in talking[t] && !own[max(0, t - reach)...min(own.count - 1, t + reach)].contains(true) }
        }
    }

    private static let frame = 512, hop = 256, taps = 8
    /// Frequencies the echo path is fitted for: 31 Hz to 8 kHz.
    private static let modelled = 1..<(frame / 2)
    /// Where speech is, for the powers: 218 Hz to 4 kHz.
    private static let speech = 7...128
    /// What's left of the copy after subtracting it, as a share of the prediction (the subtraction took 7 to 10 dB off on
    /// three calls), and how far it's turned down.
    private static let leftover: Float = 0.35, floor: Float = 0.1

    /// - Parameters:
    ///   - microphone: 16 kHz mono, lined up with `system`.
    public static func cancel(microphone: [Float], system: [Float]) -> Result {
        let count = microphone.count
        let frames = count >= frame ? (count + hop) / hop + 1 : 0
        // Half a frame of silence first, so the first samples are covered by two frames like the rest.
        let padded = { (x: [Float]) in [Float](repeating: 0, count: hop) + x + [Float](repeating: 0, count: max(0, frames * hop + frame - hop - x.count)) }
        let mic = padded(microphone), sys = padded(system)
        guard frames > taps, let stft = STFT() else {
            return Result(microphone: microphone, copy: [], rest: [], noise: 0, talking: [])
        }

        // Where the other side talks: the system audio's loudest frame over the last 160 ms is within 40 dB of the call's.
        let systemPower = (0..<frames).map { stft.power(of: sys, at: $0) }
        let microphonePower = (0..<frames).map { stft.power(of: mic, at: $0) }
        let loudest = systemPower.max() ?? 0
        let talking = (0..<frames).map { t in loudest > 0 && systemPower[max(0, t - 9)...t].max()! > loudest * 1e-4 }
        let noise = microphonePower.sorted()[frames / 10]
        guard talking.contains(true) else {
            return Result(microphone: microphone, copy: [Double](repeating: 0, count: frames), rest: microphonePower, noise: noise, talking: talking)
        }

        let first = EchoPath(fittedTo: mic, from: sys, frames: frames, stft: stft) { talking[$0] }
        var copyOnly = [Bool](repeating: false, count: frames)
        first.run(on: mic, from: sys, frames: frames, stft: stft) { t, heard, predicted in
            guard talking[t] else { return }
            let (copy, rest) = powers(heard, predicted)
            copyOnly[t] = rest < 0.5 * copy
        }
        let path = copyOnly.filter { $0 }.count > 4 * taps ? EchoPath(fittedTo: mic, from: sys, frames: frames, stft: stft) { copyOnly[$0] } : first

        var output = [Float](repeating: 0, count: mic.count)
        var copy = [Double](repeating: 0, count: frames), rest = microphonePower
        path.run(on: mic, from: sys, frames: frames, stft: stft) { t, heard, predicted in
            guard talking[t] else {
                stft.add(heard, at: t, into: &output)
                return
            }
            (copy[t], rest[t]) = powers(heard, predicted)
            var cleaned = heard
            for bin in modelled {
                let left = Complex(re: heard.re[bin] - predicted.re[bin], im: heard.im[bin] - predicted.im[bin])
                let leftPower = left.power, echo = leftover * leftover * (predicted.re[bin] * predicted.re[bin] + predicted.im[bin] * predicted.im[bin])
                let gain = leftPower > 0 ? max(floor, 1 - echo / leftPower) : floor
                cleaned.re[bin] = gain * left.re
                cleaned.im[bin] = gain * left.im
            }
            stft.add(cleaned, at: t, into: &output)
        }
        return Result(microphone: Array(output[hop..<(hop + count)]), copy: copy, rest: rest, noise: noise, talking: talking)
    }

    private static func powers(_ heard: Spectrum, _ predicted: Spectrum) -> (copy: Double, rest: Double) {
        var copy = 0.0, rest = 0.0
        for bin in speech {
            copy += Double(predicted.re[bin] * predicted.re[bin] + predicted.im[bin] * predicted.im[bin])
            let re = heard.re[bin] - predicted.re[bin], im = heard.im[bin] - predicted.im[bin]
            rest += Double(re * re + im * im)
        }
        return (copy, rest)
    }

    /// Half a frame of spectrum, packed as vDSP packs it: bin 0's real part is the DC term and its imaginary part the
    /// Nyquist term, neither of which is touched.
    fileprivate struct Spectrum {
        var re: [Float]
        var im: [Float]
    }

    /// Short-time spectra of 32 ms frames every 16 ms, with a square-root Hann window both ways, which puts a frame back
    /// together exactly when nothing changed it.
    fileprivate struct STFT {
        let fft: vDSP.FFT<DSPSplitComplex>
        let window: [Float]

        init?() {
            guard let fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
            self.fft = fft
            window = (0..<frame).map { sqrt(0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(frame))) }
        }

        func spectrum(of x: [Float], at t: Int) -> Spectrum {
            var block = vDSP.multiply(window, x[(t * hop)..<(t * hop + frame)])
            var spectrum = Spectrum(re: [Float](repeating: 0, count: frame / 2), im: [Float](repeating: 0, count: frame / 2))
            spectrum.re.withUnsafeMutableBufferPointer { re in
                spectrum.im.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    block.withUnsafeMutableBufferPointer { p in
                        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frame / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(frame / 2)) }
                    }
                    fft.forward(input: split, output: &split)
                }
            }
            return spectrum
        }

        func power(of x: [Float], at t: Int) -> Double {
            let s = spectrum(of: x, at: t)
            return speech.reduce(0) { $0 + Double(s.re[$1] * s.re[$1] + s.im[$1] * s.im[$1]) }
        }

        /// Overlap-adds frame `t` back into `output`.
        func add(_ spectrum: Spectrum, at t: Int, into output: inout [Float]) {
            var spectrum = spectrum
            var block = [Float](repeating: 0, count: frame)
            spectrum.re.withUnsafeMutableBufferPointer { re in
                spectrum.im.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    fft.inverse(input: split, output: &split)
                    block.withUnsafeMutableBufferPointer { p in
                        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frame / 2) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(frame / 2)) }
                    }
                }
            }
            // vDSP's real FFT there and back scales by twice the frame.
            let scale = 1 / Float(2 * frame)
            for i in 0..<frame { output[t * hop + i] += block[i] * window[i] * scale }
        }
    }

    /// For each frequency, the copy as the system audio's last `taps` frames, each through a complex gain of its own.
    fileprivate struct EchoPath {
        let gains: [[Complex]]

        init(fittedTo microphone: [Float], from system: [Float], frames: Int, stft: STFT, included: (Int) -> Bool) {
            var normal = [[ComplexD]](repeating: [ComplexD](repeating: .zero, count: taps * taps), count: frame / 2)
            var target = [[ComplexD]](repeating: [ComplexD](repeating: .zero, count: taps), count: frame / 2)
            var history = History()
            for t in 0..<frames {
                history.add(stft.spectrum(of: system, at: t))
                guard included(t) else { continue }
                let heard = stft.spectrum(of: microphone, at: t)
                for bin in modelled {
                    let m = ComplexD(re: Double(heard.re[bin]), im: Double(heard.im[bin]))
                    for i in 0..<taps {
                        let xi = history.value(back: i, at: bin).conjugate
                        target[bin][i] = target[bin][i] + xi * m
                        for j in i..<taps { normal[bin][i * taps + j] = normal[bin][i * taps + j] + xi * history.value(back: j, at: bin) }
                    }
                }
            }
            gains = (0..<(frame / 2)).map { bin in
                guard modelled.contains(bin) else { return [Complex](repeating: Complex(re: 0, im: 0), count: taps) }
                var a = (0..<taps).map { i in (0..<taps).map { j in j >= i ? normal[bin][i * taps + j] : normal[bin][j * taps + i].conjugate } }
                let ridge = (0..<taps).reduce(0) { $0 + a[$1][$1].re } / Double(taps) * 1e-3 + 1e-12
                for i in 0..<taps { a[i][i] = a[i][i] + ComplexD(re: ridge, im: 0) }
                return ComplexD.solve(a, target[bin]).map { Complex(re: Float($0.re), im: Float($0.im)) }
            }
        }

        /// Each frame's spectrum and its predicted copy, in order.
        func run(on microphone: [Float], from system: [Float], frames: Int, stft: STFT, _ body: (Int, Spectrum, Spectrum) -> Void) {
            var history = History()
            for t in 0..<frames {
                history.add(stft.spectrum(of: system, at: t))
                let heard = stft.spectrum(of: microphone, at: t)
                var predicted = Spectrum(re: [Float](repeating: 0, count: frame / 2), im: [Float](repeating: 0, count: frame / 2))
                for bin in modelled {
                    var re: Float = 0, im: Float = 0
                    for k in 0..<taps {
                        let g = gains[bin][k], x = history.value(back: k, at: bin)
                        re += Float(g.re * Float(x.re) - g.im * Float(x.im))
                        im += Float(g.re * Float(x.im) + g.im * Float(x.re))
                    }
                    predicted.re[bin] = re
                    predicted.im[bin] = im
                }
                body(t, heard, predicted)
            }
        }
    }

    /// The system audio's last `taps` spectra, newest first; silence before the first frame.
    fileprivate struct History {
        private var values: [Spectrum] = []
        private var newest = -1

        mutating func add(_ spectrum: Spectrum) {
            newest += 1
            if values.count < taps { values.append(spectrum) } else { values[newest % taps] = spectrum }
        }

        func value(back: Int, at bin: Int) -> ComplexD {
            guard newest - back >= 0 else { return .zero }
            let s = values[(newest - back) % taps]
            return ComplexD(re: Double(s.re[bin]), im: Double(s.im[bin]))
        }
    }

    fileprivate struct Complex {
        var re: Float
        var im: Float
        var power: Float { re * re + im * im }
    }

    fileprivate struct ComplexD {
        var re: Double
        var im: Double

        static let zero = ComplexD(re: 0, im: 0)
        static func + (a: ComplexD, b: ComplexD) -> ComplexD { ComplexD(re: a.re + b.re, im: a.im + b.im) }
        static func - (a: ComplexD, b: ComplexD) -> ComplexD { ComplexD(re: a.re - b.re, im: a.im - b.im) }
        static func * (a: ComplexD, b: ComplexD) -> ComplexD { ComplexD(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re) }
        static func / (a: ComplexD, b: ComplexD) -> ComplexD {
            let d = b.power
            return ComplexD(re: (a.re * b.re + a.im * b.im) / d, im: (a.im * b.re - a.re * b.im) / d)
        }

        var conjugate: ComplexD { ComplexD(re: re, im: -im) }
        var power: Double { re * re + im * im }

        static func solve(_ a: [[ComplexD]], _ b: [ComplexD]) -> [ComplexD] {
            var a = a, b = b
            let n = b.count
            for column in 0..<n {
                let pivot = (column..<n).max { a[$0][column].power < a[$1][column].power }!
                a.swapAt(column, pivot)
                b.swapAt(column, pivot)
                guard a[column][column].power > 0 else { continue }
                for row in (column + 1)..<n {
                    let factor = a[row][column] / a[column][column]
                    for c in column..<n { a[row][c] = a[row][c] - factor * a[column][c] }
                    b[row] = b[row] - factor * b[column]
                }
            }
            var x = [ComplexD](repeating: .zero, count: n)
            for row in stride(from: n - 1, through: 0, by: -1) where a[row][row].power > 0 {
                var sum = b[row]
                for c in (row + 1)..<n { sum = sum - a[row][c] * x[c] }
                x[row] = sum / a[row][row]
            }
            return x
        }
    }
}
