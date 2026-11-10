/// The label of a Speaker without a name, saved in English, "Speaker 2", whatever language the app shows it in.
public enum SpeakerLabel {
    public static func label(_ number: Int) -> String {
        "Speaker \(number)"
    }

    /// The number in a label; nil for a name.
    public static func number(in name: String) -> Int? {
        guard name.hasPrefix("Speaker ") else { return nil }
        return Int(name.dropFirst("Speaker ".count))
    }
}
