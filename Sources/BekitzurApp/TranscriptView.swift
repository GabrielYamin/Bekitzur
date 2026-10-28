import BekitzurDomain
import SwiftUI

/// One Speaker's consecutive speech, with each word numbered across the whole Transcript.
struct TranscriptLine: Identifiable {
    let id: Int
    let speaker: String
    let start: Double
    let words: [NumberedWord]
    /// The segments' text, shown as is when they have no word times (Transcripts made before those were kept).
    let text: String

    /// The Transcript's lines with the user's fixes applied: corrected words show what was said, and words said by
    /// another Speaker sit in that Speaker's line.
    static func lines(from transcript: Transcript, flags: TranscriptFlags) -> [TranscriptLine] {
        let speakers = Array(Set(transcript.segments.compactMap(\.speaker))).sorted()
        var lines: [TranscriptLine] = []
        var number = 0
        var speaker: String?
        var start = 0.0
        var words: [NumberedWord] = []
        var texts: [String] = []

        func finishLine() {
            guard !texts.isEmpty else { return }
            lines.append(TranscriptLine(id: lines.count, speaker: speaker ?? "Speaker", start: start, words: words, text: texts.joined(separator: " ")))
            words = []
            texts = []
        }

        for segment in transcript.segments {
            guard let segmentWords = segment.words, !segmentWords.isEmpty else {
                if !texts.isEmpty, segment.speaker != speaker { finishLine() }
                if texts.isEmpty {
                    speaker = segment.speaker
                    start = segment.start
                }
                texts.append(segment.text)
                continue
            }
            for word in segmentWords {
                let said = flags.speaker(of: word, transcribedAs: segment.speaker, among: speakers)
                if !texts.isEmpty, said != speaker { finishLine() }
                if texts.isEmpty {
                    speaker = said
                    start = word.start
                }
                let text = flags.text(of: word)
                words.append(NumberedWord(number: number, word: word, text: text, transcribedSpeaker: segment.speaker))
                texts.append(text)
                number += 1
            }
        }
        finishLine()
        return lines
    }

    /// The word being said at `time`: the last one started, until the next one starts or 1.5 seconds pass.
    static func word(at time: Double, starts: [Double]) -> Int? {
        var low = 0, high = starts.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if starts[middle] <= time {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let index = found else { return nil }
        let next = index + 1 < starts.count ? starts[index + 1] : .infinity
        return time < min(next, starts[index] + 1.5) ? index : nil
    }
}

struct NumberedWord {
    let number: Int
    /// The word as transcribed, which its marks point to.
    let word: TranscriptWord
    /// What the word says: the user's correction, or what was transcribed.
    let text: String
    let transcribedSpeaker: String?
}

/// What the Transcript's words and lines can do, passed down so the rows stay cheap to compare.
struct TranscriptActions {
    let toggle: (TranscriptWord) -> Void
    let assign: ([NumberedWord], String) -> Void
    let correct: (TranscriptWord) -> Void
    let toggleSpeaker: (TranscriptLine) -> Void
    let play: (Double) -> Void
    let listened: (Double) -> Void
}

struct TranscriptView: View {
    let model: AppModel
    let info: ConversationInfo
    let result: ProcessedConversation
    let playback: PlaybackModel
    @ViewState private var follow = true
    @ViewState private var correcting: WordToCorrect?

    private struct WordToCorrect: Identifiable {
        let word: TranscriptWord
        var id: Double { word.start }
    }

    var body: some View {
        let flags = model.flags[info.id] ?? TranscriptFlags()
        let lines = TranscriptLine.lines(from: result.transcript, flags: flags)
        let words = lines.flatMap(\.words)
        let starts = words.map(\.word.start)
        let lineOfWord = lines.flatMap { line in line.words.map { _ in line.id } }
        let actions = TranscriptActions(
            toggle: { model.toggleFlag($0, in: info.id) },
            assign: { words, speaker in model.assign(words.map { ($0.word, $0.transcribedSpeaker) }, to: speaker, in: info.id) },
            correct: { correcting = WordToCorrect(word: $0) },
            toggleSpeaker: { model.toggleSpeakerFlag(lineStartingAt: $0.start, speaker: $0.speaker, in: info.id) },
            play: { time in
                playback.seek(to: time)
                playback.play()
            },
            listened: { model.noteListened(until: $0, in: info.id) }
        )

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(words.isEmpty
                     ? "This Transcript has no word timings. Transcribe it again to follow along word by word."
                     : "Click a word to mark it wrong. Right-click a word or a speaker to say what was said, or who said it. F marks the word just played.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if !flags.words.isEmpty || !flags.speakers.isEmpty {
                    let corrected = flags.words.filter { $0.correction != nil }.count
                    let moved = flags.words.filter { $0.saidBy != nil || $0.otherSpeaker == true }.count
                    let wrong = flags.words.filter { !$0.isFix }.count
                    Text([
                        corrected > 0 ? "\(corrected) corrected" : nil,
                        moved > 0 ? "\(moved) moved to another speaker" : nil,
                        wrong + flags.speakers.count > 0 ? "\(wrong + flags.speakers.count) marked wrong" : nil,
                    ].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                }
                Button("Mark word just played") {
                    if let index = TranscriptLine.word(at: max(0, playback.time - 0.4), starts: starts) {
                        model.toggleFlag(words[index].word, in: info.id)
                    }
                }
                .keyboardShortcut("f", modifiers: [])
                .disabled(words.isEmpty || !playback.isLoaded)
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            Divider()
            TranscriptLines(
                lines: lines,
                starts: starts,
                lineOfWord: lineOfWord,
                flags: flags,
                speakers: result.speakers.map(\.displayName),
                rightToLeft: result.transcript.language == .hebrew,
                follow: follow,
                playback: playback,
                actions: actions
            )
        }
        .task(id: info.id) { model.loadFlags(info.id) }
        .sheet(item: $correcting) { item in
            CorrectionSheet(word: item.word, said: flags.flag(for: item.word)?.correction ?? "") { said in
                model.correct(item.word, as: said, in: info.id)
            }
        }
    }
}

/// The lines, redrawn as playback moves; only the line with the current word changes.
private struct TranscriptLines: View {
    let lines: [TranscriptLine]
    let starts: [Double]
    let lineOfWord: [Int]
    let flags: TranscriptFlags
    let speakers: [String]
    let rightToLeft: Bool
    let follow: Bool
    let playback: PlaybackModel
    let actions: TranscriptActions

    var body: some View {
        let current = TranscriptLine.word(at: playback.time, starts: starts)
        let currentLine = current.map { lineOfWord[$0] }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lines) { line in
                        LineView(
                            line: line,
                            current: currentLine == line.id ? current : nil,
                            flags: flags,
                            speakers: speakers,
                            rightToLeft: rightToLeft,
                            actions: actions
                        )
                        .equatable()
                        .id(line.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: currentLine) { _, line in
                guard follow, playback.isPlaying, let line else { return }
                withAnimation { proxy.scrollTo(line, anchor: .center) }
            }
            .onChange(of: Int(playback.time / 5)) {
                if playback.isPlaying { actions.listened(playback.time) }
            }
        }
    }
}

private struct LineView: View, @MainActor Equatable {
    let line: TranscriptLine
    let current: Int?
    let flags: TranscriptFlags
    let speakers: [String]
    let rightToLeft: Bool
    let actions: TranscriptActions

    static func == (a: LineView, b: LineView) -> Bool {
        a.line.id == b.line.id && a.line.start == b.line.start && a.line.speaker == b.line.speaker && a.line.text == b.line.text
            && a.current == b.current && a.rightToLeft == b.rightToLeft && a.speakers == b.speakers
            && a.flags.words == b.flags.words && a.flags.speakers == b.flags.speakers
    }

    var body: some View {
        let speakerFlagged = flags.isSpeakerFlagged(lineStartingAt: line.start)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(line.speaker).font(.headline)
                Button(timestamp(line.start)) { actions.play(line.start) }
                    .buttonStyle(.link)
                    .font(.caption.monospacedDigit())
                    .help("Play from here")
                if speakerFlagged {
                    Label("Wrong speaker", systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
                }
            }
            .contextMenu {
                SaidByMenu(speakers: speakers, current: line.speaker) { actions.assign(line.words, $0) }
                    .disabled(line.words.isEmpty)
                if speakerFlagged {
                    Button("Take the wrong-speaker mark off") { actions.toggleSpeaker(line) }
                }
                Button("Play from here") { actions.play(line.start) }
            }
            if line.words.isEmpty {
                DirectionalText(line.text, rightToLeft: rightToLeft)
            } else {
                FlowLayout(rightToLeft: rightToLeft) {
                    ForEach(line.words, id: \.number) { item in
                        WordView(
                            item: item,
                            isCurrent: item.number == current,
                            flag: flags.flag(for: item.word),
                            lineSpeaker: line.speaker,
                            speakers: speakers,
                            rightToLeft: rightToLeft,
                            actions: actions
                        )
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// "Said by …" with each other Speaker of the Conversation.
private struct SaidByMenu: View {
    let speakers: [String]
    let current: String
    let choose: (String) -> Void

    var body: some View {
        let others = speakers.filter { $0 != current }
        if others.count == 1 {
            Button("Said by \(others[0])") { choose(others[0]) }
        } else if !others.isEmpty {
            Menu("Said by") {
                ForEach(others, id: \.self) { name in
                    Button(name) { choose(name) }
                }
            }
        }
    }
}

private struct WordView: View {
    let item: NumberedWord
    let isCurrent: Bool
    let flag: TranscriptFlags.Word?
    let lineSpeaker: String
    let speakers: [String]
    let rightToLeft: Bool
    let actions: TranscriptActions

    private var corrected: Bool { flag?.correction != nil }
    private var moved: Bool { flag?.saidBy != nil || flag?.otherSpeaker == true }
    private var markedWrong: Bool { flag != nil && !corrected && !moved }
    private var rewritten: Bool { item.word.transcribed != nil && !corrected }

    var body: some View {
        Text(item.text)
            .underline(flag != nil || rewritten, pattern: flag == nil ? .dot : .solid, color: underline)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
            .contentShape(Rectangle())
            .onTapGesture { actions.toggle(item.word) }
            .contextMenu {
                Button("Play from here") { actions.play(item.word.start) }
                Button(flag == nil ? "Mark as wrong" : "Take the mark off") { actions.toggle(item.word) }
                SaidByMenu(speakers: speakers, current: lineSpeaker) { actions.assign([item], $0) }
                Button("Type what was said…") { actions.correct(item.word) }
            }
            .help(helpText)
    }

    private var underline: Color {
        if corrected { return .green }
        if moved { return .orange }
        if markedWrong { return .red }
        return .secondary
    }

    private var helpText: String {
        let transcribed = item.word.transcribed ?? item.word.text
        guard flag != nil else {
            return rewritten ? "Transcribed as “\(transcribed)”; click to mark as wrong" : "Click to mark as wrong"
        }
        var parts: [String] = []
        if corrected || rewritten { parts.append("Transcribed as “\(transcribed)”") }
        if moved { parts.append("Transcribed as said by \(item.transcribedSpeaker ?? "another speaker")") }
        if markedWrong { parts.append("Marked wrong") }
        return parts.joined(separator: "; ")
    }

    private var background: Color {
        if isCurrent { return Color.accentColor.opacity(0.35) }
        if markedWrong { return Color.red.opacity(0.15) }
        return .clear
    }
}

private struct CorrectionSheet: View {
    let word: TranscriptWord
    let save: (String) -> Void
    @ViewState private var said: String
    @Environment(\.dismiss) private var dismiss

    init(word: TranscriptWord, said: String, save: @escaping (String) -> Void) {
        self.word = word
        self.save = save
        _said = ViewState(initialValue: said)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What was said instead of “\(word.text)”?").font(.headline)
            TextField("What was said", text: $said)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(done)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func done() {
        save(said)
        dismiss()
    }
}
