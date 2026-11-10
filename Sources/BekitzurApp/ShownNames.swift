import BekitzurDomain
import BekitzurPipeline

/// Names the app saves or hands to the language model in English, as the app shows them, in its language.
enum ShownNames {
    /// A processing step, saved in English with the Conversation while it's processed.
    static func step(_ step: String?) -> String {
        guard let step else { return String(localized: "Processing") }
        return switch step {
        case "Waiting": String(localized: "Waiting")
        case "Starting": String(localized: "Starting")
        case "Waiting for the models": String(localized: "Waiting for the models")
        case "Finishing the live Transcript": String(localized: "Finishing the live Transcript")
        case ProcessingStep.transcribing.rawValue: String(localized: "Transcribing")
        case ProcessingStep.recognizingSpeakers.rawValue: String(localized: "Recognizing speakers")
        case ProcessingStep.separatingVoices.rawValue: String(localized: "Separating people who talk at once")
        case ProcessingStep.checkingTerms.rawValue: String(localized: "Checking English terms")
        case ProcessingStep.writingNotes.rawValue: String(localized: "Writing Notes")
        default: step
        }
    }

    /// A Conversation's language, whose English name the language model reads.
    static func language(_ language: ConversationLanguage) -> String {
        switch language {
        case .hebrew: String(localized: "Hebrew")
        case .english: String(localized: "English")
        }
    }

    /// A Speaker's name, or the label of one without a name, which is saved in English: "Speaker 2".
    static func speaker(_ name: String) -> String {
        if name == "Speaker" { return String(localized: "Speaker") }
        guard name.hasPrefix("Speaker "), let number = Int(name.dropFirst("Speaker ".count)) else { return name }
        return String(localized: "Speaker \(number)")
    }
}
