import BekitzurDomain
import Foundation
import whisper

/// Scores how well texts fit a stretch of audio, as a Whisper model hears it: the log-probability of each text's tokens
/// from the first token where the texts differ, through the end of the text. Texts that differ in one word are compared
/// on that word and on how well the rest of the sentence still fits after it.
public final class AudioScorer {
    private let context: OpaquePointer
    private let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

    public init(modelURL: URL) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let context = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw TranscriberError.modelNotLoaded(modelURL)
        }
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    /// Takes in up to 30 seconds of 16 kHz audio, for the `scores` calls that follow.
    public func listen(to samples: ArraySlice<Float>) throws {
        let clip = Array(samples.prefix(30 * 16_000))
        guard whisper_pcm_to_mel(context, clip, Int32(clip.count), threads) == 0, whisper_encode(context, 0, threads) == 0 else {
            throw TranscriberError.transcriptionFailed(-1)
        }
    }

    /// The texts' log-probabilities for the audio last listened to; minus infinity for a text too long to score.
    public func scores(of texts: [String], language: ConversationLanguage) -> [Double] {
        let start = [
            whisper_token_sot(context), whisper_token_lang(context, whisper_lang_id(language.rawValue)),
            whisper_token_transcribe(context), whisper_token_not(context),
        ]
        let sequences = texts.map { tokens(" " + $0) + [whisper_token_eot(context)] }
        guard let first = sequences.first else { return [] }
        let shared = sequences.dropFirst().reduce(first.count - 1) { length, sequence in
            zip(first.prefix(length), sequence).prefix { $0 == $1 }.count
        }
        let prefix = start + first.prefix(shared)
        // The model's text context holds 448 tokens.
        guard sequences.allSatisfy({ start.count + $0.count < 440 }), decode(Array(prefix.dropLast()), past: 0) else {
            return texts.map { _ in -.infinity }
        }
        return sequences.map { sequence in
            var past = prefix.count - 1
            var last = prefix[past]
            var total = 0.0
            for next in sequence.dropFirst(shared) {
                guard decode([last], past: past) else { return -.infinity }
                total += logProbability(of: next)
                last = next
                past += 1
            }
            return total
        }
    }

    private func tokens(_ text: String) -> [whisper_token] {
        let count = -whisper_tokenize(context, text, nil, 0)
        var tokens = [whisper_token](repeating: 0, count: Int(max(count, 0)))
        let written = whisper_tokenize(context, text, &tokens, count)
        return Array(tokens.prefix(Int(max(written, 0))))
    }

    /// Decoding positions before `past` are kept from earlier calls; later ones are replaced.
    private func decode(_ tokens: [whisper_token], past: Int) -> Bool {
        tokens.isEmpty || whisper_decode(context, tokens, Int32(tokens.count), Int32(past), threads) == 0
    }

    /// From the logits after the last decoded token, the only row whisper_decode fills.
    private func logProbability(of token: whisper_token) -> Double {
        let count = Int(whisper_n_vocab(context))
        guard let logits = whisper_get_logits(context) else { return -.infinity }
        var maximum = -Float.infinity
        for i in 0..<count { maximum = max(maximum, logits[i]) }
        var sum = 0.0
        for i in 0..<count { sum += exp(Double(logits[i] - maximum)) }
        return Double(logits[Int(token)] - maximum) - log(sum)
    }
}
