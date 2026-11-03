import Foundation

/// Whether a Mac has the memory Bekitzur is made for. The Notes model alone is about 15 GB, held in memory while it
/// writes: with less than 32 GB, writing the Notes can take very long, or fail for a long Conversation, and under 24 GB
/// it can't work, so the models aren't downloaded. Nothing checked this before: a 16 GB Mac downloaded the 18 GB of
/// models and recorded, then couldn't write the Notes.
public enum MemoryRequirement: Equatable, Sendable {
    case enough
    case low(gigabytes: Int)
    case tooLow(gigabytes: Int)

    public static let recommended = 32
    public static let minimum = 24

    public init(bytes: UInt64) {
        let gigabytes = Int((Double(bytes) / Double(1 << 30)).rounded())
        self = gigabytes >= Self.recommended ? .enough : gigabytes >= Self.minimum ? .low(gigabytes: gigabytes) : .tooLow(gigabytes: gigabytes)
    }

    /// This Mac's; or, to see how Bekitzur looks on a smaller Mac, as many gigabytes as the `memoryForChecks` default.
    public static var thisMac: MemoryRequirement {
        let pretend = UserDefaults.standard.integer(forKey: "memoryForChecks")
        return MemoryRequirement(bytes: pretend > 0 ? UInt64(pretend) << 30 : ProcessInfo.processInfo.physicalMemory)
    }
}
