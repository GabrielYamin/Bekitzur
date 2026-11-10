import BekitzurDomain
import SwiftUI

/// What playing a Source needs: the player, the Transcript as it shows, and the way to it.
struct SourcePlayer {
    let playback: PlaybackModel
    /// The Transcript with the user's fixes, made when a Source is played.
    let transcript: () -> Transcript
    /// Opens the Transcript at a moment, playing on from there.
    let showInTranscript: (Double) -> Void
}

/// A button that plays where something came from in a popover, so the Notes or the answer stay in view.
struct SourceButton<Label: View>: View {
    let speaker: String
    /// What was said, for a turn whose words have no times.
    let text: String
    let player: SourcePlayer
    let clip: () -> SourceClip?
    @ViewBuilder let label: Label
    @ViewState private var shown: SourceClip?

    var body: some View {
        Button {
            shown = clip()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { shown != nil }, set: { if !$0 { shown = nil } }), arrowEdge: .bottom) {
            if let shown {
                SourcePreview(clip: shown, speaker: speaker, text: text, playback: player.playback) {
                    self.shown = nil
                    player.showInTranscript(shown.range.lowerBound)
                }
            }
        }
    }
}

/// A Source's moment, playing as it opens: who said it, what they said with the quoted words standing out, and where
/// the clip is.
private struct SourcePreview: View {
    let clip: SourceClip
    let speaker: String
    let text: String
    let playback: PlaybackModel
    let showInTranscript: () -> Void
    @ViewState private var wasPlaying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "\(ShownNames.speaker(clip.speaker ?? speaker)) · \(timestamp(clip.range.lowerBound))").font(.headline)
            said
            HStack(spacing: 10) {
                Button(action: toggle) {
                    Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(playing ? "Pause" : "Play")
                Slider(value: position, in: clip.range) { editing in
                    if editing {
                        wasPlaying = playing
                        playback.pause()
                    } else if wasPlaying {
                        resume()
                    }
                }
                .controlSize(.small)
                Text(verbatim: "\(timestamp(elapsed)) / \(timestamp(length))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .disabled(!playback.isLoaded)
            Button("Show in Transcript", action: showInTranscript)
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { playback.play(clip.range) }
        .onDisappear { if playing { playback.pause() } }
    }

    private var said: some View {
        let shown = clip.words.isEmpty ? text : clip.words.map(\.text).joined(separator: " ")
        return Text(clip.words.isEmpty ? AttributedString(text) : highlighted)
            .lineLimit(8)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, shown.isMostlyRightToLeft ? .rightToLeft : .leftToRight)
    }

    private var highlighted: AttributedString {
        var result = AttributedString()
        for (index, word) in clip.words.enumerated() {
            var run = AttributedString(index == 0 ? word.text : " " + word.text)
            if word.quoted {
                run.font = .body.weight(.semibold)
            } else {
                run.foregroundColor = .secondary
            }
            result += run
        }
        return result
    }

    /// Playing this clip, rather than the Transcript or another clip.
    private var playing: Bool {
        playback.isPlaying && playback.clip?.upperBound == clip.range.upperBound
    }

    private var length: Double { clip.range.upperBound - clip.range.lowerBound }
    private var elapsed: Double { min(max(playback.time - clip.range.lowerBound, 0), length) }

    private var position: Binding<Double> {
        Binding(get: { min(max(playback.time, clip.range.lowerBound), clip.range.upperBound) }, set: { playback.seek(to: $0) })
    }

    private func toggle() {
        if playing { playback.pause() } else { resume() }
    }

    /// From where it was paused in the clip, or from its start once it's played through.
    private func resume() {
        let time = playback.time
        let from = clip.range.contains(time) && time < clip.range.upperBound - 0.25 ? time : clip.range.lowerBound
        playback.play(from...clip.range.upperBound)
    }
}
