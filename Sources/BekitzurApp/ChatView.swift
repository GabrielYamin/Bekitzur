import BekitzurDomain
import SwiftUI

/// A chat about one Conversation, answered from its Transcript and its Notes alone, which a message can ask to change.
/// An answer shows the lines it comes from, each a quote checked against the Transcript; when nothing checks out, it says
/// the Conversation doesn't say. A change to the Notes shows what it changed, and the last one can be undone.
struct ChatView: View {
    let model: AppModel
    let info: ConversationInfo
    /// The Notes' turns, which tell where a quoted turn ends.
    let turns: [Turn]
    /// Plays a quoted line where it's shown.
    let player: SourcePlayer
    @ViewState private var message = ""
    /// Another Conversation picked from the menu, whose Notes the next message brings in.
    @ViewState private var attached: String?

    var body: some View {
        if model.chatTooLong(info.id) {
            ContentUnavailableView {
                Label("Chat works with Conversations up to 2 hours", systemImage: "clock.badge.exclamationmark")
            } description: {
                Text("Past that, the model starts missing what's in the Transcript.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            chat
        }
    }

    private var chat: some View {
        let exchanges = model.exchanges[info.id] ?? []
        let replying = model.replyingID == info.id
        return VStack(spacing: 0) {
            if exchanges.isEmpty {
                ContentUnavailableView {
                    Label("Chat about this Conversation", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Ask about what was said, or ask to change the Notes. Answers come only from the Transcript and the Notes, with the lines they're based on, and you'll be told when they don't say. To use another Conversation's Notes, name it, like “my meeting with Dana last week”, or pick it from the menu beside the message box.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(exchanges) { exchange in
                                ExchangeView(
                                    exchange: exchange, turns: turns, player: player, canUndo: model.canUndo(exchange, in: info.id),
                                    undo: { model.undo(exchange, in: info.id) }, open: { model.selection = $0 }
                                )
                                .id(exchange.id)
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
            VStack(alignment: .leading, spacing: 6) {
                if model.isProcessing {
                    Text("The chat waits while Bekitzur processes a Conversation.").font(.caption).foregroundStyle(.secondary)
                }
                let candidates = model.chatCandidates(for: info.id)
                if let candidate = candidates.first(where: { $0.id == attached }) {
                    attachment(candidate)
                }
                HStack(spacing: 8) {
                    bringIn(candidates)
                    TextField("Ask something, or ask to change the Notes", text: $message)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    if replying { ProgressView().controlSize(.small) }
                    Button("Send", action: send)
                        .disabled(model.replyingID != nil || model.isProcessing || message.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
            .background(.bar)
        }
        .onAppear { model.loadChat(info.id) }
    }

    private func send() {
        guard model.replyingID == nil, !model.isProcessing else { return }
        model.send(message, about: info.id, bringing: attached)
        message = ""
        attached = nil
    }

    private func bringIn(_ candidates: [ChatCandidate]) -> some View {
        Menu {
            if candidates.isEmpty { Text("No other Conversations yet") }
            ForEach(candidates.prefix(30)) { candidate in
                Button(candidate.title + " · " + candidate.date.formatted(date: .abbreviated, time: .omitted)) { attached = candidate.id }
            }
        } label: {
            Image(systemName: "link")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Bring in another Conversation's Notes")
    }

    private func attachment(_ candidate: ChatCandidate) -> some View {
        HStack(spacing: 6) {
            Label("With “\(candidate.title)” · \(candidate.date.formatted(date: .abbreviated, time: .omitted))", systemImage: "link")
            Button { attached = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("Don't bring it in")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ExchangeView: View {
    let exchange: ChatExchange
    let turns: [Turn]
    let player: SourcePlayer
    let canUndo: Bool
    let undo: () -> Void
    /// Shows another Conversation.
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let app = exchange.from {
                changed(by: app)
            } else {
                reply
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The user's message and the chat's reply.
    @ViewBuilder
    private var reply: some View {
        DirectionalText(exchange.message).font(.headline)
        if let reference = exchange.reference { source(reference) }
        if let failure = exchange.failure {
            Label("Couldn't answer: \(failure)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        if let answer = exchange.answer {
            if let text = answer.text {
                DirectionalText(text).textSelection(.enabled)
            } else if exchange.edits.isEmpty, exchange.failure == nil {
                Label("This isn't in the Conversation.", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
            ForEach(Array(answer.evidence.enumerated()), id: \.offset) { _, evidence in
                quote(evidence)
            }
            if !exchange.edits.isEmpty { changes }
        } else if exchange.failure == nil {
            Label("Looking in the Transcript…", systemImage: "ellipsis").foregroundStyle(.secondary)
        }
    }

    /// Changes an AI app made to the Notes through Bekitzur's MCP server, with the reason it gave.
    @ViewBuilder
    private func changed(by app: String) -> some View {
        Label(app.isEmpty ? String(localized: "Changed by an AI app") : String(localized: "Changed by \(app)"), systemImage: "sparkles")
            .font(.headline)
        if !exchange.message.isEmpty { DirectionalText(exchange.message).foregroundStyle(.secondary) }
        changes
    }

    private func quote(_ evidence: Evidence) -> some View {
        let speaker = evidence.speaker ?? ""
        return SourceButton(speaker: speaker, text: evidence.quote, player: player) {
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

    /// The other Conversation whose Notes the reply used.
    private func source(_ reference: ChatReference) -> some View {
        Button { open(reference.id) } label: {
            Label("From “\(reference.title)” · \(reference.date.formatted(date: .abbreviated, time: .omitted))", systemImage: "link")
                .font(.caption)
        }
        .buttonStyle(.link)
        .help("Show this Conversation")
    }

    /// What the reply changed in the Notes, struck through once undone.
    private var changes: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(exchange.edits.enumerated()), id: \.offset) { _, edit in
                Label(Self.describe(edit), systemImage: Self.icon(edit))
                    .font(.callout)
                    .strikethrough(exchange.undone)
                    .foregroundStyle(exchange.undone ? .secondary : .primary)
            }
            if exchange.undone {
                Text("Undone").font(.caption).foregroundStyle(.secondary)
            } else if canUndo {
                Button("Undo", action: undo).controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private static func describe(_ edit: AppliedEdit) -> String {
        switch edit.kind {
        case .added:
            switch edit.section {
            case .decision: String(localized: "Added a Decision: \(edit.text)")
            case .openQuestion: String(localized: "Added an Open Question: \(edit.text)")
            default: String(localized: "Added an Action Item: \(edit.text)")
            }
        case .changed:
            switch edit.section {
            case .decision: String(localized: "Changed a Decision: \(edit.text)")
            case .openQuestion: String(localized: "Changed an Open Question: \(edit.text)")
            default: String(localized: "Changed an Action Item: \(edit.text)")
            }
        case .removed:
            switch edit.section {
            case .decision: String(localized: "Removed a Decision: \(edit.text)")
            case .openQuestion: String(localized: "Removed an Open Question: \(edit.text)")
            default: String(localized: "Removed an Action Item: \(edit.text)")
            }
        case .title: String(localized: "Changed the title: \(edit.text)")
        case .summary: String(localized: "Changed the summary")
        }
    }

    private static func icon(_ edit: AppliedEdit) -> String {
        switch edit.kind {
        case .added: "plus.circle"
        case .removed: "minus.circle"
        case .changed, .title, .summary: "pencil.circle"
        }
    }
}
