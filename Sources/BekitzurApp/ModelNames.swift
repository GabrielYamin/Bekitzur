import BekitzurModels

/// A model's name as the app shows it, in the app's language: as Settings lists it, and as a sentence says it. A
/// model's own `name` stays English, for the log.
enum ModelNames {
    static func title(_ name: String) -> String {
        switch name {
        case ModelFile.hebrewSpeech.name: String(localized: "Hebrew speech model")
        case ModelFile.englishSpeech.name: String(localized: "English speech model")
        case ModelFile.languageModel.name: String(localized: "Language model")
        case ModelFile.voiceSeparation[0].name: String(localized: "Voice separation model")
        default: name
        }
    }

    /// "the Hebrew speech model", as in "Downloading the Hebrew speech model".
    static func inSentence(_ name: String) -> String {
        switch name {
        case ModelFile.hebrewSpeech.name: String(localized: "the Hebrew speech model")
        case ModelFile.englishSpeech.name: String(localized: "the English speech model")
        case ModelFile.languageModel.name: String(localized: "the language model")
        case ModelFile.voiceSeparation[0].name: String(localized: "the voice separation model")
        default: name
        }
    }
}
