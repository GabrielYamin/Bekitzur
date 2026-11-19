import BekitzurDomain
import BekitzurModels
import BekitzurPipeline
import SwiftUI

/// While recording, the user's notes beside what's being said; after Stop, beside Bekitzur's steps toward the Notes.
struct RecordingView: View {
    let model: AppModel
    let info: ConversationInfo

    var body: some View {
        HStack(spacing: 0) {
            YourNotesEditor(model: model, info: info)
            Divider()
            Group {
                if info.status == .recording {
                    LiveLines(model: model, info: info)
                } else {
                    ProcessingSteps(info: info)
                }
            }
            .padding(22)
            .frame(width: 320)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.background.secondary)
        }
    }
}

/// What's been said so far, the newest line largest and the older ones fading, like lyrics. It's transcribed in chunks
/// of about half a minute, from both tracks mixed, so it runs that far behind and doesn't tell who's speaking.
private struct LiveLines: View {
    let model: AppModel
    let info: ConversationInfo

    static let shown = 8

    var body: some View {
        let live = model.liveTranscripts[info.id]
        let segments = live?.segments ?? []
        let fallback: TextDirection = live?.language == .hebrew ? .rightToLeft : .leftToRight
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Live")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text("about half a minute behind")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Group {
                if model.liveStopped.contains(info.id) {
                    Label(
                        BekitzurPaths.modelStore.usable([.hebrewSpeech, .englishSpeech])
                            ? "Live transcription stopped. The recording goes on, and its Transcript will be made from the recording when you stop."
                            : "There's no live Transcript until Bekitzur's models are downloaded. The recording goes on, and it's transcribed once they're in.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                } else if segments.isEmpty {
                    Text("The first lines appear about half a minute after people start talking.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(max(0, segments.count - Self.shown)..<segments.count, id: \.self) { index in
                            line(segments[index], age: segments.count - 1 - index, fallback: fallback)
                        }
                    }
                    .animation(.easeOut(duration: 0.3), value: segments.count)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .clipped()
        }
    }

    private func line(_ segment: TranscriptSegment, age: Int, fallback: TextDirection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(timestamp(segment.start))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.quaternary)
            DirectionalText(segment.text, rightToLeft: segment.text.direction(fallback: fallback) == .rightToLeft)
                .font(age == 0 ? .system(size: 20, weight: .semibold) : .system(size: age == 1 ? 15.5 : 14, weight: .medium))
                .foregroundStyle(Self.style(age: age))
                .lineLimit(age < 2 ? nil : 3)
                .textSelection(.enabled)
        }
    }

    private static func style(age: Int) -> HierarchicalShapeStyle {
        switch age {
        case 0: .primary
        case 1: .secondary
        case 2: .tertiary
        default: .quaternary
        }
    }
}

/// Bekitzur's way to the Notes: what it's done, what it's doing, and what's left. Separating people who talk at once
/// comes after the Notes, so it shows only while it runs.
private struct ProcessingSteps: View {
    let info: ConversationInfo

    private enum State {
        case done, now, later
    }

    var body: some View {
        let steps = Self.steps(for: info)
        let current = steps.firstIndex { $0.rawValue == info.step }
        VStack(alignment: .leading, spacing: 0) {
            Text("Bekitzur")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            if current == nil {
                row(ShownNames.step(info.step), .now)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                row(ShownNames.step(step.rawValue), current.map { index < $0 ? .done : index == $0 ? .now : .later } ?? .later)
            }
            Text("Everything runs on this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
        }
    }

    static func steps(for info: ConversationInfo) -> [ProcessingStep] {
        info.language == .english ? [.transcribing, .recognizingSpeakers, .writingNotes] : [.transcribing, .recognizingSpeakers, .checkingTerms, .writingNotes]
    }

    private func row(_ label: String, _ state: State) -> some View {
        HStack(spacing: 10) {
            Group {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                case .now: ProgressView().controlSize(.small)
                case .later: Image(systemName: "circle").foregroundStyle(.quaternary)
                }
            }
            .frame(width: 16, height: 16)
            Text(label)
                .fontWeight(state == .now ? .semibold : .regular)
                .foregroundStyle(state == .later ? .tertiary : .primary)
        }
        .padding(.vertical, 8)
    }
}
