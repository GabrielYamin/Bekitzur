import AppKit
import BekitzurDomain
import Carbon.HIToolbox

/// A key combination that works from any app, as a system hot key: watching every key typed instead would need
/// Accessibility permission, which takes an admin on a managed Mac.
@MainActor
final class GlobalShortcut {
    private let id: UInt32
    private var hotKey: EventHotKeyRef?

    /// What each shortcut does, by its id, for the system's handler, which can't hold anything of its own.
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?

    init(id: UInt32, action: @escaping () -> Void) {
        self.id = id
        Self.actions[id] = action
        Self.installHandler()
    }

    /// Replaces the combination it had, if any.
    func register(_ shortcut: KeyShortcut) {
        unregister()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.modifiers(of: shortcut), hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            hotKey = nil
            AppLog.write("Couldn't set \(shortcut.shown) for a quick note: another app may have it (\(status))")
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    /// "BKZR".
    private static let signature: OSType = 0x424B_5A52

    private static func modifiers(of shortcut: KeyShortcut) -> UInt32 {
        var modifiers = 0
        if shortcut.command { modifiers |= cmdKey }
        if shortcut.option { modifiers |= optionKey }
        if shortcut.control { modifiers |= controlKey }
        if shortcut.shift { modifiers |= shiftKey }
        return UInt32(modifiers)
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // The application's event target is handled on the main thread.
            MainActor.assumeIsolated { GlobalShortcut.actions[id]?() }
            return noErr
        }, 1, &pressed, nil, &handler)
    }
}

extension KeyShortcut {
    /// The shortcut a key press makes, with the key as the keyboard shows it; nil for a modifier on its own.
    init?(_ event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers?.uppercased(), !characters.isEmpty else { return nil }
        let flags = event.modifierFlags
        let key = switch Int(event.keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        default: characters
        }
        self.init(
            keyCode: event.keyCode,
            key: key,
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift)
        )
    }
}
