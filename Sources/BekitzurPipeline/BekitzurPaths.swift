import BekitzurDomain
import BekitzurModels
import Foundation

public enum BekitzurPaths {
    public static let appSupport = URL.applicationSupportDirectory.appending(path: "Bekitzur")
    public static let models = appSupport.appending(path: "Models")
    public static let conversations = appSupport.appending(path: "Conversations")
    public static let voiceprints = appSupport.appending(path: "voiceprints.json")
    public static let vocabulary = appSupport.appending(path: "vocabulary.json")
    public static let modelStore = ModelStore(folder: models)

    public static var languageModel: URL { model(.languageModel) }

    /// The voice separation model's Core ML package, and where its compiled form is kept; nil until it's downloaded.
    public static var voiceSeparation: (package: URL, compiled: URL)? {
        guard modelStore.usable(ModelFile.voiceSeparation) else { return nil }
        let package = models.appending(path: ModelFile.voiceSeparationPackage)
        return (package, package.deletingPathExtension().appendingPathExtension("mlmodelc"))
    }

    public static func speechModel(for language: ConversationLanguage) -> URL {
        switch language {
        case .hebrew: model(.hebrewSpeech)
        case .english: model(.englishSpeech)
        }
    }

    /// The file the app reads a model from, or where it goes when there's none yet.
    static func model(_ file: ModelFile) -> URL {
        modelStore.installed(file) ?? modelStore.url(of: file)
    }
}
