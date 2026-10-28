import BekitzurDomain
import Foundation

public enum BekitzurPaths {
    public static let appSupport = URL.applicationSupportDirectory.appending(path: "Bekitzur")
    public static let models = appSupport.appending(path: "Models")
    public static let conversations = appSupport.appending(path: "Conversations")
    public static let voiceprints = appSupport.appending(path: "voiceprints.json")
    public static let vocabulary = appSupport.appending(path: "vocabulary.json")
    public static let languageModel = models.appending(path: "gemma-4-26b-a4b-it-qat/model.gguf")

    public static func speechModel(for language: ConversationLanguage) -> URL {
        switch language {
        case .hebrew: models.appending(path: "ivrit-ai-whisper-large-v3-turbo-ggml/ggml-model.bin")
        case .english: models.appending(path: "whisper-large-v3-turbo-ggml/ggml-large-v3-turbo.bin")
        }
    }
}
