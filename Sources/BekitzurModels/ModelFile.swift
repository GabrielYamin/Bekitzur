import Foundation

/// A model file Bekitzur reads, pinned to one revision of its publisher's repository on Hugging Face.
public struct ModelFile: Sendable, Equatable, Identifiable {
    /// What the app calls it, like "Hebrew speech model".
    public let name: String
    /// Where it goes, relative to the models folder.
    public let path: String
    public let url: URL
    /// The Git LFS hash Hugging Face publishes for that revision.
    public let sha256: String
    public let bytes: Int64
    /// Files this one replaces, relative to the models folder. Until it's downloaded the app reads the first of them
    /// that's there; once it's in, they're deleted.
    public let replaces: [String]

    public var id: String { path }

    public init(name: String, path: String, url: URL, sha256: String, bytes: Int64, replaces: [String] = []) {
        self.name = name
        self.path = path
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
        self.replaces = replaces
    }
}

extension ModelFile {
    public static let hebrewSpeech = ModelFile(
        name: "Hebrew speech model",
        path: "ivrit-ai-whisper-large-v3-turbo-ggml/ggml-model.bin",
        url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/2130c78e4a9cb4914cc4df91a1c3031407789705/ggml-model.bin")!,
        sha256: "c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1",
        bytes: 1_624_555_275
    )

    /// Regular Whisper, which also detects the language.
    public static let englishSpeech = ModelFile(
        name: "English speech model",
        path: "whisper-large-v3-turbo-ggml/ggml-large-v3-turbo.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin")!,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        bytes: 1_624_555_275
    )

    /// Google's QAT Q4_0 GGUF of Gemma 4 26B-A4B, saved under the name the app loads.
    public static let languageModel = ModelFile(
        name: "Language model",
        path: "gemma-4-26b-a4b-it-qat/model.gguf",
        url: URL(string: "https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf/resolve/d1c082be9cf3c8a514acf63b8761f4b41935842e/gemma-4-26B_q4_0-it.gguf")!,
        sha256: "3eca3b8f6d7baf218a7dd6bba5fb59a56ee25fe2d567b6f5f589b4f697eca51d",
        bytes: 14_439_363_584
    )

    /// Every model the app needs, in the order they download: the speech models first, so recordings are transcribed
    /// live sooner.
    public static let all = [hebrewSpeech, englishSpeech, languageModel]
}
