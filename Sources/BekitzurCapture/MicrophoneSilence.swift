import Foundation

/// When a microphone that stopped sending audio is started again from scratch, and when the user hears of it. A device
/// can go quiet without a word, as a Bluetooth headset switching to its call mode did, and the recording would go on
/// without the user's voice; a quiet room still sends audio, so only no audio at all counts.
struct MicrophoneSilence {
    enum Action: Equatable {
        /// Start the microphone again from scratch.
        case rebuild
        /// It's been this many seconds without audio, even started again.
        case silent(after: Double)
        /// Audio came again after this many seconds without.
        case hearing(after: Double)
    }

    /// Seconds without audio before the microphone is started again from scratch.
    static let rebuildAfter = 4.0
    /// Seconds without audio before the user hears of it.
    static let silentAfter = 8.0
    /// Seconds before trying again while it stays silent, doubling each time up to `longestRetry`.
    static let retry = 10.0
    static let longestRetry = 60.0

    private(set) var silent = false
    /// When it was last started again; nil while audio comes.
    private var rebuilt: Double?
    private var retries = 0
    /// The longest it's gone without audio since audio last came.
    private var quietest = 0.0

    /// - Parameters:
    ///   - quiet: Seconds since the last audio, or since recording started.
    ///   - now: Seconds by any steady clock.
    ///   - restarting: A restart after a change of device is under way, which goes first until the user would hear of the
    ///     silence anyway: one that never settles would otherwise keep them from hearing of it.
    mutating func check(quiet: Double, now: Double, restarting: Bool) -> [Action] {
        // Blocks come several times a second.
        guard quiet >= 1 else {
            let wasQuiet = silent || rebuilt != nil
            let after = quietest
            silent = false
            rebuilt = nil
            retries = 0
            quietest = 0
            return wasQuiet ? [.hearing(after: after)] : []
        }
        quietest = max(quietest, quiet)
        guard !restarting || quiet >= Self.silentAfter else { return [] }
        var actions: [Action] = []
        if let rebuilt {
            if silent, now - rebuilt >= min(Self.longestRetry, Self.retry * pow(2, Double(retries))) {
                self.rebuilt = now
                retries += 1
                actions.append(.rebuild)
            }
        } else if quiet >= Self.rebuildAfter {
            rebuilt = now
            actions.append(.rebuild)
        }
        if !silent, quiet >= Self.silentAfter {
            silent = true
            actions.append(.silent(after: quiet))
        }
        return actions
    }
}
