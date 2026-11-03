import SwiftUI

// The menu bar's panel had no hover effect at all, so nothing in it looked clickable until it was clicked.

/// A row of the menu bar's panel, lit up under the pointer like a menu item, across the panel and without moving its text.
struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering && isEnabled ? 0.08 : 0))
                        .padding(.horizontal, -6)
                        .padding(.vertical, -3)
                }
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// Lights a system button up under the pointer, which buttons in the panel don't do on their own.
private struct HoverLight: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    func body(content: Content) -> some View {
        content
            .brightness(hovering && isEnabled ? 0.08 : 0)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLight() -> some View {
        modifier(HoverLight())
    }
}
