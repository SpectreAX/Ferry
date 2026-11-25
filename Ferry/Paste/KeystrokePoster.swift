import CoreGraphics

/// Posts a synthetic paste keystroke (⌘V, or ⌃V for terminals later) to the focused app. Each event carries
/// `PasteEventTap.syntheticMarker` so Ferry's own tap lets it through, and uses a private event source so
/// modifier keys the user is still holding can't turn it into ⌘⇧V or similar. Never posts Return.
enum KeystrokePoster {
    static let keyV: CGKeyCode = 9

    @discardableResult
    static func postPaste(flags: CGEventFlags = .maskCommand) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: PasteEventTap.syntheticMarker)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
