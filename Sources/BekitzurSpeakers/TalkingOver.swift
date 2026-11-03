import Accelerate

/// Where the user talks over the other side of a call on laptop speakers, which the microphone's copy of the other side
/// hides from a simple comparison: the copy is nearly as loud as the system audio, and from moment to moment no single
/// gain from the system audio predicts it.
///
/// The copy is predicted from the system audio, frequency by frequency, through each frequency's echo path over the
/// last 128 ms, fitted to the call by least squares where the other side talks, then fitted again on just the moments
/// the first fit explains, since the others hold the user. A moment is the user's when what's left of the microphone is
/// 15 dB above the predicted copy and 25 dB above the room's noise, in most of the five 16 ms frames around it.
enum TalkingOver {
    private static let frame = 512, hop = 256, taps = 8
    /// 218 Hz to 4 kHz, where speech is.
    private static let bins = 7...128
    private static let copyMargin = 31.6, noiseMargin = 316.0

    /// - Parameters:
    ///   - microphone: 16 kHz mono, lined up with `system`.
    /// - Returns: Stretches in seconds, a little wider than the user's speech so words keep their edges.
    static func stretches(microphone: [Float], system: [Float], sampleRate: Double = 16_000) -> [ClosedRange<Double>] {
        let frames = (min(microphone.count, system.count) - frame) / hop + 1
        guard frames > taps, let spectra = Spectra() else { return [] }

        // Where the other side talks: the system audio's loudest frame over the last 160 ms is within 40 dB of the call's
        // loudest.
        let systemPower = (0..<frames).map { spectra.power(of: system, at: $0) }
        let microphonePower = (0..<frames).map { spectra.power(of: microphone, at: $0) }
        guard let loudest = systemPower.max(), loudest > 0 else { return [] }
        let talking = (0..<frames).map { t in systemPower[max(0, t - 9)...t].max()! > loudest * 1e-4 }
        let noise = microphonePower.sorted()[frames / 10]

        let first = EchoPath(fittedTo: microphone, from: system, frames: frames, spectra: spectra) { talking[$0] }
        var copyOnly = [Bool](repeating: false, count: frames)
        first.parts(of: microphone, from: system, frames: frames, spectra: spectra, where: { talking[$0] }) { t, copy, rest in
            copyOnly[t] = rest < 0.5 * copy
        }
        let path = EchoPath(fittedTo: microphone, from: system, frames: frames, spectra: spectra) { copyOnly[$0] }
        // Louder than the other side itself, too: where they're louder, the Transcript has their words, and the user's
        // sound over them would take those words.
        var heard = [Bool](repeating: false, count: frames)
        path.parts(of: microphone, from: system, frames: frames, spectra: spectra, where: { talking[$0] }) { t, copy, rest in
            heard[t] = rest > max(copyMargin * copy, noiseMargin * noise, systemPower[t])
        }
        let user = (0..<frames).map { t in heard[max(0, t - 2)...min(frames - 1, t + 2)].filter { $0 }.count >= 3 }

        var stretches: [ClosedRange<Double>] = []
        let pad = 0.04
        for t in 0..<frames where user[t] {
            let start = max(0, Double(t * hop) / sampleRate - pad), end = Double(t * hop + frame) / sampleRate + pad
            if let last = stretches.last, start <= last.upperBound {
                stretches[stretches.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else {
                stretches.append(start...end)
            }
        }
        return stretches
    }

    /// Short-time spectra: Hann-windowed frames of 32 ms every 16 ms.
    private struct Spectra {
        let fft: vDSP.FFT<DSPSplitComplex>
        let window: [Float]

        init?() {
            guard let fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
            self.fft = fft
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frame, isHalfWindow: false)
        }

        /// Frame `t`'s spectrum in the speech band.
        func band(of x: [Float], at t: Int) -> [Complex] {
            var block = vDSP.multiply(window, x[(t * hop)..<(t * hop + frame)])
            var re = [Float](repeating: 0, count: frame / 2), im = re
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    block.withUnsafeMutableBufferPointer { p in
                        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frame / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(frame / 2)) }
                    }
                    fft.forward(input: split, output: &split)
                }
            }
            return bins.map { Complex(re: Double(re[$0]), im: Double(im[$0])) }
        }

        func power(of x: [Float], at t: Int) -> Double {
            band(of: x, at: t).reduce(0) { $0 + $1.power }
        }
    }

    /// For each frequency, the copy as the system audio's last `taps` frames, each through a complex gain of its own.
    private struct EchoPath {
        let gains: [[Complex]]

        /// Least squares for each frequency over the frames `included` takes.
        init(fittedTo microphone: [Float], from system: [Float], frames: Int, spectra: Spectra, included: (Int) -> Bool) {
            let count = bins.count
            var normal = [[Complex]](repeating: [Complex](repeating: .zero, count: taps * taps), count: count)
            var target = [[Complex]](repeating: [Complex](repeating: .zero, count: taps), count: count)
            var history = History()
            for t in 0..<frames {
                history.add(spectra.band(of: system, at: t))
                guard included(t) else { continue }
                let heard = spectra.band(of: microphone, at: t)
                for index in 0..<count {
                    for i in 0..<taps {
                        let xi = history.value(back: i, at: index).conjugate
                        target[index][i] = target[index][i] + xi * heard[index]
                        for j in i..<taps { normal[index][i * taps + j] = normal[index][i * taps + j] + xi * history.value(back: j, at: index) }
                    }
                }
            }
            gains = (0..<count).map { index in
                var a = (0..<taps).map { i in (0..<taps).map { j in j >= i ? normal[index][i * taps + j] : normal[index][j * taps + i].conjugate } }
                let ridge = (0..<taps).reduce(0) { $0 + a[$1][$1].re } / Double(taps) * 1e-3 + 1e-12
                for i in 0..<taps { a[i][i] = a[i][i] + Complex(re: ridge, im: 0) }
                return Self.solve(a, target[index])
            }
        }

        /// The predicted copy's band power and the rest's, in each frame `included` takes.
        func parts(of microphone: [Float], from system: [Float], frames: Int, spectra: Spectra, where included: (Int) -> Bool, _ body: (Int, Double, Double) -> Void) {
            var history = History()
            for t in 0..<frames {
                history.add(spectra.band(of: system, at: t))
                guard included(t) else { continue }
                let heard = spectra.band(of: microphone, at: t)
                var copy = 0.0, rest = 0.0
                for index in heard.indices {
                    var predicted = Complex.zero
                    for k in 0..<taps { predicted = predicted + gains[index][k] * history.value(back: k, at: index) }
                    copy += predicted.power
                    rest += (heard[index] - predicted).power
                }
                body(t, copy, rest)
            }
        }

        private static func solve(_ a: [[Complex]], _ b: [Complex]) -> [Complex] {
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
            var x = [Complex](repeating: .zero, count: n)
            for row in stride(from: n - 1, through: 0, by: -1) where a[row][row].power > 0 {
                var sum = b[row]
                for c in (row + 1)..<n { sum = sum - a[row][c] * x[c] }
                x[row] = sum / a[row][row]
            }
            return x
        }
    }

    /// The system audio's last `taps` spectra, newest first; silence before the first frame.
    private struct History {
        private var values = [[Complex]](repeating: [Complex](repeating: .zero, count: bins.count), count: taps)
        private var newest = -1

        mutating func add(_ band: [Complex]) {
            newest += 1
            values[newest % taps] = band
        }

        func value(back: Int, at index: Int) -> Complex {
            newest - back >= 0 ? values[(newest - back) % taps][index] : .zero
        }
    }

    private struct Complex {
        var re: Double
        var im: Double

        static let zero = Complex(re: 0, im: 0)
        static func + (a: Complex, b: Complex) -> Complex { Complex(re: a.re + b.re, im: a.im + b.im) }
        static func - (a: Complex, b: Complex) -> Complex { Complex(re: a.re - b.re, im: a.im - b.im) }
        static func * (a: Complex, b: Complex) -> Complex { Complex(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re) }
        static func / (a: Complex, b: Complex) -> Complex {
            let d = b.power
            return Complex(re: (a.re * b.re + a.im * b.im) / d, im: (a.im * b.re - a.re * b.im) / d)
        }

        var conjugate: Complex { Complex(re: re, im: -im) }
        var power: Double { re * re + im * im }
    }
}
