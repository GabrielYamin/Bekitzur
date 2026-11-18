import Foundation
import Testing
@testable import BekitzurDomain

struct RecordingControlsTests {
    private func level(of samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { AudioLevel.of($0) }
    }

    /// Silence is empty, loud speech is full, and in between goes by decibels, so a quiet voice still shows.
    @Test func levelsGoFromSilenceToLoudSpeech() {
        let silence = [Float](repeating: 0, count: 480)
        let loud = (0..<480).map { Float(sin(Double($0) / 7)) * 0.8 }
        let quiet = loud.map { $0 / 31.6 }

        let none = level(of: silence)
        let full = level(of: loud)
        let some = level(of: quiet)

        #expect(none == 0)
        #expect(full == 1)
        #expect(some > 0.4 && some < 0.7)
        #expect(level(of: []) == 0)
    }

    @Test func aShortcutShowsAsMenusDo() {
        let changed = KeyShortcut(keyCode: 1, key: "S", command: true, control: true, shift: true)

        #expect(KeyShortcut.quickNote.shown == "⌥⌘N")
        #expect(changed.shown == "⌃⇧⌘S")
        #expect(KeyShortcut.quickNote.isUsable)
        #expect(!KeyShortcut(keyCode: 1, key: "S", shift: true).isUsable)
    }
}
