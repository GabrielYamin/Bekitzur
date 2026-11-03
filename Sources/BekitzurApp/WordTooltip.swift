import AppKit
import SwiftUI

/// What a fix in the Transcript took the place of, in a window of its own just above the word, like a tooltip. Drawn
/// inside the Transcript, it would sit on the words around it and mix with them, and SwiftUI's tooltips don't show on
/// the words at all.
@MainActor
final class WordTooltip {
    static let shared = WordTooltip()

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let content = NSHostingView(rootView: Label(text: ""))
    /// The word the tooltip is for, by number, and what it says, from when the pointer gets to the word.
    private var shown: (word: Int, text: String)?
    private var pending: Task<Void, Never>?

    private init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = content
    }

    /// Shows `text` above the word with this number after a moment, unless the pointer leaves it first. `pointer` is
    /// where the pointer is in the word, measured from its top left; `size` is the word's.
    func show(_ text: String, word: Int, pointer: CGPoint, size: CGSize) {
        guard NSApp.isActive, shown?.word != word || shown?.text != text else { return }
        hide()
        shown = (word, text)
        let mouse = NSEvent.mouseLocation
        // On screen, y goes up.
        let frame = CGRect(x: mouse.x - pointer.x, y: mouse.y + pointer.y - size.height, width: size.width, height: size.height)
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.present(text, above: frame)
        }
    }

    /// Hides the tooltip, or only the one for the word with this number.
    func hide(word: Int? = nil) {
        guard word == nil || word == shown?.word else { return }
        pending?.cancel()
        pending = nil
        shown = nil
        panel.orderOut(nil)
    }

    /// Above the word, or below it when the screen's top is in the way.
    private func present(_ text: String, above word: CGRect) {
        content.rootView = Label(text: text)
        let size = content.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: word.midX, y: word.midY)) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var frame = CGRect(x: word.midX - size.width / 2, y: word.maxY + 4, width: size.width, height: size.height)
        if frame.maxY > visible.maxY { frame.origin.y = word.minY - 4 - size.height }
        frame.origin.x = min(max(frame.minX, visible.minX + 4), visible.maxX - size.width - 4)
        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    private struct Label: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.callout)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}
