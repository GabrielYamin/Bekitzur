import BekitzurDomain
import SwiftUI

/// A person's initials on their color, the same wherever they show; a Speaker without a name is a dashed circle with
/// its number.
struct PersonAvatar: View {
    let name: String
    var size: CGFloat = 18

    /// Colors white initials read well on, none of them recording's red.
    static let colors: [Color] = [.purple, .green, .pink, .orange, .teal, .blue, .indigo, .brown]

    var body: some View {
        Group {
            if let number = SpeakerLabel.number(in: name) {
                Text(verbatim: "\(number)")
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
            } else {
                Text(verbatim: PersonMark.initials(of: name))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Self.color(of: name), in: Circle())
            }
        }
        .font(.system(size: size * 0.45, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .help(ShownNames.speaker(name))
        .accessibilityLabel(ShownNames.speaker(name))
    }

    static func color(of name: String) -> Color {
        colors[PersonMark.colorIndex(of: name, count: colors.count)]
    }
}

/// A few people's avatars overlapping, for a row without room for their names, and how many more there are.
struct AvatarStack: View {
    let names: [String]
    var size: CGFloat = 16
    var limit = 5

    var body: some View {
        HStack(spacing: 3) {
            HStack(spacing: -size * 0.3) {
                ForEach(Array(names.prefix(limit)), id: \.self) { name in
                    PersonAvatar(name: name, size: size)
                        // A ring cut out of the avatar before it, in whatever color is behind the row.
                        .background(Circle().fill(.black).padding(-2).blendMode(.destinationOut))
                }
            }
            // Composited as one: drawn one by one, a sidebar row blended each avatar with the one under it.
            .compositingGroup()
            if names.count > limit {
                Text(verbatim: "+\(names.count - limit)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
