import Foundation

/// A model file Bekitzur reads, pinned to one revision of a repository on Hugging Face.
public struct ModelFile: Sendable, Equatable, Identifiable {
    /// What the app calls it, like "Hebrew speech model"; the files of a model made of several share it.
    public let name: String
    /// Where it goes, relative to the models folder.
    public let path: String
    public let url: URL
    /// The file's SHA-256 at that revision, which Hugging Face publishes as the Git LFS hash for large files.
    public let sha256: String
    public let bytes: Int64
    /// Files this one replaces, relative to the models folder. Until it's downloaded the app reads the first of them
    /// that's there; once it's in, they're deleted.
    public let replaces: [String]
    /// Whether Conversations wait for it to be processed; without an optional model, processing skips what it's for.
    public let required: Bool

    public var id: String { path }

    public init(name: String, path: String, url: URL, sha256: String, bytes: Int64, replaces: [String] = [], required: Bool = true) {
        self.name = name
        self.path = path
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
        self.replaces = replaces
        self.required = required
    }
}

/// A model as the app shows it: the files that share a name.
public struct ModelGroup: Sendable, Identifiable {
    public let name: String
    public let files: [ModelFile]

    public var id: String { name }
    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
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

    /// Where the voice separation model's Core ML package goes, relative to the models folder.
    public static let voiceSeparationPackage = "mossformer2-ss-16k-coreml/MossFormer2_SS_16K.mlpackage"

    /// Alibaba's MossFormer2 (ClearerVoice-Studio), converted to Core ML: a package of three files, which separates two
    /// people talking at once. Optional: Conversations are processed without it, only not separated.
    public static let voiceSeparation = [
        ("Manifest.json", "cc4e38523902de698c8bea7dc9142ff00e0cff0d8541da1bd27c1a432c668565", Int64(617)),
        ("Data/com.apple.CoreML/model.mlmodel", "f0e936c3119f36f759f132c7270857b29e7d5f7810d94a00ccdf1977b435d185", Int64(1_693_600)),
        ("Data/com.apple.CoreML/weights/weight.bin", "d5cbff35650793d91e880bd43074aea6ad1c5b48781d057244a0039c56249cc2", Int64(116_277_056)),
    ].map { file, sha256, bytes in
        ModelFile(
            name: "Voice separation model",
            path: "\(voiceSeparationPackage)/\(file)",
            url: URL(string: "https://huggingface.co/Moipee/MossFormer2-SS-16K-CoreML/resolve/b937109e10cb0af3aac8577b6fa4c4c615a42e48/MossFormer2_SS_16K.mlpackage/\(file)")!,
            sha256: sha256,
            bytes: bytes,
            required: false
        )
    }

    /// Every model the app reads, in the order they download: the speech models first, so recordings are transcribed
    /// live sooner.
    public static let all = [hebrewSpeech, englishSpeech, languageModel] + voiceSeparation

    /// The models Conversations wait for.
    public static let required = all.filter(\.required)

    /// The models as the app shows them, each once, in the order they download.
    public static let groups = groups(of: all)

    public static func groups(of files: [ModelFile]) -> [ModelGroup] {
        var names: [String] = []
        for file in files where !names.contains(file.name) { names.append(file.name) }
        return names.map { name in ModelGroup(name: name, files: files.filter { $0.name == name }) }
    }
}
