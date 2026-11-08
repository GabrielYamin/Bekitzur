import BekitzurPipeline
@testable import BekitzurSpeakers
import Foundation
import Testing

struct VoiceSeparatorTests {
    /// Two signals the stand-in model knows, unlike enough to tell apart.
    private static func voices(_ count: Int) -> [[Float]] {
        let first: [Float] = (0..<count).map { i -> Float in sin(Float(i) * 0.0123) }
        let second: [Float] = (0..<count).map { i -> Float in
            let square: Float = (i / 101) % 2 == 0 ? 0.4 : -0.4
            let wave: Float = sin(Float(i) * 0.0517) * 0.3
            return square + wave
        }
        return [first, second]
    }

    @Test(arguments: [10_000, VoiceSeparator.window, VoiceSeparator.window + 1, 100_000])
    func eachVoiceStaysWholeWhenTheModelGivesTheVoicesInEitherOrder(count: Int) {
        let truth = Self.voices(count)
        let mix = zip(truth[0], truth[1]).map(+)
        var step = 0
        let separated = VoiceSeparator.separate(mix) { window in
            defer { step += 1 }
            let at = step * VoiceSeparator.stride
            let parts: [[Float]] = truth.map { voice -> [Float] in
                (0..<window.count).map { i -> Float in
                    let sample = at + i
                    return sample < voice.count ? voice[sample] : 0
                }
            }
            return step.isMultiple(of: 2) ? parts : parts.reversed()
        }

        #expect(separated.map(\.count) == [count, count])
        let first = VoiceSeparator.correlation(separated[0], truth[0]) > VoiceSeparator.correlation(separated[0], truth[1]) ? 0 : 1
        #expect(VoiceSeparator.correlation(separated[0], truth[first]) > 0.999)
        #expect(VoiceSeparator.correlation(separated[1], truth[1 - first]) > 0.999)
    }

    static let model = BekitzurPaths.voiceSeparation

    @Test(.enabled(if: model != nil))
    func theModelGivesTwoVoicesAsLongAsTheAudio() async throws {
        let model = try #require(Self.model)
        let separator = try await VoiceSeparator(package: model.package, compiled: model.compiled)
        let samples: [Float] = (0..<40_000).map { i -> Float in sin(Float(i) * 0.05) * 0.3 }

        let voices = try separator.separate(samples)

        #expect(voices.map(\.count) == [40_000, 40_000])
        #expect(voices.allSatisfy { $0.allSatisfy(\.isFinite) })
    }
}
