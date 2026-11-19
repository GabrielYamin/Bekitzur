/// How a person is told apart at a glance wherever they show: their initials, and a color that's the same for the same
/// name in every Conversation and on every launch.
public enum PersonMark {
    /// The first letters of the first and last words, like "DC" for "Dana Cohen"; none for a Speaker without a name.
    public static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        guard SpeakerLabel.number(in: name) == nil, let first = words.first?.first else { return "" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }

    /// Which of `count` colors is the name's, from a hash of its letters: `hashValue` changes with every launch.
    public static func colorIndex(of name: String, count: Int) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % UInt32(max(count, 1)))
    }
}
