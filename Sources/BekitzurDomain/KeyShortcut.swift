import Foundation

/// A key with the modifiers held for it, like ⌥⌘N.
public struct KeyShortcut: Codable, Equatable, Sendable {
    /// The key's virtual key code, which stays the same whatever the keyboard's layout.
    public var keyCode: UInt16
    /// What the key shows as, like "N".
    public var key: String
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(keyCode: UInt16, key: String, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode
        self.key = key
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    /// For a note at this moment, from any app.
    public static let quickNote = KeyShortcut(keyCode: 45, key: "N", command: true, option: true)

    /// The modifiers in the order menus show them, then the key, like "⌃⌥⇧⌘N".
    public var shown: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key
    }

    /// One that isn't typed in passing: with ⌘, ⌥, or ⌃.
    public var isUsable: Bool {
        command || option || control
    }
}
