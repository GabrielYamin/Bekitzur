import BekitzurDomain
import SwiftUI

struct NotesView: View {
    let result: ProcessedConversation
    /// Plays the Recording from a Source.
    let play: (Double) -> Void

    private var notes: Notes { result.notes }
    private var turns: [String: Turn] { Dictionary(result.turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(notes.summary).font(.body).lineSpacing(3)

                if !notes.decisions.isEmpty {
                    NotesSection(title: "Decisions", systemImage: "checkmark.seal") {
                        ForEach(Array(notes.decisions.enumerated()), id: \.offset) { _, decision in
                            NoteItem(text: decision.text, quote: decision.quote, sources: decision.sourceTurns, turns: turns, play: play)
                        }
                    }
                }

                if !notes.actionItems.isEmpty {
                    NotesSection(title: "Action Items", systemImage: "checklist") {
                        ForEach(Array(notes.actionItems.enumerated()), id: \.offset) { _, item in
                            NoteItem(text: item.text, quote: item.quote, sources: item.sourceTurns, turns: turns, play: play) {
                                HStack(spacing: 6) {
                                    Chip(item.owner ?? "No Owner", systemImage: "person", prominent: item.owner != nil)
                                    if let due = NotesMarkdown.dueText(item) {
                                        Chip(due, systemImage: "calendar", prominent: true)
                                            .help(item.duePhrase.map { "Said: \"\($0)\"" } ?? "")
                                    }
                                }
                            }
                        }
                    }
                }

                if !notes.openQuestions.isEmpty {
                    NotesSection(title: "Open Questions", systemImage: "questionmark.bubble") {
                        ForEach(Array(notes.openQuestions.enumerated()), id: \.offset) { _, question in
                            NoteItem(text: question.text, quote: nil, sources: question.sourceTurns, turns: turns, play: play)
                        }
                    }
                }

                if notes.decisions.isEmpty && notes.actionItems.isEmpty && notes.openQuestions.isEmpty {
                    Text("No Decisions, Action Items, or Open Questions in this Conversation.").foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct NotesSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage).font(.title3.bold())
            content
        }
    }
}

private struct NoteItem<Details: View>: View {
    let text: String
    let quote: String?
    let sources: [String]
    let turns: [String: Turn]
    let play: (Double) -> Void
    @ViewBuilder let details: Details

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).fontWeight(.medium)
            details
            if let quote, !quote.isEmpty {
                DirectionalText("“\(quote)”").font(.callout).foregroundStyle(.secondary)
            }
            if !sources.isEmpty {
                HStack(spacing: 6) {
                    ForEach(sources, id: \.self) { id in
                        if let turn = turns[id] {
                            Button {
                                play(turn.start ?? 0)
                            } label: {
                                Label("\(turn.speaker) \(timestamp(turn.start))", systemImage: "play.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Play from here: \(turn.text)")
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension NoteItem where Details == EmptyView {
    init(text: String, quote: String?, sources: [String], turns: [String: Turn], play: @escaping (Double) -> Void) {
        self.init(text: text, quote: quote, sources: sources, turns: turns, play: play) { EmptyView() }
    }
}

private struct Chip: View {
    let text: String
    let systemImage: String
    let prominent: Bool

    init(_ text: String, systemImage: String, prominent: Bool) {
        self.text = text
        self.systemImage = systemImage
        self.prominent = prominent
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(prominent ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(prominent ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: Capsule())
    }
}
