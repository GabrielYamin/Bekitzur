import ArgumentParser
import BekitzurAudio
import Foundation

struct AlignCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "align",
        abstract: "Measure when a call's microphone hears the system audio, which tells how far apart its two tracks start."
    )

    @Argument(help: "The microphone track.")
    var microphone: String

    @Argument(help: "The system audio track.")
    var system: String

    func run() throws {
        let started = Date()
        let mic = try AudioLoader.loadMono16k(URL(filePath: microphone)), sys = try AudioLoader.loadMono16k(URL(filePath: system))
        guard let lag = TrackAlignment.copyLag(of: sys, in: mic) else {
            print("No copy of the system audio in the microphone, as with headphones.")
            return
        }
        let delay = TrackAlignment.microphoneDelay(microphone: mic, system: sys) ?? 0
        print(String(format: "The microphone hears the system audio %.1f ms %@; play it %.1f ms later to line up.",
                     abs(lag * 1000), lag < 0 ? "before the system audio track has it" : "after it", delay * 1000))
        print("Along the call, the system audio plays:")
        for delay in TrackAlignment.systemAudioDelays(microphone: mic, system: sys) {
            print(String(format: "  from %@: %.1f ms later", minutes(delay.from), delay.delay * 1000))
        }
        log(String(format: "%.1f s", Date().timeIntervalSince(started)))
    }

    private func minutes(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}
