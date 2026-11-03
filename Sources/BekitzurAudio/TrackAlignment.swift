import Accelerate
import BekitzurDomain

/// Lines up a call's two tracks by the copy of the system audio that laptop speakers put in the microphone.
public enum TrackAlignment {
    /// How much later to play the system audio along the call so the other side lines up with the microphone's copy:
    /// found every 4 seconds over 8 while the other side talks, then every second over 2 near that, with a new delay
    /// wherever it moves by more than 3 ms, in the quietest moment around. Empty without a clear copy, as with headphones.
    ///
    /// The copy comes after the system audio by however long the speakers take to play it, and a recording that lost
    /// audio on the way drifts. Eight-second windows alone would place a change seconds away from the loss, so the
    /// 2-second pass finds where it is.
    /// - Parameters:
    ///   - microphone: 16 kHz mono, like `system`.
    public static func systemAudioDelays(microphone: [Float], system: [Float], sampleRate: Double = 16_000) -> [TrackDelay] {
        let coarse = lags(of: system, in: microphone, window: 8, hop: 4, searching: 1, sampleRate: sampleRate) { _ in 0 }
        // Too little of the other side to follow along: one delay for the whole call, from its loudest stretches together.
        guard coarse.count >= 3 else {
            return copyLag(of: system, in: microphone, sampleRate: sampleRate).map { [TrackDelay(from: 0, delay: $0)] } ?? []
        }
        let near = smoothed(coarse, radius: 1)
        let fine = lags(of: system, in: microphone, window: 2, hop: 1, searching: 0.04, sampleRate: sampleRate) { time in
            near.min { abs($0.time - time) < abs($1.time - time) }?.lag ?? 0
        }
        // A stray peak or two isn't a change. Within a few ms, a room's reflections take turns being the strongest path,
        // so smaller moves stay one delay.
        let measured = fine.count >= 3 ? smoothed(fine, radius: 2) : near
        let tolerance = 0.003
        var runs: [(first: Int, lags: [Double])] = []
        for (i, lag) in measured.map(\.lag).enumerated() {
            if let run = runs.last, abs(lag - median(run.lags)) <= tolerance {
                runs[runs.count - 1].lags.append(lag)
            } else {
                runs.append((i, [lag]))
            }
        }
        return runs.enumerated().map { index, run in
            let from = index == 0 ? 0 : quietest(system, between: measured[run.first - 1].time, and: measured[run.first].time, sampleRate: sampleRate)
            return TrackDelay(from: Double(from) / sampleRate, delay: (median(run.lags) * sampleRate).rounded() / sampleRate)
        }
    }

    /// The copy's lag behind the system audio, in windows of `window` seconds every `hop` where the other side talks and
    /// the copy is clear, searched `searching` seconds either way of where `around` says it is, by the window's middle.
    private static func lags(
        of system: [Float],
        in microphone: [Float],
        window seconds: Double,
        hop: Double,
        searching: Double,
        sampleRate: Double,
        around: (Int) -> Double
    ) -> [(time: Int, lag: Double)] {
        let count = min(system.count, microphone.count)
        let window = Int(seconds * sampleRate), maxLag = Int(searching * sampleRate)
        guard count >= window, let correlator = Correlator(minimumSize: window + maxLag, sampleRate: sampleRate) else { return [] }
        var measured: [(time: Int, lag: Double)] = []
        for start in stride(from: 0, through: count - window, by: Int(hop * sampleRate)) where vDSP.rootMeanSquare(system[start..<start + window]) > 0.005 {
            let shift = Int((around(start + window / 2) * sampleRate).rounded())
            guard start + shift >= 0, start + shift + window <= microphone.count else { continue }
            let r = correlator.normalized(microphone[(start + shift)..<(start + shift + window)], system[start..<start + window], maxLag: maxLag)
            let peak = vDSP.indexOfMaximum(vDSP.absolute(r))
            guard abs(r[Int(peak.0)]) >= 0.1 else { continue }
            measured.append((start + window / 2, Double(shift + Int(peak.0) - maxLag) / sampleRate))
        }
        return measured
    }

    /// Each lag as the median of those within `radius` windows of it.
    private static func smoothed(_ measured: [(time: Int, lag: Double)], radius: Int) -> [(time: Int, lag: Double)] {
        measured.indices.map { i in (measured[i].time, median(measured[max(0, i - radius)...min(measured.count - 1, i + radius)].map(\.lag))) }
    }

    /// The system audio as `delays` place it, for mixing with the microphone.
    public static func placing(_ system: [Float], by delays: [TrackDelay], sampleRate: Double = 16_000) -> [Float] {
        guard !delays.isEmpty else { return system }
        let pieces = TrackDelay.pieces(delays, duration: Double(system.count) / sampleRate)
        let sample = { (seconds: Double) in Int((seconds * sampleRate).rounded()) }
        var placed = [Float](repeating: 0, count: pieces.last.map { sample($0.at) + sample($0.source.upperBound) - sample($0.source.lowerBound) } ?? 0)
        for piece in pieces {
            let from = sample(piece.source.lowerBound), at = sample(piece.at)
            let count = min(sample(piece.source.upperBound), system.count) - from
            guard count > 0, at + count <= placed.count else { continue }
            placed.replaceSubrange(at..<at + count, with: system[from..<from + count])
        }
        return placed
    }

    /// Where the system audio is quietest between two sample positions, a fifth of a second at a time, so a change of
    /// delay falls in a pause.
    private static func quietest(_ system: [Float], between start: Int, and end: Int, sampleRate: Double) -> Int {
        let frame = Int(sampleRate / 5)
        guard end - start > frame else { return (start + end) / 2 }
        let frames = stride(from: start, through: end - frame, by: frame / 2)
        let quiet = frames.min { vDSP.rootMeanSquare(system[$0..<$0 + frame]) < vDSP.rootMeanSquare(system[$1..<$1 + frame]) } ?? start
        return quiet + frame / 2
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// Seconds to play the microphone later so its copy of the system audio lines up with the system audio; 0 when the
    /// copy already comes after it, as sound from a speaker does, and nil without a clear copy, as with headphones.
    ///
    /// In a recording whose files each start at their own first sound, the microphone, started second, runs ahead, so
    /// its copy comes before the call itself and the other side echoes in playback.
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
