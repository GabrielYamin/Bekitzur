import Foundation

/// How much later a call's system audio track plays from some point on, so the other side lines up with the copy of it
/// that laptop speakers put in the microphone.
public struct TrackDelay: Codable, Sendable, Hashable {
    /// Seconds into the system audio track where this delay starts; it lasts until the next one.
    public var from: Double
    /// Seconds later than recorded; earlier when negative.
    public var delay: Double

    public init(from: Double, delay: Double) {
        self.from = from
        self.delay = delay
    }

    /// A stretch of the track, in its own seconds, and where it starts playing.
    public struct Piece: Equatable, Sendable {
        public var source: Range<Double>
        public var at: Double
    }

    /// Where each stretch of a track `duration` seconds long plays. A stretch that would start before the one before it
    /// ends, or before the start, loses its first moments instead; one that starts later leaves silence before it.
    public static func pieces(_ delays: [TrackDelay], duration: Double) -> [Piece] {
        var pieces: [Piece] = []
        var end = 0.0
        for (index, delay) in delays.enumerated() {
            var from = max(0, delay.from)
            let to = index + 1 < delays.count ? min(duration, delays[index + 1].from) : duration
            var at = from + delay.delay
            if at < end {
                from += end - at
                at = end
            }
            guard from < to else { continue }
            pieces.append(Piece(source: from..<to, at: at))
            end = at + (to - from)
        }
        return pieces
    }
}
