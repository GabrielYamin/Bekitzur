import BekitzurDomain
import SwiftUI

/// The Conversation along its length under the Transcript: play controls, a lane for each Speaker in their color, each
/// Decision, Action Item, and Open Question above the lanes where it was said, and the user's notes below them where
/// they wrote them. Clicking or dragging along it plays from there, and a mark plays from where it is.
struct PeopleTimeline: View {
    let timeline: ConversationTimeline
    let notes: Notes
    let playback: PlaybackModel
    /// Off while a text field is typed in, which the space bar would otherwise play and pause instead of typing a space.
    var spaceBar = true
    @ViewState private var hovered: TimelineMark?

    private static let inset: CGFloat = 16
    private static let label: CGFloat = 110
    private static let gap: CGFloat = 10
    private static let lane: CGFloat = 20
    private static let marks: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PlayControls(playback: playback, spaceBar: spaceBar)
            HStack(alignment: .top, spacing: Self.gap) {
                labels
                tracks
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .overlay { hoverCard }
        .disabled(!playback.isLoaded)
    }

    /// The hovered mark's item or note, above the timeline over the Transcript, where it hides none of the marks.
    @ViewBuilder
    private var hoverCard: some View {
        if let hovered, let card = card(for: hovered) {
            GeometryReader { geometry in
                let tracks = Self.inset + Self.label + Self.gap
                let scale = TimeScale(length: timeline.length, width: geometry.size.width - tracks - Self.inset)
                let left = min(max(tracks + scale.x(card.at) - 40, 8), max(geometry.size.width - 288, 8))
                TimelineCard(card: card)
                    .frame(width: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, height: 0, alignment: .bottomLeading)
                    .offset(x: left, y: -6)
            }
            .allowsHitTesting(false)
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Self.marks)
            ForEach(timeline.lanes, id: \.speaker) { lane in
                HStack(spacing: 6) {
                    PersonAvatar(name: lane.speaker, size: 16)
                    Text(ShownNames.speaker(lane.speaker)).lineLimit(1)
                }
                .font(.callout)
                .frame(height: Self.lane)
            }
            Color.clear.frame(height: Self.marks)
        }
        .frame(width: Self.label, alignment: .leading)
    }

    private var tracks: some View {
        let height = Self.marks * 2 + Self.lane * CGFloat(timeline.lanes.count)
        return GeometryReader { geometry in
            let scale = TimeScale(length: timeline.length, width: geometry.size.width)
            ZStack(alignment: .topLeading) {
                Seeking(playback: playback, scale: scale)
                ForEach(Array(timeline.lanes.enumerated()), id: \.offset) { index, lane in
                    LaneTrack(lane: lane, length: timeline.length)
                        .frame(height: Self.lane)
                        .offset(y: Self.marks + Self.lane * CGFloat(index))
                        .allowsHitTesting(false)
                }
                // Hovering and clicking go on the mark before it's placed: a placed mark fills the timeline, and so would
                // its hover.
                ForEach(Array(timeline.items.enumerated()), id: \.offset) { index, item in
                    ItemMark(kind: item.kind, active: hovered == .item(index))
                        .onHover { hover(.item(index), $0) }
                        .onTapGesture { play(from: item.at) }
                        .position(x: scale.x(item.at), y: Self.marks / 2)
                }
                ForEach(timeline.yourNotes) { note in
                    NoteMark(active: hovered == .note(note.id))
                        .onHover { hover(.note(note.id), $0) }
                        .onTapGesture { play(from: note.at) }
                        .position(x: scale.x(note.at), y: height - Self.marks / 2)
                }
                Playhead(playback: playback, scale: scale, height: height)
            }
        }
        .frame(height: height)
    }

    private func hover(_ mark: TimelineMark, _ inside: Bool) {
        if inside {
            hovered = mark
        } else if hovered == mark {
            hovered = nil
        }
    }

    private func play(from time: Double) {
        playback.seek(to: time)
        playback.play()
    }

    private func card(for mark: TimelineMark) -> TimelineCard.Content? {
        switch mark {
        case .item(let index):
            guard timeline.items.indices.contains(index) else { return nil }
            return TimelineCard.Content(item: timeline.items[index], in: notes, yourNotes: timeline.yourNotes)
        case .note(let id):
            guard let note = timeline.yourNotes.first(where: { $0.id == id }) else { return nil }
            return TimelineCard.Content(note: note)
        }
    }
}

/// The whole Conversation in one thin bar under the Notes: who spoke when in their colors, a tick for each item, a dot
/// for each of the user's notes, and where playback is. Clicking it plays from there; the button beside it opens the
/// Transcript with the timeline.
struct TimelineRibbon: View {
    let timeline: ConversationTimeline
    let playback: PlaybackModel
    let openTranscript: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PlayButton(playback: playback, size: 26)
            PlaybackTime(playback: playback).font(.caption)
            GeometryReader { geometry in
                let scale = TimeScale(length: timeline.length, width: geometry.size.width)
                ZStack(alignment: .topLeading) {
                    Seeking(playback: playback, scale: scale)
                    ForEach(Array(timeline.items.enumerated()), id: \.offset) { _, item in
                        Capsule().fill(.secondary).frame(width: 2, height: 8).position(x: scale.x(item.at), y: 5)
                    }
                    RibbonBar(timeline: timeline)
                        .frame(height: 8)
                        .offset(y: 12)
                        .allowsHitTesting(false)
                    ForEach(timeline.yourNotes) { note in
                        Circle().fill(.tint).frame(width: 6, height: 6).position(x: scale.x(note.at), y: 27)
                    }
                    Playhead(playback: playback, scale: scale, height: 32)
                }
            }
            .frame(height: 32)
            Button(action: openTranscript) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Listen in the Transcript, with who spoke when")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .disabled(!playback.isLoaded)
    }
}

private enum TimelineMark: Hashable {
    case item(Int)
    case note(UUID)
}

/// Where on a timeline's width a moment falls, and the moment at a point along it.
private struct TimeScale {
    let length: Double
    let width: CGFloat

    func x(_ time: Double) -> CGFloat {
        guard length > 0 else { return 0 }
        return CGFloat(min(max(time / length, 0), 1)) * width
    }

    func time(_ x: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * length
    }
}

/// Clicking or dragging along a timeline moves playback there.
private struct Seeking: View {
    let playback: PlaybackModel
    let scale: TimeScale

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { playback.seek(to: scale.time($0.location.x)) })
    }
}

/// Where playback is, a view of its own so only it moves as playback does.
private struct Playhead: View {
    let playback: PlaybackModel
    let scale: TimeScale
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(.primary)
            .frame(width: 2, height: height)
            .position(x: scale.x(playback.time), y: height / 2)
            .allowsHitTesting(false)
    }
}

private struct PlayButton: View {
    let playback: PlaybackModel
    let size: CGFloat
    var spaceBar = false

    var body: some View {
        Button {
            playback.toggle()
        } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.background)
                .frame(width: size, height: size)
                .background(.primary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(spaceBar ? KeyboardShortcut(.space, modifiers: []) : nil)
        .help(spaceBar ? "Play or pause (space bar)" : "Play or pause")
    }
}

private struct PlaybackTime: View {
    let playback: PlaybackModel

    var body: some View {
        Text(verbatim: "\(timestamp(playback.time)) / \(timestamp(playback.duration))")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

/// Back and forward 15 seconds around play and pause, where playback is, and how fast.
private struct PlayControls: View {
    let playback: PlaybackModel
    let spaceBar: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button { playback.seek(to: playback.time - 15) } label: { Image(systemName: "gobackward.15") }
                .buttonStyle(.borderless)
                .help("Back 15 seconds")
            PlayButton(playback: playback, size: 30, spaceBar: spaceBar)
            Button { playback.seek(to: playback.time + 15) } label: { Image(systemName: "goforward.15") }
                .buttonStyle(.borderless)
                .help("Forward 15 seconds")
            PlaybackTime(playback: playback).font(.callout)
            Spacer()
            Picker("Speed", selection: Binding(get: { playback.rate }, set: { playback.rate = $0 })) {
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Text("\(rate.formatted())×").tag(rate)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// A Speaker's lane: a faint track with their talk on it in their color.
private struct LaneTrack: View {
    let lane: ConversationTimeline.Lane
    let length: Double

    var body: some View {
        Canvas { context, size in
            let top = (size.height - 6) / 2
            context.fill(Path(roundedRect: CGRect(x: 0, y: top, width: size.width, height: 6), cornerRadius: 3), with: .color(.primary.opacity(0.08)))
            for stretch in lane.stretches {
                let rect = Self.rect(stretch, length: length, width: size.width, top: top)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(lane.color))
            }
        }
    }

    static func rect(_ stretch: ClosedRange<Double>, length: Double, width: CGFloat, top: CGFloat) -> CGRect {
        guard length > 0 else { return .zero }
        let start = CGFloat(stretch.lowerBound / length) * width
        let end = CGFloat(stretch.upperBound / length) * width
        return CGRect(x: start, y: top, width: max(end - start, 2), height: 6)
    }
}

/// Every Speaker's talk in one bar, each in their color.
private struct RibbonBar: View {
    let timeline: ConversationTimeline

    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(.primary.opacity(0.08)))
            for lane in timeline.lanes {
                for stretch in lane.stretches {
                    let rect = LaneTrack.rect(stretch, length: timeline.length, width: size.width, top: 0)
                    context.fill(Path(CGRect(x: rect.minX, y: 0, width: rect.width, height: size.height)), with: .color(lane.color))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct ItemMark: View {
    let kind: ConversationTimeline.Kind
    let active: Bool

    var body: some View {
        Image(systemName: Self.symbol(kind))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(active ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
            .frame(width: 16, height: 16)
            .background(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.background), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: active ? 0 : 1))
            .contentShape(Rectangle())
    }

    static func symbol(_ kind: ConversationTimeline.Kind) -> String {
        switch kind {
        case .decision: "checkmark.seal"
        case .actionItem: "checkmark"
        case .openQuestion: "questionmark"
        }
    }
}

private struct NoteMark: View {
    let active: Bool

    var body: some View {
        Image(systemName: "pencil")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            .frame(width: 16, height: 16)
            .background(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.18)), in: Circle())
            .contentShape(Circle())
    }
}

/// What a mark on the timeline is: an item with its kind, time, and details, and the note of the user's that made it
/// or adds to it; or one of the user's notes.
private struct TimelineCard: View {
    struct Content {
        let at: Double
        let title: String
        let text: String
        var detail: String?
        var note: UserNote?

        init(item: ConversationTimeline.Item, in notes: Notes, yourNotes: [UserNote]) {
            at = item.at
            var linked: [UUID] = []
            switch item.kind {
            case .decision:
                let decision = notes.decisions[item.index]
                title = String(localized: "Decision · \(timestamp(item.at))")
                text = decision.text
                linked = [decision.fromYourNote].compactMap { $0 } + (decision.withYourNotes ?? [])
            case .actionItem:
                let action = notes.actionItems[item.index]
                title = String(localized: "Action Item · \(timestamp(item.at))")
                text = action.text
                let owner = action.owner.map(ShownNames.speaker) ?? String(localized: "No Owner")
                detail = [owner, NotesMarkdown.dueText(action)].compactMap { $0 }.joined(separator: " · ")
                linked = [action.fromYourNote].compactMap { $0 } + (action.withYourNotes ?? [])
            case .openQuestion:
                let question = notes.openQuestions[item.index]
                title = String(localized: "Open Question · \(timestamp(item.at))")
                text = question.text
                linked = [question.fromYourNote].compactMap { $0 } + (question.withYourNotes ?? [])
            }
            note = linked.lazy.compactMap { id in yourNotes.first { $0.id == id } }.first
        }

        init(note: UserNote) {
            at = note.at
            title = String(localized: "Your note · \(timestamp(note.at))")
            text = note.words
        }
    }

    let card: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.title)
                .font(.system(size: 10.5, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            DirectionalText(card.text)
                .font(.callout.weight(.medium))
                .lineLimit(3)
            if let detail = card.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if let note = card.note {
                Divider().padding(.vertical, 3)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "pencil")
                    Text(timestamp(note.at)).monospacedDigit()
                    DirectionalText(note.words).foregroundStyle(.secondary).lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.tint)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

extension ConversationTimeline.Lane {
    /// Their avatar's color; gray for a Speaker without a name, whose avatar has none.
    var color: Color {
        SpeakerLabel.number(in: speaker) == nil ? PersonAvatar.color(of: speaker) : .gray
    }
}
