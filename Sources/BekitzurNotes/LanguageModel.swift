import Foundation
import llama

public enum LanguageModelError: Error, CustomStringConvertible {
    case modelNotLoaded(URL)
    case contextNotCreated
    case invalidGrammar
    case promptTooLong(tokens: Int, limit: Int)
    case decodeFailed(Int32)

    public var description: String {
        switch self {
        case .modelNotLoaded(let url): "Can't load the language model at \(url.path)"
        case .contextNotCreated: "Can't create a language model context"
        case .invalidGrammar: "The output grammar doesn't parse"
        case .promptTooLong(let tokens, let limit): "The prompt is \(tokens) tokens, over the \(limit)-token limit"
        case .decodeFailed(let code): "The language model failed (llama.cpp error \(code))"
        }
    }
}

public struct Completion: Sendable {
    public let text: String
    public let promptTokens: Int
    public let outputTokens: Int
    public let seconds: Double
}

/// Runs a GGUF language model through llama.cpp, fully on the GPU, with greedy decoding.
public final class LanguageModel {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    public let contextSize: Int
    /// Tokens in the context: the chat so far.
    private var held = 0
    private static let backend: Void = llama_backend_init()

    public init(modelURL: URL, contextSize: Int = 32_768) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(modelURL.path, modelParams) else {
            throw LanguageModelError.modelNotLoaded(modelURL)
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_batch = 2048
        contextParams.n_ubatch = 512
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        // The sliding-window layers keep only their window, which works as long as the context is only appended to or
        // cleared, never rewound.
        contextParams.swa_full = false
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LanguageModelError.contextNotCreated
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.contextSize = contextSize
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// A system and user message in Gemma 4's chat format, with thinking switched off by the empty thought channel.
    static func gemma4Prompt(system: String, user: String) -> String {
        let system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<|turn>system\n\(system)<turn|>\n<|turn>user\n\(user)<turn|>\n<|turn>model\n<|channel>thought\n<channel|>"
    }

    /// Generates a reply, constrained to the GBNF grammar when one is given.
    public func complete(system: String, user: String, grammar: String?, maxTokens: Int) throws -> Completion {
        try startChat(system: system, user: user, grammar: grammar, maxTokens: maxTokens)
    }

    /// Starts a chat with a system and a user message, and replies; the context keeps all of it for `continueChat`.
    public func startChat(system: String, user: String, grammar: String?, maxTokens: Int) throws -> Completion {
        llama_memory_clear(llama_get_memory(context), true)
        held = 0
        return try reply(to: tokenize(Self.gemma4Prompt(system: system, user: user), addingStart: true), grammar: grammar, maxTokens: maxTokens)
    }

    /// Adds a user message to the chat and replies. Only the new message is read: everything before it is still in the
    /// context, which matters when that's an hour of transcript. Throws `promptTooLong` once the context is full.
    public func continueChat(user: String, grammar: String?, maxTokens: Int) throws -> Completion {
        // The last reply ended at its end-of-turn token, which was never decoded.
        let message = "<turn|>\n<|turn>user\n\(user.trimmingCharacters(in: .whitespacesAndNewlines))<turn|>\n<|turn>model\n<|channel>thought\n<channel|>"
        return try reply(to: tokenize(message, addingStart: false), grammar: grammar, maxTokens: maxTokens)
    }

    private func reply(to prompt: [llama_token], grammar: String?, maxTokens: Int) throws -> Completion {
        let started = Date()
        var tokens = prompt
        guard held + tokens.count + maxTokens <= contextSize else {
            throw LanguageModelError.promptTooLong(tokens: held + tokens.count, limit: contextSize - maxTokens)
        }

        var position = 0
        while position < tokens.count {
            let count = min(2048, tokens.count - position)
            let status = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + position, Int32(count)))
            }
            guard status == 0 else { throw LanguageModelError.decodeFailed(status) }
            position += count
            held += count
        }

        var grammarSampler: UnsafeMutablePointer<llama_sampler>?
        if let grammar {
            guard let sampler = llama_sampler_init_grammar(vocab, grammar, "root") else { throw LanguageModelError.invalidGrammar }
            grammarSampler = sampler
        }
        defer { if let grammarSampler { llama_sampler_free(grammarSampler) } }
        let vocabularySize = Int(llama_vocab_n_tokens(vocab))
        var allTokens: [llama_token_data] = []

        var bytes: [UInt8] = []
        var produced = 0
        while produced < maxTokens {
            guard let logits = llama_get_logits_ith(context, -1) else { throw LanguageModelError.decodeFailed(-1) }
            var token = Self.mostLikely(logits, count: vocabularySize)
            // Greedy decoding: if the likeliest token fits the grammar, masking the others can't change the choice.
            // Checking only that token instead of the whole vocabulary at every step roughly halves generation time.
            if let grammarSampler {
                var single = llama_token_data(id: token, logit: logits[Int(token)], p: 0)
                let fits = withUnsafeMutablePointer(to: &single) { pointer in
                    var candidates = llama_token_data_array(data: pointer, size: 1, selected: -1, sorted: false)
                    llama_sampler_apply(grammarSampler, &candidates)
                    return candidates.data[0].logit.isFinite
                }
                if !fits {
                    if allTokens.isEmpty { allTokens = Array(repeating: llama_token_data(id: 0, logit: 0, p: 0), count: vocabularySize) }
                    for i in 0..<vocabularySize { allTokens[i] = llama_token_data(id: llama_token(i), logit: logits[i], p: 0) }
                    token = allTokens.withUnsafeMutableBufferPointer { buffer in
                        var candidates = llama_token_data_array(data: buffer.baseAddress, size: vocabularySize, selected: -1, sorted: false)
                        llama_sampler_apply(grammarSampler, &candidates)
                        var best = 0
                        for i in 1..<candidates.size where candidates.data[i].logit > candidates.data[best].logit { best = i }
                        return candidates.data[best].id
                    }
                }
                llama_sampler_accept(grammarSampler, token)
            }
            if llama_vocab_is_eog(vocab, token) { break }
            bytes += piece(token)
            produced += 1
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { throw LanguageModelError.decodeFailed(status) }
            held += 1
        }
        return Completion(
            text: String(decoding: bytes, as: UTF8.self),
            promptTokens: tokens.count,
            outputTokens: produced,
            seconds: Date().timeIntervalSince(started)
        )
    }

    private static func mostLikely(_ logits: UnsafeMutablePointer<Float>, count: Int) -> llama_token {
        var best = 0
        for i in 1..<count where logits[i] > logits[best] { best = i }
        return llama_token(best)
    }

    /// - Parameter addingStart: Prepends the start-of-text token, which only the start of a chat has.
    private func tokenize(_ text: String, addingStart: Bool) -> [llama_token] {
        let length = Int32(text.utf8.count)
        let needed = -llama_tokenize(vocab, text, length, nil, 0, addingStart, true)
        var tokens = [llama_token](repeating: 0, count: Int(max(needed, 0)))
        let count = llama_tokenize(vocab, text, length, &tokens, needed, addingStart, true)
        return Array(tokens.prefix(Int(max(count, 0))))
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(count, 0))).map { UInt8(bitPattern: $0) }
    }
}
