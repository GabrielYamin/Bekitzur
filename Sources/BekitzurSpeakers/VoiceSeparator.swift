import CoreML
import Foundation

public enum VoiceSeparatorError: Error, CustomStringConvertible, LocalizedError {
    case noVoices

    public var description: String {
        switch self {
        case .noVoices: "The voice separation model returned no voices"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noVoices: String(localized: "The voice separation model returned no voices")
        }
    }
}

/// Splits audio where two people talk at once into one track per voice, with Alibaba's MossFormer2 (ClearerVoice-Studio)
/// converted to Core ML. The model takes 2.05 seconds at a time, so longer audio goes in windows that share half a second
/// with the one before; each window keeps its middle, and its voices are put in the order of the window before by
/// comparing the half second they share, since the model can give either voice first.
public final class VoiceSeparator {
    /// The 16 kHz samples the model takes at once: 4,096 encoder steps, whole attention groups of 256.
    public static let window = 32_776
    static let stride = window * 3 / 4

    private let model: MLModel

    /// Loads the model, compiling the package into `compiled` the first time and after the package changes.
    public init(package: URL, compiled: URL) async throws {
        let manifest = package.appending(path: "Manifest.json")
        let packageDate = (try? manifest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let compiledDate = (try? compiled.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if compiledDate.map({ $0 < packageDate }) ?? true {
            let fresh = try await MLModel.compileModel(at: package)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: fresh, to: compiled)
        }
        let configuration = MLModelConfiguration()
        // The Neural Engine can't compile it, and its CPU backend crashed in testing.
        configuration.computeUnits = .cpuAndGPU
        model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
    }

    /// The two voices in 16 kHz mono `samples`, each as long and as loud as `samples`. Which comes first means nothing.
    public func separate(_ samples: [Float]) throws -> [[Float]] {
        try Self.separate(samples) { try run($0) }
    }

    private func run(_ window: [Float]) throws -> [[Float]] {
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.window)], dataType: .float32)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for i in 0..<Self.window { buffer[i] = window[i] }
        }
        let output = try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["audio": input]))
        guard let voices = output.featureValue(for: "voices")?.multiArrayValue, voices.shape.count == 3, voices.shape[1].intValue == 2 else {
            throw VoiceSeparatorError.noVoices
        }
        let voiceStride = voices.strides[1].intValue, sampleStride = voices.strides[2].intValue
        if voices.dataType == .float32 {
            return voices.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                (0..<2).map { voice in (0..<Self.window).map { buffer[voice * voiceStride + $0 * sampleStride] } }
            }
        }
        return (0..<2).map { voice in
            (0..<Self.window).map { voices[voice * voiceStride + $0 * sampleStride].floatValue }
        }
    }

    /// The windows, their voices' order, and joining them, around `run`, which separates one window into two voices.
    static func separate(_ samples: [Float], window: Int = window, stride: Int = stride, run: ([Float]) throws -> [[Float]]) rethrows -> [[Float]] {
        guard !samples.isEmpty else { return [[], []] }
        let steps = max(0, Int((Double(samples.count - window) / Double(stride)).rounded(.up)))
        let padded = samples + [Float](repeating: 0, count: window + steps * stride - samples.count)
        let shared = window - stride
        var voices = [[Float]](repeating: [Float](repeating: 0, count: padded.count), count: 2)
        var previous: [[Float]]?
        for step in 0...steps {
            let at = step * stride
            var pair = try run(Array(padded[at..<at + window]))
            if let previous {
                let before = previous.map { Array($0[(window - shared)...]) }, now = pair.map { Array($0[..<shared]) }
                if correlation(before[0], now[1]) + correlation(before[1], now[0]) > correlation(before[0], now[0]) + correlation(before[1], now[1]) {
                    pair.swapAt(0, 1)
                }
            }
            let first = step == 0 ? 0 : shared / 2
            let last = step == steps ? window : window - shared / 2
            for voice in 0..<2 {
                voices[voice].replaceSubrange(at + first..<at + last, with: pair[voice][first..<last])
            }
            previous = pair
        }
        let loudness = rms(samples)
        return voices.map { voice in
            let trimmed = Array(voice[..<samples.count])
            let level = rms(trimmed)
            return level > 0 ? trimmed.map { $0 / level * loudness } : trimmed
        }
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let meanA = a.reduce(0, +) / Float(a.count), meanB = b.reduce(0, +) / Float(b.count)
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in a.indices {
            let x = a[i] - meanA, y = b[i] - meanB
            dot += x * y
            normA += x * x
            normB += y * y
        }
        return normA > 0 && normB > 0 ? dot / (normA * normB).squareRoot() : 0
    }

    private static func rms(_ samples: [Float]) -> Float {
        samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}
