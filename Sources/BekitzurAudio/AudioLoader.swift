import AVFoundation

public enum AudioLoaderError: Error, CustomStringConvertible {
    case unsupportedFormat(URL)
    case conversionFailed(URL, String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let url): "Can't read audio from \(url.path)"
        case .conversionFailed(let url, let reason): "Can't convert \(url.path): \(reason)"
        }
    }
}

/// Reads an audio file of any format AVFoundation supports into 16 kHz mono Float samples, the input every model uses.
public enum AudioLoader {
    public static let sampleRate: Double = 16_000

    public static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw AudioLoaderError.unsupportedFormat(url) }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let chunk: AVAudioFrameCount = 1 << 16
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
            throw AudioLoaderError.unsupportedFormat(url)
        }
        let ratio = sampleRate / file.processingFormat.sampleRate
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio) + 1)
        var finished = false

        while !finished {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 1024) else {
                throw AudioLoaderError.conversionFailed(url, "can't allocate buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                do {
                    try file.read(into: input, frameCount: chunk)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let conversionError { throw AudioLoaderError.conversionFailed(url, conversionError.localizedDescription) }
            if let data = output.floatChannelData, output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            finished = status == .endOfStream || status == .error
        }
        return samples
    }
}
