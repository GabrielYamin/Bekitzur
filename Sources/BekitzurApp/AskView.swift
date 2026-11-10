import BekitzurDomain
import SwiftUI

/// Questions about one Conversation, answered from its Transcript alone. An answer shows the lines it comes from, each a
/// quote checked against the Transcript; when nothing checks out, it says the Conversation doesn't say.
struct AskView: View {
    let model: AppModel
    let info: ConversationInfo
    /// The Notes' turns, which tell where a quoted turn ends.
    let turns: [Turn]
    /// Plays a quoted line where it's shown.
    let player: SourcePlayer
    @ViewState private var question = ""

    var body: some View {
        let exchanges = model.exchanges[info.id] ?? []
        let asking = model.askingID == info.id
        VStack(spacing: 0) {
            if exchanges.isEmpty {
                ContentUnavailableView {
                    Label("Ask about this Conversation", systemImage: "questionmark.bubble")
                } description: {
                    Text("Answers come only from the Transcript, with the lines they're based on. When the Transcript doesn't say, you'll be told so.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(exchanges) { exchange in
                                ExchangeView(exchange: exchange, turns: turns, player: player).id(exchange.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: exchanges.last?.answer) {
                        if let last = exchanges.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onChange(of: exchanges.count) {
                        if let last = exchanges.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Ask a question, like who's doing what", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                if asking { ProgressView().controlSize(.small) }
                Button("Ask", action: send)
                    .disabled(model.askingID != nil || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private func send() {
        guard model.askingID == nil else { return }
        model.ask(question, about: info.id)
        question = ""
    }
}

private struct ExchangeView: View {
    let exchange: AppModel.Exchange
    let turns: [Turn]
    let player: SourcePlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DirectionalText(exchange.question).font(.headline)
            if let failure = exchange.failure {
                Label("Couldn't answer: \(failure)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let answer = exchange.answer {
                if let text = answer.text {
                    DirectionalText(text).textSelection(.enabled)
                    ForEach(Array(answer.evidence.enumerated()), id: \.offset) { _, evidence in
                        let speaker = evidence.speaker ?? ""
                        SourceButton(speaker: speaker, text: evidence.quote, player: player) {
                            let end = turns.first { $0.id == evidence.turn && $0.start == evidence.start }?.end
                            return SourceClip(quote: evidence.quote, speaker: speaker, start: evidence.start, end: end, in: player.transcript())
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "play.circle").foregroundStyle(.secondary)
                                Text(timestamp(evidence.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(evidence.speaker.map(ShownNames.speaker) ?? "").font(.caption.bold()).foregroundStyle(.secondary)
                                DirectionalText("“\(evidence.quote)”").font(.callout).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .help("Listen")
                    }
                } else {
                    Label("This isn't in the Conversation.", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
            } else {
                Label("Looking in the Transcript…", systemImage: "ellipsis").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
