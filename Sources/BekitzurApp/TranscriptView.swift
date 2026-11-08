import BekitzurDomain
import SwiftUI

/// One Speaker's speech, with each word numbered across the whole Transcript in the order it shows them.
struct TranscriptLine: Identifiable {
    let id: Int
    let speaker: String
    let start: Double
    let words: [NumberedWord]
    /// The segments' text, shown as is when they have no word times.
    let text: String
    /// When each word starts, to tell which one is being said.
    let starts: [Double]

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

/// A line on its own, or the lines of people who talked at once.
struct TranscriptRow: Identifiable {
    let id: Int
    let lines: [TranscriptLine]
    let start: Double
    let end: Double
    /// When a second person starts talking; the row's start for a line on its own.
    let atOnce: Double
    /// Separating people who talk at once found some of its words.
    let separated: Bool

    /// The Transcript's rows with the user's fixes applied: corrected words show what was said, a phrase corrected
    /// together shows as its first word, and words said by another Speaker sit in that Speaker's line. People who talked
    /// at once have a line each in one row (`TranscriptRows`).
    /// - Parameter together: Where the Speakers' timeline heard them talk at once, by the names they show as.
    static func rows(
        from transcript: Transcript,
        flags: TranscriptFlags,
        together: [(start: Double, end: Double, speakers: Set<String>)] = []
    ) -> [TranscriptRow] {
        let speakers = Array(Set(transcript.segments.compactMap(\.speaker))).sorted()
        // The rest of each phrase, by when it starts, shown with its first word.
        var phrases: [(start: Double, rest: [NumberedWord])] = []
        for segment in transcript.segments {
            for word in segment.words ?? [] {
                guard let start = flags.flag(for: word)?.phrase else { continue }
                let rest = NumberedWord(number: -1, word: word, text: "", transcribedSpeaker: segment.speaker)
                if let index = phrases.firstIndex(where: { abs($0.start - start) < 0.005 }) {
                    phrases[index].rest.append(rest)
                } else {
                    phrases.append((start, [rest]))
                }
            }
        }

        /// A word, or a segment's text without word times.
        struct Piece {
            let word: TranscriptWord?
            let text: String
            let start: Double
            let end: Double
            let speaker: String
            let transcribedSpeaker: String?
            let rest: [NumberedWord]
            let separated: Bool
        }
        var pieces: [Piece] = []
        for segment in transcript.segments {
            guard let words = segment.words, !words.isEmpty else {
                pieces.append(Piece(word: nil, text: segment.text, start: segment.start, end: segment.end, speaker: segment.speaker ?? "Speaker",
                                    transcribedSpeaker: segment.speaker, rest: [], separated: segment.separated == true))
                continue
            }
            for word in words where flags.flag(for: word)?.phrase == nil {
                let said = flags.speaker(of: word, transcribedAs: segment.speaker, among: speakers) ?? "Speaker"
                let rest = phrases.first { abs($0.start - word.start) < 0.005 }?.rest ?? []
                pieces.append(Piece(word: word, text: flags.text(of: word), start: word.start, end: word.end, speaker: said,
                                    transcribedSpeaker: segment.speaker, rest: rest, separated: segment.separated == true))
            }
        }

        // Text without word times makes lines of its own.
        let timed: [(start: Double, end: Double, speaker: String)] = pieces.map { piece -> (start: Double, end: Double, speaker: String) in
            let speaker = piece.word == nil ? piece.speaker + "\u{0}" : piece.speaker
            return (piece.start, piece.end, speaker)
        }
        let sentenceEnds: Set<Character> = [".", "?", "!", "…"]
        var endingSentences = Set<Int>()
        for (index, piece) in pieces.enumerated() {
            if let last = piece.text.last, sentenceEnds.contains(last) { endingSentences.insert(index) }
        }
        let layout = TranscriptRows.layout(timed, together: together, endingSentences: endingSentences)
        var rows: [TranscriptRow] = []
        var lineCount = 0
        var number = 0
        for row in layout {
            var lines: [TranscriptLine] = []
            for line in row {
                let texts = line.map { pieces[$0].text }.filter { !$0.isEmpty }
                guard !texts.isEmpty else { continue }
                var words: [NumberedWord] = []
                for piece in line.map({ pieces[$0] }) {
                    guard let word = piece.word else { continue }
                    words.append(NumberedWord(number: number, word: word, text: piece.text, transcribedSpeaker: piece.transcribedSpeaker, rest: piece.rest))
                    number += 1
                }
                let first = pieces[line[0]]
                lines.append(TranscriptLine(id: lineCount, speaker: first.speaker, start: first.start, words: words, text: texts.joined(separator: " "), starts: words.map(\.word.start)))
                lineCount += 1
            }
            guard !lines.isEmpty else { continue }
            let all: [Piece] = row.flatMap { $0 }.map { pieces[$0] }
            let start: Double = lines.map(\.start).min() ?? 0
            let end: Double = all.map(\.end).max() ?? 0
            let atOnce = Self.atOnce(lines, from: start, together: together)
            rows.append(TranscriptRow(id: rows.count, lines: lines, start: start, end: end, atOnce: atOnce, separated: all.contains(where: \.separated)))
        }
        return rows
    }

    /// When a second person starts talking in a row: the second line's start, or earlier where the timeline heard two
    /// of the row's people at once, since their words can be timed late.
    private static func atOnce(_ lines: [TranscriptLine], from start: Double, together: [(start: Double, end: Double, speakers: Set<String>)]) -> Double {
        guard lines.count > 1 else { return start }
        let speakers = Set(lines.map(\.speaker))
        var atOnce: Double = lines.map(\.start).sorted()[1]
        for stretch in together where stretch.start < atOnce && stretch.end > start {
            if stretch.speakers.intersection(speakers).count >= 2 { atOnce = max(start, stretch.start) }
        }
        return atOnce
    }

    /// Where the Speakers' timeline heard people talk at once, by the names the Speakers show as now.
    static func together(in result: ProcessedConversation) -> [(start: Double, end: Double, speakers: Set<String>)] {
        var names: [String: String] = [:]
        for speaker in result.speakers { names[speaker.label] = speaker.displayName }
        return (result.together ?? []).map { stretch -> (start: Double, end: Double, speakers: Set<String>) in
            let speakers = Set(stretch.speakers.map { names[$0] ?? $0 })
            return (stretch.start, stretch.end, speakers)
        }
    }

    /// Each word's row, by word number.
    static func rowOfWord(in rows: [TranscriptRow]) -> [Int] {
        var rowOfWord: [Int] = []
        for row in rows {
            for line in row.lines { rowOfWord += [Int](repeating: row.id, count: line.words.count) }
        }
        return rowOfWord
    }

    /// The word each Speaker is saying at `time`, by line, and the row with the one started last, to follow. One word a
    /// Speaker: the last word of a line stays lit a moment after it's said, while their next line may have begun.
    static func playing(at time: Double, in rows: [TranscriptRow]) -> (words: [Int: Int], row: Int?) {
        var low = 0, high = rows.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if rows[middle].start <= time {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let found else { return ([:], nil) }
        var said: [String: (start: Double, line: Int, number: Int, row: Int)] = [:]
        // A row can start a little before the one before it ends.
        for row in rows[max(0, found - 2)...found] where time < row.end + 1.5 {
            for line in row.lines {
                guard let index = TranscriptLine.word(at: time, starts: line.starts) else { continue }
                let start = line.starts[index]
                if let current = said[line.speaker], current.start > start { continue }
                said[line.speaker] = (start, line.id, line.words[index].number, row.id)
            }
        }
        var words: [Int: Int] = [:]
        var latest: (start: Double, row: Int)?
        for word in said.values {
            words[word.line] = word.number
            if let last = latest, last.start > word.start { continue }
            latest = (word.start, word.row)
        }
        return (words, latest?.row)
    }
}

struct NumberedWord {
    let number: Int
    /// The word as transcribed, which its marks point to.
    let word: TranscriptWord
    /// What the word says: the user's correction, or what was transcribed.
    let text: String
    let transcribedSpeaker: String?
    /// The rest of the phrase this word was corrected with, which isn't shown on its own.
    var rest: [NumberedWord] = []

    /// This word with the rest of its phrase, which marks and corrections apply to together.
    var phrase: [NumberedWord] { [self] + rest }
}

/// What the Transcript's words and lines can do, passed down so the rows stay cheap to compare.
struct TranscriptActions {
    /// A click on a word: clears the selection if there is one, and otherwise marks the word or takes its mark off.
    let toggle: (TranscriptWord) -> Void
    let assign: ([NumberedWord], String) -> Void
    let correct: ([TranscriptWord]) -> Void
    let mark: ([TranscriptWord], Bool) -> Void
    let isMarked: (TranscriptWord) -> Bool
    /// The selected words, when the word with this number is one of several selected.
    let selected: (Int) -> [NumberedWord]?
    let toggleSpeaker: (TranscriptLine) -> Void
    let play: (Double) -> Void
    let listened: (Double) -> Void
}

/// The words dragged across, by number, so marks and corrections can apply to a phrase at once.
@Observable
@MainActor
final class WordSelection {
    nonisolated static let space = "transcript"

    var range: ClosedRange<Int>?
    /// The word the drag started on.
    @ObservationIgnored private var anchor: Int?
    /// Where each word is in the Transcript's scrolling content, to tell which word a drag is over.
    @ObservationIgnored var frames: [Int: CGRect] = [:]

    var count: Int { range?.count ?? 0 }

    func drag(from start: CGPoint, to point: CGPoint) {
        guard let anchor = anchor ?? word(at: start) else { return }
        self.anchor = anchor
        guard let end = word(at: point) else { return }
        range = min(anchor, end)...max(anchor, end)
    }

    /// A drag that stayed on one word selects nothing.
    func endDrag() {
        anchor = nil
        if count < 2 { range = nil }
    }

    /// The word under `point`, or the nearest one on its row of words; nil between rows.
    private func word(at point: CGPoint) -> Int? {
        func distance(_ frame: CGRect) -> CGFloat {
            point.x < frame.minX ? frame.minX - point.x : max(0, point.x - frame.maxX)
        }
        return frames.filter { $0.value.minY - 2 <= point.y && point.y <= $0.value.maxY + 2 }
            .min { distance($0.value) < distance($1.value) }?.key
    }
}

struct TranscriptView: View {
    let model: AppModel
    let info: ConversationInfo
    let result: ProcessedConversation
    let playback: PlaybackModel
    @ViewState private var follow = true
    @ViewState private var correcting: WordsToCorrect?
    @ViewState private var selection = WordSelection()
    @ViewState private var finding = false
    @ViewState private var query = ""
    /// Which match Find is on.
    @ViewState private var match = 0
    @FocusState private var typingQuery: Bool

    private struct WordsToCorrect: Identifiable {
        let words: [TranscriptWord]
        var id: Double { words[0].start }
    }

    var body: some View {
        let flags = model.flags[info.id] ?? TranscriptFlags()
        let rows = TranscriptRow.rows(from: result.transcript, flags: flags, together: TranscriptRow.together(in: result))
        let lines = rows.flatMap(\.lines)
        let words = lines.flatMap(\.words)
        let rowOfWord = TranscriptRow.rowOfWord(in: rows)
        let matches = finding ? TranscriptSearch.matches(of: query, in: words.map(\.text)) : []
        let currentMatch = matches.isEmpty ? nil : matches[min(match, matches.count - 1)]
        let selection = self.selection
        let actions = TranscriptActions(
            toggle: { word in
                if selection.range != nil {
                    selection.range = nil
                } else {
                    model.toggleFlag(word, in: info.id)
                }
            },
            assign: { words, speaker in
                model.assign(words.map { ($0.word, $0.transcribedSpeaker) }, to: speaker, in: info.id)
                selection.range = nil
            },
            correct: { correcting = WordsToCorrect(words: $0) },
            mark: { words, wrong in
                model.mark(words, wrong: wrong, in: info.id)
                selection.range = nil
            },
            isMarked: { (model.flags[info.id] ?? TranscriptFlags()).flag(for: $0) != nil },
            selected: { number in
                guard let range = selection.range, range.count > 1, range.contains(number) else { return nil }
                return words.filter { range.contains($0.number) }
            },
            toggleSpeaker: { model.toggleSpeakerFlag(lineStartingAt: $0.start, speaker: $0.speaker, in: info.id) },
            play: { time in
                playback.seek(to: time)
                playback.play()
            },
            listened: { model.noteListened(until: $0, in: info.id) }
        )

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TranscriptHint(selection: selection, hasWords: !words.isEmpty)
                Spacer()
                if !flags.words.isEmpty || !flags.speakers.isEmpty {
                    let corrected = flags.words.filter { $0.correction != nil && $0.phrase == nil }.count
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
                    // With people talking at once, the words don't show in the order they're said.
                    let said = words.indices.sorted { words[$0].word.start < words[$1].word.start }
                    if let index = TranscriptLine.word(at: max(0, playback.time - 0.4), starts: said.map { words[$0].word.start }) {
                        model.toggleFlag(words[said[index]].word, in: info.id)
                    }
                }
                .keyboardShortcut(typingQuery ? nil : KeyboardShortcut("f", modifiers: []))
                .disabled(words.isEmpty || !playback.isLoaded)
                Button {
                    finding = true
                    typingQuery = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Find in the Transcript (⌘F)")
                .disabled(words.isEmpty)
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            Divider()
            if finding {
                findBar(matches: matches.count)
                Divider()
            }
            // Nothing in the Transcript moves while it's read: what separating found waits to be shown.
            if let found = model.separationsFound[info.id] {
                SeparationNote(places: found.places) {
                    selection.range = nil
                    model.mergeSeparation(info.id)
                }
                Divider()
            }
            TranscriptLines(
                rows: rows,
                rowOfWord: rowOfWord,
                flags: flags,
                speakers: result.speakers.map(\.displayName),
                fallback: result.transcript.language == .hebrew ? .rightToLeft : .leftToRight,
                follow: follow,
                playback: playback,
                selection: selection,
                matches: Self.matchesByLine(matches, in: lines),
                currentMatch: currentMatch,
                actions: actions
            )
            PlayerBar(playback: playback, spaceBar: !typingQuery)
        }
        .task(id: info.id) { model.loadFlags(info.id) }
        .onAppear { model.transcriptAppeared(info.id) }
        .onDisappear { model.transcriptDisappeared(info.id) }
        .onChange(of: info.id) { old, new in
            model.transcriptDisappeared(old)
            model.transcriptAppeared(new)
        }
        .onChange(of: query) { match = 0 }
        .sheet(item: $correcting) { item in
            CorrectionSheet(words: item.words, said: Self.correction(of: item.words, in: flags)) { said in
                model.correct(item.words, as: said, in: info.id)
                selection.range = nil
            }
        }
    }

    /// What the sheet starts with: what was typed for these words before, if every one of them has a correction.
    private static func correction(of words: [TranscriptWord], in flags: TranscriptFlags) -> String {
        let corrections = words.map { flags.flag(for: $0)?.correction }
        guard corrections.allSatisfy({ $0 != nil }) else { return "" }
        return corrections.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What to find, how many matches there are and which one is showing, and the way to the others. Return goes to the
    /// next match and Escape closes it, like Find elsewhere.
    private func findBar(matches: Int) -> some View {
        HStack(spacing: 8) {
            TextField("Find in the Transcript", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($typingQuery)
                .onAppear { typingQuery = true }
                .onSubmit { step(1, of: matches) }
                .onExitCommand(perform: closeFind)
            if !query.allSatisfy(\.isWhitespace) {
                Text(matches == 0 ? "Not found" : "\(min(match, matches - 1) + 1) of \(matches)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button { step(-1, of: matches) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous match (⇧⌘G)")
                .disabled(matches == 0)
            Button { step(1, of: matches) } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut("g", modifiers: .command)
                .help("Next match (⌘G)")
                .disabled(matches == 0)
            Spacer()
            Button("Done", action: closeFind)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// Moves to the next match, or with -1 the one before, going around at either end.
    private func step(_ by: Int, of matches: Int) {
        guard matches > 0 else { return }
        match = (min(match, matches - 1) + by + matches) % matches
    }

    private func closeFind() {
        finding = false
        typingQuery = false
    }

    /// The matches in each line, by line, cut to its words; a match that runs on into the next line is in both.
    private static func matchesByLine(_ matches: [ClosedRange<Int>], in lines: [TranscriptLine]) -> [Int: [ClosedRange<Int>]] {
        var byLine: [Int: [ClosedRange<Int>]] = [:]
        var next = 0
        for line in lines {
            guard let first = line.words.first?.number, let last = line.words.last?.number else { continue }
            while next < matches.count, matches[next].upperBound < first { next += 1 }
            var index = next
            while index < matches.count, matches[index].lowerBound <= last {
                byLine[line.id, default: []].append(matches[index].clamped(to: first...last))
                index += 1
            }
        }
        return byLine
    }
}

/// What separating people who talked at once found, waiting for Show while the Transcript is read.
private struct SeparationNote: View {
    let places: Int
    let show: () -> Void

    var body: some View {
        let text = places == 1 ? "Separated 1 place where people talked at once." : "Separated \(places) places where people talked at once."
        HStack {
            Label(text, systemImage: "person.2.wave.2")
            Spacer()
            Button("Show", action: show)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }
}

/// What can be done with the Transcript, or with the words selected; a view of its own, so a drag redraws only this and
/// the lines it changes, not the whole Transcript.
private struct TranscriptHint: View {
    let selection: WordSelection
    let hasWords: Bool

    var body: some View {
        if selection.count > 1 {
            Text("\(selection.count) words selected. Right-click them to say what was said, who said it, or to mark them wrong.")
                .font(.callout)
            Button("Clear Selection") { selection.range = nil }
                .keyboardShortcut(.cancelAction)
        } else {
            Text(hasWords
                 ? "Click a word to mark it wrong, or drag across words to select several. Right-click a word or a speaker to say what was said, or who said it. F marks the word just played, and ⌘F finds words."
                 : "This Transcript has no word timings. Transcribe it again to follow along word by word.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// The lines, redrawn as playback moves; only the lines with a word being said change.
private struct TranscriptLines: View {
    let rows: [TranscriptRow]
    let rowOfWord: [Int]
    let flags: TranscriptFlags
    let speakers: [String]
    /// For a line without letters to tell its direction by.
    let fallback: TextDirection
    let follow: Bool
    let playback: PlaybackModel
    let selection: WordSelection
    /// What Find found, by line.
    let matches: [Int: [ClosedRange<Int>]]
    let currentMatch: ClosedRange<Int>?
    let actions: TranscriptActions

    var body: some View {
        let playing = TranscriptRow.playing(at: playback.time, in: rows)
        let selected = selection.range
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(rows) { row in
                        RowView(row: row, rightToLeft: fallback == .rightToLeft, play: actions.play) { line in
                            LineView(
                                line: line,
                                current: playing.words[line.id],
                                selected: Self.part(of: selected, in: line),
                                matches: matches[line.id] ?? [],
                                currentMatch: Self.part(of: currentMatch, in: line),
                                flags: flags,
                                speakers: speakers,
                                fallback: fallback,
                                selection: selection,
                                actions: actions
                            )
                            .equatable()
                        }
                        .id(row.id)
                    }
                }
                .padding(16)
                .coordinateSpace(.named(WordSelection.space))
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(WordSelection.space))
                        .onChanged {
                            WordTooltip.shared.hide()
                            selection.drag(from: $0.startLocation, to: $0.location)
                        }
                        .onEnded { _ in selection.endDrag() }
                )
            }
            .onChange(of: playing.row) { _, row in
                guard follow, playback.isPlaying, let row else { return }
                withAnimation { proxy.scrollTo(row, anchor: .center) }
            }
            .onChange(of: currentMatch) { _, match in
                guard let match else { return }
                withAnimation { proxy.scrollTo(rowOfWord[match.lowerBound], anchor: .center) }
            }
            // A Source in the Notes or a quote in an answer opens the Transcript already playing, on a line that won't
            // change again for a while.
            .onAppear {
                guard follow, playback.isPlaying else { return }
                Task { @MainActor in
                    if let row = TranscriptRow.playing(at: playback.time, in: rows).row {
                        proxy.scrollTo(row, anchor: .center)
                    }
                }
            }
            .onChange(of: Int(playback.time / 5)) {
                if playback.isPlaying { actions.listened(playback.time) }
            }
        }
    }

    /// The words of `range` that are in the line, by number.
    private static func part(of range: ClosedRange<Int>?, in line: TranscriptLine) -> ClosedRange<Int>? {
        guard let range, let first = line.words.first?.number, let last = line.words.last?.number, range.overlaps(first...last) else { return nil }
        return range.clamped(to: first...last)
    }
}

/// A line on its own, or the lines of people who talked at once, stacked under a label saying so and joined by a bar on
/// the reading side. Words separation added or gave to another Speaker look like any other.
private struct RowView<Line: View>: View {
    let row: TranscriptRow
    let rightToLeft: Bool
    let play: (Double) -> Void
    @ViewBuilder let line: (TranscriptLine) -> Line

    var body: some View {
        if row.lines.count == 1 {
            line(row.lines[0])
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.wave.2")
                    Text("\(row.lines.count) people at once")
                    Button(timestamp(row.atOnce)) { play(row.atOnce) }
                        .buttonStyle(.link)
                        .monospacedDigit()
                        .help("Play from here")
                    if row.separated {
                        Text("· separated automatically")
                            .help("Bekitzur separated these voices; listen to check")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(row.lines) { line($0) }
                    }
                }
                .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
            }
        }
    }
}

private struct LineView: View, @MainActor Equatable {
    let line: TranscriptLine
    let current: Int?
    /// The selected words in this line, by number.
    let selected: ClosedRange<Int>?
    /// What Find found in this line, and the part of it Find is on.
    let matches: [ClosedRange<Int>]
    let currentMatch: ClosedRange<Int>?
    let flags: TranscriptFlags
    let speakers: [String]
    let fallback: TextDirection
    let selection: WordSelection
    let actions: TranscriptActions

    static func == (a: LineView, b: LineView) -> Bool {
        a.line.id == b.line.id && a.line.start == b.line.start && a.line.speaker == b.line.speaker && a.line.text == b.line.text
            && a.current == b.current && a.selected == b.selected && a.matches == b.matches && a.currentMatch == b.currentMatch
            && a.fallback == b.fallback && a.speakers == b.speakers && a.flags.words == b.flags.words && a.flags.speakers == b.flags.speakers
    }

    var body: some View {
        let speakerFlagged = flags.isSpeakerFlagged(lineStartingAt: line.start)
        // A Hebrew Conversation can switch to English, and either can quote the other.
        let texts = line.words.isEmpty ? line.text.split(separator: " ").map(String.init) : line.words.map(\.text)
        let direction = TextDirection.of(texts, fallback: fallback)
        let runs = TextDirection.runs(texts, in: direction)
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
                DirectionalText(line.text, rightToLeft: direction == .rightToLeft)
            } else {
                let layout = FlowLayout(rightToLeft: direction == .rightToLeft)
                layout {
                    ForEach(Array(line.words.enumerated()), id: \.element.number) { position, item in
                        WordView(
                            item: item,
                            isCurrent: item.number == current,
                            isSelected: selected?.contains(item.number) == true,
                            found: currentMatch?.contains(item.number) == true ? .currentMatch
                                : matches.contains { $0.contains(item.number) } ? .match : nil,
                            flag: flags.flag(for: item.word),
                            lineSpeaker: line.speaker,
                            speakers: speakers,
                            rightToLeft: (runs[position] == nil ? direction : direction.opposite) == .rightToLeft,
                            selection: selection,
                            actions: actions
                        )
                        .layoutValue(key: FlowRun.self, value: runs[position])
                    }
                }
                .backgroundPreferenceValue(WordHighlights.self) { highlights in
                    if !highlights.isEmpty {
                        GeometryReader { proxy in
                            ForEach(Highlight.allCases.filter { highlights[$0] != nil }, id: \.self) { highlight in
                                HighlightBands(words: highlights[highlight, default: []].map { proxy[$0] }, spacing: layout.spacing)
                                    .fill(highlight.color)
                            }
                        }
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
    let isSelected: Bool
    /// Found by Find: in a match, or in the one Find is on.
    let found: Highlight?
    let flag: TranscriptFlags.Word?
    let lineSpeaker: String
    let speakers: [String]
    let rightToLeft: Bool
    let selection: WordSelection
    let actions: TranscriptActions

    private var corrected: Bool { flag?.correction != nil }
    /// Part of a correction over several words that gave fewer words than were transcribed.
    private var notSaid: Bool { flag?.correction?.isEmpty == true }
    private var moved: Bool { flag?.saidBy != nil || flag?.otherSpeaker == true }
    private var markedWrong: Bool { flag != nil && !corrected && !moved }
    private var rewritten: Bool { item.word.transcribed != nil && !corrected }

    var body: some View {
        Text(notSaid ? item.word.text : item.text)
            .strikethrough(notSaid)
            .foregroundStyle(notSaid ? .secondary : .primary)
            .underline(flag != nil || rewritten, pattern: flag == nil ? .dot : .solid, color: underline)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
            .contentShape(Rectangle())
            .anchorPreference(key: WordHighlights.self, value: .bounds) { bounds in
                var highlights: [Highlight: [Anchor<CGRect>]] = [:]
                if let found { highlights[found] = [bounds] }
                if isSelected { highlights[.selected] = [bounds] }
                return highlights
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WordSelection.space)) } action: { selection.frames[item.number] = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let pointer):
                    if let tip, selection.range == nil, let size = selection.frames[item.number]?.size {
                        WordTooltip.shared.show(tip, word: item.number, pointer: pointer, size: size)
                    }
                case .ended:
                    WordTooltip.shared.hide(word: item.number)
                }
            }
            .onDisappear { WordTooltip.shared.hide(word: item.number) }
            .onTapGesture {
                WordTooltip.shared.hide()
                actions.toggle(item.word)
            }
            .contextMenu {
                if let group = (isSelected ? actions.selected(item.number) : nil)?.flatMap(\.phrase) {
                    Button("Play from here") { actions.play(group[0].word.start) }
                    let marked = group.allSatisfy { actions.isMarked($0.word) }
                    Button(marked ? "Take the marks off" : "Mark as wrong") { actions.mark(group.map(\.word), !marked) }
                    SaidByMenu(speakers: speakers, current: lineSpeaker) { actions.assign(group, $0) }
                    Button("Type what was said…") { actions.correct(group.map(\.word)) }
                } else {
                    Button("Play from here") { actions.play(item.word.start) }
                    Button(flag == nil ? "Mark as wrong" : "Take the mark off") { actions.toggle(item.word) }
                    SaidByMenu(speakers: speakers, current: lineSpeaker) { actions.assign(item.phrase, $0) }
                    Button("Type what was said…") { actions.correct(item.phrase.map(\.word)) }
                }
            }
    }

    private var underline: Color {
        if corrected { return .green }
        if moved { return .orange }
        if markedWrong { return .red }
        return .secondary
    }

    /// What the fixes took the place of, shown above the word while the pointer is on it: what was transcribed before a
    /// correction or the Vocabulary's spelling, and who it was transcribed as said by.
    private var tip: String? {
        var parts: [String] = []
        if notSaid {
            parts.append("Not said: part of what you typed for the words before it")
        } else if corrected || rewritten {
            parts.append("Transcribed as “\(item.phrase.map { $0.word.transcribed ?? $0.word.text }.joined(separator: " "))”")
        }
        if moved { parts.append("Transcribed as said by \(item.transcribedSpeaker ?? "another speaker")") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The selection and what Find found are drawn behind the line's words, as one band where they sit side by side.
    private var background: Color {
        if isCurrent { return Color.accentColor.opacity(0.35) }
        if markedWrong { return Color.red.opacity(0.15) }
        return .clear
    }
}

/// A word's highlight behind the line, drawn in this order, so the selection shows over what Find found.
private enum Highlight: CaseIterable {
    case match, currentMatch, selected

    var color: Color {
        switch self {
        case .match: Color.yellow.opacity(0.22)
        case .currentMatch: Color.orange.opacity(0.55)
        case .selected: Color.accentColor.opacity(0.2)
        }
    }
}

/// Where a line's highlighted words are, by highlight, to draw the highlights behind them.
private struct WordHighlights: PreferenceKey {
    static var defaultValue: [Highlight: [Anchor<CGRect>]] { [:] }

    static func reduce(value: inout [Highlight: [Anchor<CGRect>]], nextValue: () -> [Highlight: [Anchor<CGRect>]]) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}

/// A line's words with one highlight as one: a band over each run of them that sit side by side on a row. An English run
/// in a Hebrew line can put a word without the highlight between two with it, which then get a band each.
private struct HighlightBands: Shape {
    let words: [CGRect]
    /// The space between words that sit side by side.
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var bands: [CGRect] = []
        for word in words.sorted(by: { ($0.minY, $0.minX) < ($1.minY, $1.minX) }) {
            if let last = bands.last, abs(last.minY - word.minY) < 1, word.minX - last.maxX <= spacing + 1 {
                bands[bands.count - 1] = last.union(word)
            } else {
                bands.append(word)
            }
        }
        var path = Path()
        for band in bands {
            path.addRoundedRect(in: band, cornerSize: CGSize(width: 4, height: 4))
        }
        return path
    }
}

private struct CorrectionSheet: View {
    let words: [TranscriptWord]
    let save: (String) -> Void
    @ViewState private var said: String
    @Environment(\.dismiss) private var dismiss

    init(words: [TranscriptWord], said: String, save: @escaping (String) -> Void) {
        self.words = words
        self.save = save
        _said = ViewState(initialValue: said)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What was said instead of “\(words.map(\.text).joined(separator: " "))”?").font(.headline)
            TextField("What was said", text: $said)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(done)
            if words.count > 1 {
                Text("What you type replaces all of them as one phrase, which a click takes back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
