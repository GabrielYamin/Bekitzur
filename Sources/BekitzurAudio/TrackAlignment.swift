import Accelerate

/// Lines up a call's two tracks by the copy of the system audio that laptop speakers put in the microphone.
public enum TrackAlignment {
    /// Seconds to play the microphone later so its copy of the system audio lines up with the system audio; 0 when the
    /// copy already comes after it, as sound from a speaker does, and nil without a clear copy, as with headphones.
    ///
    /// Before tracks were lined up while recording, each file started at its own first sound and the microphone started
    /// second, so its copy came 9 to 212 ms before the call itself in three calls, and the other side echoed in playback.
    /// - Parameters:
    ///   - microphone: 16 kHz mono, like `system`.
    public static func microphoneDelay(microphone: [Float], system: [Float], sampleRate: Double = 16_000) -> Double? {
        copyLag(of: system, in: microphone, sampleRate: sampleRate).map { max(0, -$0) }
    }

    /// Seconds after the system audio that its copy is heard in the microphone, negative when it's heard first: the peak of
    /// their cross-correlation in the speech band over the system audio's loudest stretches, if it's clearly there.
    public static func copyLag(of system: [Float], in microphone: [Float], sampleRate: Double = 16_000, maximum: Double = 1) -> Double? {
        let count = min(system.count, microphone.count)
        let window = min(count, Int(10 * sampleRate)), maxLag = Int(maximum * sampleRate)
        guard window > 2 * maxLag, let correlator = Correlator(minimumSize: window + maxLag, sampleRate: sampleRate) else { return nil }

        let starts = stride(from: 0, through: count - window, by: window).map { start in
            (start, vDSP.rootMeanSquare(system[start..<start + window]))
        }
        let loudest = starts.filter { $0.1 > 0.005 }.sorted { $0.1 > $1.1 }.prefix(12)
        guard !loudest.isEmpty else { return nil }

        var sum = [Float](repeating: 0, count: 2 * maxLag + 1)
        for (start, _) in loudest {
            let r = correlator.normalized(microphone[start..<start + window], system[start..<start + window], maxLag: maxLag)
            vDSP.add(sum, r, result: &sum)
        }
        let average = vDSP.divide(sum, Float(loudest.count))
        let peak = vDSP.indexOfMaximum(vDSP.absolute(average))
        guard abs(average[Int(peak.0)]) >= 0.1 else { return nil }
        return Double(Int(peak.0) - maxLag) / sampleRate
    }
}

/// Cross-correlation through a real FFT, band-limited to speech so hum and rumble don't decide the peak.
private struct Correlator {
    let size: Int
    let fft: vDSP.FFT<DSPSplitComplex>
    /// 1 for the bins in the speech band; bin 0 holds DC and Nyquist, both outside it.
    let band: [Float]

    init?(minimumSize: Int, sampleRate: Double) {
        let log2n = vDSP_Length(ceil(log2(Double(minimumSize))))
        size = 1 << Int(log2n)
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        self.fft = fft
        let size = self.size
        band = (0..<size / 2).map { k in
            let frequency = Double(k) * sampleRate / Double(size)
            return k > 0 && (300...3_400).contains(frequency) ? 1 : 0
        }
    }

    /// The correlation of `a` with `b` for lags -maxLag...maxLag, divided by both energies; positive lags mean `a` hears
    /// it later.
    func normalized(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>, maxLag: Int) -> [Float] {
        let (ar, ai) = spectrum(a), (br, bi) = spectrum(b)
        // A times the conjugate of B, and each one's power.
        let crossReal = vDSP.add(vDSP.multiply(ar, br), vDSP.multiply(ai, bi))
        let crossImag = vDSP.subtract(vDSP.multiply(ai, br), vDSP.multiply(ar, bi))
        let zeros = [Float](repeating: 0, count: size / 2)
        let cross = inverse(real: crossReal, imag: crossImag)
        let energyA = inverse(real: vDSP.add(vDSP.square(ar), vDSP.square(ai)), imag: zeros)[0]
        let energyB = inverse(real: vDSP.add(vDSP.square(br), vDSP.square(bi)), imag: zeros)[0]
        let scale = 1 / max((energyA * energyB).squareRoot(), .leastNormalMagnitude)
        // Lag k sits at index k, and lag -k at size - k.
        return (-maxLag...maxLag).map { lag in cross[lag >= 0 ? lag : size + lag] * scale }
    }

    private func spectrum(_ x: ArraySlice<Float>) -> (real: [Float], imag: [Float]) {
        var padded = [Float](repeating: 0, count: size)
        padded.replaceSubrange(0..<x.count, with: x)
        var real = [Float](repeating: 0, count: size / 2), imag = [Float](repeating: 0, count: size / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                padded.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2)) }
                }
                fft.forward(input: split, output: &split)
            }
        }
        return (vDSP.multiply(real, band), vDSP.multiply(imag, band))
    }

    private func inverse(real: [Float], imag: [Float]) -> [Float] {
        var real = real, imag = imag
        var output = [Float](repeating: 0, count: size)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                fft.inverse(input: split, output: &split)
                output.withUnsafeMutableBufferPointer { o in
                    o.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(size / 2)) }
                }
            }
        }
        return output
    }
}
