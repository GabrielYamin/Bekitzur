import AppKit
import BekitzurDomain
import SwiftUI

/// A window floating over every app and Space, even one in full screen, that leaves the app in front where it is:
/// the pill, and the quick note, which takes typing without bringing Bekitzur forward. Screen sharing leaves it out
/// where the system lets it.
private final class FloatingPanel: NSPanel {
    private let takesKeys: Bool

    init(takesKeys: Bool) {
        self.takesKeys = takesKeys
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        sharingType = .none
    }

    override var canBecomeKey: Bool { takesKeys }
    override var canBecomeMain: Bool { false }
}

/// While recording, a small pill over every app with the time, the microphone's and the Mac's levels, a pen for a quick
/// note, and Stop. Dragged anywhere, it stays there for the next recording.
@MainActor
final class RecordingPill {
    private let panel = FloatingPanel(takesKeys: false)
    /// Where the pointer and the pill were when a drag began, on screen.
    private var dragStart: (pointer: CGPoint, origin: CGPoint)?

    init(model: AppModel) {
        let host = NSHostingController(rootView: PillView(model: model) { [weak self] ended in self?.drag(ended: ended) })
        // As wide as the time, which gains a digit after an hour.
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.setFrameAutosaveName("RecordingPill")
    }

    var frame: CGRect? { panel.isVisible ? panel.frame : nil }

    func show() {
        guard !panel.isVisible else { return }
        if !panel.setFrameUsingName("RecordingPill") {
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            let size = panel.contentViewController?.view.fittingSize ?? .zero
            panel.setFrameTopLeftPoint(CGPoint(x: visible.maxX - size.width - 24, y: visible.maxY - 16))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        dragStart = nil
    }

    /// Follows the pointer on screen rather than in the pill, which moves along with it.
    private func drag(ended: Bool) {
        let pointer = NSEvent.mouseLocation
        if ended {
            dragStart = nil
            return
        }
        let start = dragStart ?? (pointer, panel.frame.origin)
        dragStart = start
        panel.setFrameOrigin(CGPoint(x: start.origin.x + pointer.x - start.pointer.x, y: start.origin.y + pointer.y - start.pointer.y))
    }
}

/// A note at this moment, from any app: under the pill, or with the pill off under Bekitzur's icon in the menu bar.
/// Return adds it and Escape closes it, leaving the app in front where it was.
@MainActor
final class QuickNotePanel {
    private let panel = FloatingPanel(takesKeys: true)
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var isOpen: Bool { panel.isVisible }

    /// - Parameters:
    ///   - at: Seconds into the recording, the moment the note is for.
    ///   - below: The pill's frame, when it's showing.
    func open(at time: Double, below pill: CGRect?) {
        let view = NSHostingView(rootView: QuickNoteView(model: model, at: time) { [weak self] in self?.close() })
        panel.contentView = view
        let size = view.fittingSize
        let anchor = pill ?? Self.menuBarIcon() ?? Self.topRight(width: size.width)
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(anchor.minX, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrame(CGRect(x: x, y: anchor.minY - 8 - size.height, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// Where Bekitzur's icon is in the menu bar: the window the system gives the status item.
    private static func menuBarIcon() -> CGRect? {
        NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") && $0.isVisible }?.frame
    }

    private static func topRight(width: CGFloat) -> CGRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return CGRect(x: visible.maxX - width - 16, y: visible.maxY, width: width, height: 0)
    }
}

private struct PillView: View {
    let model: AppModel
    /// Moves the pill with the pointer; true once the drag ends.
    let drag: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.showMainWindow(selecting: model.recordingID)
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    if let startedAt = model.recordingStartedAt {
                        RecordingTimer(since: startedAt).font(.system(size: 12.5, weight: .semibold))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the recording in Bekitzur")
            microphone
            LevelBars(symbol: "speaker.wave.2.fill", levels: model.levels.systemAudio)
            buttons
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(height: 40)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in drag(false) }
                .onEnded { _ in drag(true) }
        )
        .help("Drag to move it")
        .padding(1)
        .fixedSize()
    }

    /// The microphone's levels, or while it sends nothing, a warning that opens the recording to switch microphones.
    @ViewBuilder
    private var microphone: some View {
        if let silent = model.silentMicrophone {
            Button {
                model.showMainWindow(selecting: model.recordingID)
            } label: {
                Label("No sound", systemImage: "mic.slash.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("No sound is coming from \(silent). Click to choose another microphone.")
        } else {
            LevelBars(symbol: "mic.fill", levels: model.levels.microphone)
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button {
                model.openQuickNote()
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.tint, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Add a note at this moment (\(model.quickNoteShortcut.shown))")
            Button {
                model.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.red, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop recording and write the Notes")
        }
    }
}

/// The note field pinned to the moment it opened, with the notes written earlier in the recording.
private struct QuickNoteView: View {
    let model: AppModel
    let at: Double
    let close: () -> Void
    @ViewState private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let earlier = model.recordingID.flatMap { model.yourNotes[$0] }?.filter { !$0.words.isEmpty } ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pencil").foregroundStyle(.tint)
                Text("Note at \(timestamp(at))")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            TextField("Note", text: $text, prompt: Text("What's worth remembering"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3, reservesSpace: true)
                .focused($focused)
                .onSubmit(add)
            HStack(spacing: 10) {
                Text("↩ Add")
                Text("esc Close")
                Spacer()
                Text("\(model.quickNoteShortcut.shown) from any app")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            if !earlier.isEmpty {
                Divider().padding(.vertical, 2)
                Text("Earlier in this recording")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                ForEach(earlier.suffix(4)) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(timestamp(note.at)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        DirectionalText(note.words).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .padding(1)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focused = true }
        .onExitCommand(perform: close)
    }

    private func add() {
        model.addQuickNote(text, at: at)
        close()
    }
}
