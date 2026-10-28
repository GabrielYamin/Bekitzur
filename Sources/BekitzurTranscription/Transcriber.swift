import BekitzurDomain
import Foundation
import whisper

public enum TranscriberError: Error, CustomStringConvertible {
    case modelNotLoaded(URL)
    case transcriptionFailed(Int32)

    public var description: String {
        switch self {
        case .modelNotLoaded(let url): "Can't load the speech model at \(url.path)"
        case .transcriptionFailed(let code): "Transcription failed (whisper.cpp error \(code))"
        }
    }
}

/// Transcribes 16 kHz mono audio with a Whisper-family model through whisper.cpp.
///
/// The settings match what the scripted read was scored with: beam search, the language forced, no text carried
/// between 30-second windows (which prevents Whisper's repetition loops), and non-speech tokens suppressed.
///
/// Word times come from DTW alignment on large-v3-turbo's attention heads, which the ivrit.ai model shares. Whisper's
/// own token times can be a second off, enough to put a quick reply in the wrong Speaker's mouth.
public final class Transcriber {
    private let context: OpaquePointer

    public init(modelURL: URL) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true
        // whisper.cpp computes no DTW times with flash attention on; without it transcription is about 15% slower.
        params.flash_attn = false
        params.dtw_token_timestamps = true
        params.dtw_aheads_preset = WHISPER_AHEADS_LARGE_V3_TURBO
        guard let context = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw TranscriberError.modelNotLoaded(modelURL)
        }
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    /// - Parameters:
    ///   - prompt: Text the model reads before every 30-second window, such as an example sentence in the wanted
    ///     style. Earlier transcription is still never carried.
    ///   - asOneSegment: For audio of 30 seconds or less: one segment, decoded in a single window. Otherwise
    ///     whisper.cpp starts a new window after the last segment, and if that window holds a segment ending within
    ///     0.15 seconds of its start, word timing aborts the process (median filter wider than the audio).
    public func transcribe(_ samples: [Float], language: ConversationLanguage, prompt: String? = nil, asOneSegment: Bool = false) throws -> [TranscriptSegment] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 5
        params.greedy.best_of = 5
        params.n_max_text_ctx = 0
        params.suppress_nst = true
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.single_segment = asOneSegment
        if let prompt {
            // A carried prompt goes first in each window and earlier text fills the rest of this budget, so a budget of
            // the prompt plus the start-of-context token leaves no room for earlier text.
            params.carry_initial_prompt = true
            params.n_max_text_ctx = -whisper_tokenize(context, prompt, nil, 0) + 1
        }

        let status = language.rawValue.withCString { code in
            params.language = code
            return (prompt ?? "").withCString { promptText in
                if prompt != nil { params.initial_prompt = promptText }
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        guard status == 0 else { throw TranscriberError.transcriptionFailed(status) }

        return (0..<whisper_full_n_segments(context)).compactMap { i in
            let text = Self.clean(String(cString: whisper_full_get_segment_text(context, i)))
            guard !text.isEmpty else { return nil }
            // whisper.cpp times are in hundredths of a second.
            return TranscriptSegment(
                start: Double(whisper_full_get_segment_t0(context, i)) / 100,
                end: Double(whisper_full_get_segment_t1(context, i)) / 100,
                text: text,
                words: words(inSegment: i)
            )
        }
    }

    /// A token that starts with a space starts a new word. Tokens are byte pieces that can split a Hebrew letter, so a
    /// word's bytes are decoded only once the word is complete.
    private func words(inSegment segment: Int32) -> [TranscriptWord] {
        let endOfText = whisper_token_eot(context)
        var words: [TranscriptWord] = []
        var bytes: [UInt8] = []
        var start = 0.0, end = 0.0

        func finishWord() {
            let text = Self.clean(String(decoding: bytes, as: UTF8.self))
            if !text.isEmpty { words.append(TranscriptWord(start: start, end: end, text: text)) }
            bytes = []
        }

        for token in 0..<whisper_full_n_tokens(context, segment) {
            let data = whisper_full_get_token_data(context, segment, token)
            guard data.id < endOfText, let piece = whisper_full_get_token_text(context, segment, token) else { continue }
            let pieceBytes = Array(UnsafeRawBufferPointer(start: piece, count: strlen(piece)))
            if pieceBytes.first == UInt8(ascii: " "), !bytes.isEmpty { finishWord() }
            let time = Double(data.t_dtw >= 0 ? data.t_dtw : data.t0) / 100
            if bytes.isEmpty { start = time }
            end = time
            bytes += pieceBytes
        }
        if !bytes.isEmpty { finishWord() }
        return words
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202B}", with: "")
            .replacingOccurrences(of: "\u{202C}", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
