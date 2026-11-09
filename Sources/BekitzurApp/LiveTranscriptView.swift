import BekitzurDomain
import BekitzurModels
import BekitzurPipeline
import SwiftUI

/// What's been said so far, while recording and until the Notes are written. It's transcribed in chunks of about half
/// a minute, so it runs that far behind; Speakers and English terms come once the recording stops.
struct LiveTranscriptView: View {
    let model: AppModel
    let info: ConversationInfo
    @ViewState private var follow = true

    var body: some View {
        let live = model.liveTranscripts[info.id]
        let segments = live?.segments ?? []
        let stopped = info.status == .recording && model.liveStopped.contains(info.id)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if info.status == .recording {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text("Recording")
                        RecordingTimer(since: info.startedAt)
                    }
                    .font(.headline)
                    Text("The Transcript follows about half a minute behind. Speakers and English terms are added when you stop.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text(ShownNames.step(info.step)).font(.callout)
                }
                Spacer()
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                if info.status == .recording {
                    Button("Stop and write Notes") { model.stopRecording() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if stopped {
                Label(
                    BekitzurPaths.modelStore.usable([.hebrewSpeech, .englishSpeech])
                        ? "Live transcription stopped. The recording goes on, and its Transcript will be made from the recording when you stop."
                        : "There's no live Transcript until Bekitzur's models are downloaded. The recording goes on, and it's transcribed once they're in.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            if segments.isEmpty, !stopped {
                ContentUnavailableView {
                    Label("Listening", systemImage: "waveform")
                } description: {
                    Text("The first lines appear about half a minute after people start talking.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(timestamp(segment.start))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .leading)
                                    DirectionalText(segment.text, rightToLeft: segment.text.direction(fallback: live?.language == .hebrew ? .rightToLeft : .leftToRight) == .rightToLeft)
                                        .textSelection(.enabled)
                                }
                                .id(index)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: segments.count) { _, count in
                        guard follow, count > 0 else { return }
                        withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                    .onAppear {
                        if follow, !segments.isEmpty { proxy.scrollTo(segments.count - 1, anchor: .bottom) }
                    }
                }
            }
        }
    }
}
