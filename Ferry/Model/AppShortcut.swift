import AppKit
import SwiftUI

/// A user-configurable keyboard shortcut stored as a compact string in `UserDefaults`.
/// Supports IME-safe ANSI `keyCode` parsing, Apple-order formatting, SwiftUI `KeyboardShortcut`
/// conversion, and conflict validation against reserved system/Ferry shortcuts.
struct AppShortcut: Equatable, Hashable {
    struct Modifiers: OptionSet, Equatable, Hashable {
        let rawValue: Int

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        var eventModifiers: EventModifiers {
            var result: EventModifiers = []
            if contains(.control) { result.insert(.control) }
            if contains(.option) { result.insert(.option) }
            if contains(.shift) { result.insert(.shift) }
            if contains(.command) { result.insert(.command) }
            return result
        }

        var nsEventFlags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if contains(.control) { flags.insert(.control) }
            if contains(.option) { flags.insert(.option) }
            if contains(.shift) { flags.insert(.shift) }
            if contains(.command) { flags.insert(.command) }
            return flags
        }

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        init(nsEventFlags: NSEvent.ModifierFlags) {
            var result: Modifiers = []
            let relevant = nsEventFlags.intersection([.control, .option, .shift, .command])
            if relevant.contains(.control) { result.insert(.control) }
            if relevant.contains(.option) { result.insert(.option) }
            if relevant.contains(.shift) { result.insert(.shift) }
            if relevant.contains(.command) { result.insert(.command) }
            self = result
        }
    }

    enum ValidationResult: Equatable {
        case valid(AppShortcut)
        case missingModifier
        case reserved
        case duplicate
    }

    let key: String
    let modifiers: Modifiers

    init(key: String, modifiers: Modifiers) {
        self.key = Self.normalizeKey(key) ?? key.lowercased()
        self.modifiers = modifiers
    }

    // Defaults chosen to avoid macOS, Raycast, Snipaste, WeChat/QQ, and Ferry's existing ⌥⌘C.
    static let defaultHideMarkdown = AppShortcut(key: "/", modifiers: [.command, .option])
    static let defaultStripMarkdownOnCopy = AppShortcut(key: "c", modifiers: [.command, .option, .shift])

    /// Shortcuts used by macOS or core Ferry actions that cannot be overridden.
    static let reservedShortcuts: Set<AppShortcut> = [
        AppShortcut(key: "c", modifiers: .command),
        AppShortcut(key: "v", modifiers: .command),
        AppShortcut(key: "x", modifiers: .command),
        AppShortcut(key: "z", modifiers: .command),
        AppShortcut(key: "z", modifiers: [.command, .shift]),
        AppShortcut(key: "a", modifiers: .command),
        AppShortcut(key: "s", modifiers: .command),
        AppShortcut(key: "o", modifiers: .command),
        AppShortcut(key: "n", modifiers: .command),
        AppShortcut(key: "w", modifiers: .command),
        AppShortcut(key: "q", modifiers: .command),
        AppShortcut(key: "h", modifiers: .command),
        AppShortcut(key: "h", modifiers: [.command, .option]),
        AppShortcut(key: "m", modifiers: .command),
        AppShortcut(key: "m", modifiers: [.command, .option]),
        AppShortcut(key: ",", modifiers: .command),
        AppShortcut(key: "f", modifiers: .command),
        AppShortcut(key: "g", modifiers: .command),
        AppShortcut(key: "g", modifiers: [.command, .shift]),
        AppShortcut(key: "c", modifiers: [.command, .option]), // Copy as Plain Markdown
        AppShortcut(key: "b", modifiers: .command), // Bold
        AppShortcut(key: "i", modifiers: .command), // Italic
        AppShortcut(key: "k", modifiers: .command), // Insert Link
        AppShortcut(key: "=", modifiers: .command), // Bigger
        AppShortcut(key: "+", modifiers: .command),
        AppShortcut(key: "=", modifiers: [.command, .shift]),
        AppShortcut(key: "-", modifiers: .command), // Smaller
        AppShortcut(key: "0", modifiers: .command), // Actual Size
        AppShortcut(key: "t", modifiers: .command), // New Tab
        AppShortcut(key: "w", modifiers: [.command, .shift]), // Close Window
        AppShortcut(key: "s", modifiers: [.command, .shift]), // Save As
        AppShortcut(key: "[", modifiers: [.command, .shift]), // Show Previous Tab
        AppShortcut(key: "]", modifiers: [.command, .shift]), // Show Next Tab
        AppShortcut(key: "tab", modifiers: .control),
        AppShortcut(key: "tab", modifiers: [.control, .shift]),
        AppShortcut(key: "1", modifiers: .command), AppShortcut(key: "2", modifiers: .command),
        AppShortcut(key: "3", modifiers: .command), AppShortcut(key: "4", modifiers: .command),
        AppShortcut(key: "5", modifiers: .command), AppShortcut(key: "6", modifiers: .command),
        AppShortcut(key: "7", modifiers: .command), AppShortcut(key: "8", modifiers: .command),
        AppShortcut(key: "9", modifiers: .command),
    ]

    // MARK: Serialization

    var storageString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("control") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("command") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    static func encode(_ shortcut: AppShortcut?) -> String {
        shortcut?.storageString ?? ""
    }

    /// Decodes a stored shortcut string:
    /// - `nil` returns `fallback`
    /// - `""` returns `nil` (explicitly cleared)
    /// - malformed strings fall back to `fallback`
    static func decode(_ stored: String?, default fallback: AppShortcut) -> AppShortcut? {
        guard let stored else { return fallback }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return parse(storageString: trimmed) ?? fallback
    }

    private static func parse(storageString: String) -> AppShortcut? {
        let parts = storageString.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let rawKey = parts.last, let normalizedKey = normalizeKey(rawKey) else { return nil }
        var modifiers: Modifiers = []
        for token in parts.dropLast() {
            switch token.lowercased() {
            case "control", "ctrl": modifiers.insert(.control)
            case "option", "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "command", "cmd": modifiers.insert(.command)
            default: return nil
            }
        }
        guard !modifiers.isDisjoint(with: [.command, .control]) else { return nil }
        let shortcut = AppShortcut(key: normalizedKey, modifiers: modifiers)
        return shortcut
    }

    // MARK: Display & SwiftUI

    var displayString: String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        return prefix + Self.displayKey(key)
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard let equivalent = Self.keyEquivalent(for: key) else { return nil }
        return KeyboardShortcut(equivalent, modifiers: modifiers.eventModifiers)
    }

    private static func displayKey(_ key: String) -> String {
        switch key {
        case "space": return "Space"
        case "return": return "↩"
        case "tab": return "⇥"
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        default: return key.count == 1 ? key.uppercased() : key
        }
    }

    private static func keyEquivalent(for key: String) -> KeyEquivalent? {
        switch key {
        case "space": return .space
        case "return": return .return
        case "tab": return .tab
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        default:
            guard key.count == 1, let char = key.first else { return nil }
            return KeyEquivalent(char)
        }
    }

    // MARK: Event Parsing & Validation

    static func from(event: NSEvent) -> AppShortcut? {
        guard event.type == .keyDown else { return nil }
        let modifiers = Modifiers(nsEventFlags: event.modifierFlags)
        if let mapped = keyFromVirtualKeyCode(event.keyCode) {
            return AppShortcut(key: mapped, modifiers: modifiers)
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let normalized = normalizeKey(chars) else { return nil }
        return AppShortcut(key: normalized, modifiers: modifiers)
    }

    static func validate(_ shortcut: AppShortcut, conflictingWith other: AppShortcut?) -> ValidationResult {
        guard !shortcut.modifiers.isDisjoint(with: [.command, .control]) else {
            return .missingModifier
        }
        if reservedShortcuts.contains(shortcut) {
            return .reserved
        }
        if other == shortcut {
            return .duplicate
        }
        return .valid(shortcut)
    }

    private static func normalizeKey(_ raw: String) -> String? {
        let lower = raw.lowercased()
        switch lower {
        case " ", "space": return "space"
        case "\r", "\n", "return": return "return"
        case "\t", "tab": return "tab"
        case "up", "down", "left", "right": return lower
        default:
            guard lower.count == 1, let scalar = lower.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar),
                  scalar.value >= 0x21 && scalar.value < 0x7F else { return nil }
            return lower
        }
    }

    /// Maps ANSI virtual key codes directly so Chinese/Japanese IME or Option+Key never skews recording.
    private static func keyFromVirtualKeyCode(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 0x00: return "a"
        case 0x0B: return "b"
        case 0x08: return "c"
        case 0x02: return "d"
        case 0x0E: return "e"
        case 0x03: return "f"
        case 0x05: return "g"
        case 0x04: return "h"
        case 0x22: return "i"
        case 0x26: return "j"
        case 0x28: return "k"
        case 0x25: return "l"
        case 0x2E: return "m"
        case 0x2D: return "n"
        case 0x1F: return "o"
        case 0x23: return "p"
        case 0x0C: return "q"
        case 0x0F: return "r"
        case 0x01: return "s"
        case 0x11: return "t"
        case 0x20: return "u"
        case 0x09: return "v"
        case 0x0D: return "w"
        case 0x07: return "x"
        case 0x10: return "y"
        case 0x06: return "z"
        case 0x1D: return "0"
        case 0x12: return "1"
        case 0x13: return "2"
        case 0x14: return "3"
        case 0x15: return "4"
        case 0x17: return "5"
        case 0x16: return "6"
        case 0x1A: return "7"
        case 0x1C: return "8"
        case 0x19: return "9"
        case 0x1B: return "-"
        case 0x18: return "="
        case 0x21: return "["
        case 0x1E: return "]"
        case 0x2A: return "\\"
        case 0x29: return ";"
        case 0x27: return "'"
        case 0x2B: return ","
        case 0x2F: return "."
        case 0x2C: return "/"
        case 0x32: return "`"
        case 0x31: return "space"
        case 0x24: return "return"
        case 0x30: return "tab"
        case 0x7E: return "up"
        case 0x7D: return "down"
        case 0x7B: return "left"
        case 0x7C: return "right"
        default: return nil
        }
    }
}
