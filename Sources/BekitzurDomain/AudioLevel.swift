import Foundation

/// How loud a block of sound is, from 0 for silence to 1 for speech close to the microphone, for meters that show a
/// track is heard.
public enum AudioLevel {
    /// Decibels below full scale: quieter than `quiet` is silence, and louder than `loud` is full.
    static let quiet: Float = -55
    static let loud: Float = -10

    public static func of(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels - quiet) / (loud - quiet), 0), 1)
    }
}
