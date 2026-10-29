import BekitzurDomain
import SwiftUI

/// Lays views out in lines like words in a paragraph, wrapping at the container's width.
///
/// Right-to-left lines are placed from the right edge here rather than by SwiftUI's mirroring, so put the layout in a
/// left-to-right environment and set each word's own direction. Words that share a `FlowRun` read in the other
/// direction, so an English phrase in a Hebrew line keeps its order; lines are broken first, so a run that wraps goes on
/// where it stopped.
struct FlowLayout: Layout {
    var rightToLeft = false
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var widest: CGFloat = 0, height: CGFloat = 0
        for (number, line) in Self.lines(sizes.map(\.width), width: proposal.width ?? .infinity, spacing: spacing).enumerated() {
            var width: CGFloat = 0, lineHeight: CGFloat = 0
            for index in line {
                width += sizes[index].width
                lineHeight = max(lineHeight, sizes[index].height)
            }
            widest = max(widest, width + spacing * CGFloat(line.count - 1))
            height += lineHeight + (number > 0 ? lineSpacing : 0)
        }
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y: CGFloat = 0
        for line in Self.lines(sizes.map(\.width), width: bounds.width, spacing: spacing) {
            var x: CGFloat = 0
            for position in TextDirection.placement(line.map { subviews[$0][FlowRun.self] }) {
                let index = line[position], size = sizes[index]
                let left = rightToLeft ? bounds.maxX - x - size.width : bounds.minX + x
                subviews[index].place(at: CGPoint(x: left, y: bounds.minY + y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += (line.map { sizes[$0].height }.max() ?? 0) + lineSpacing
        }
    }

    /// The views on each line, by index, in order.
    static func lines(_ widths: [CGFloat], width: CGFloat, spacing: CGFloat) -> [[Int]] {
        var lines: [[Int]] = [], line: [Int] = [], x: CGFloat = 0
        for (index, viewWidth) in widths.enumerated() {
            if !line.isEmpty, x + viewWidth > width {
                lines.append(line)
                line = []
                x = 0
            }
            line.append(index)
            x += viewWidth + spacing
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}

/// The run of words in the other direction that a word belongs to, from `TextDirection.runs`; nil when it follows the
/// line.
struct FlowRun: LayoutValueKey {
    static let defaultValue: Int? = nil
}
