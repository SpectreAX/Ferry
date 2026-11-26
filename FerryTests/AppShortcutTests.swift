import AppKit
import SwiftUI
import XCTest
@testable import Ferry

final class AppShortcutTests: XCTestCase {
    func testDefaultShortcutsAreValidDistinctAndFormatted() {
        let hide = AppShortcut.defaultHideMarkdown
        let strip = AppShortcut.defaultStripMarkdownOnCopy

        XCTAssertEqual(hide.displayString, "⌥⌘/")
        XCTAssertEqual(strip.displayString, "⌥⇧⌘C")
        XCTAssertNotEqual(hide, strip)
        XCTAssertNotNil(hide.keyboardShortcut)
        XCTAssertNotNil(strip.keyboardShortcut)

        XCTAssertEqual(AppShortcut.validate(hide, conflictingWith: strip), .valid(hide))
        XCTAssertEqual(AppShortcut.validate(strip, conflictingWith: hide), .valid(strip))
    }

    func testStorageEncodeDecodeRoundTrip() {
        XCTAssertEqual(AppShortcut.decode(nil, default: .defaultHideMarkdown), .defaultHideMarkdown)
        XCTAssertNil(AppShortcut.decode("", default: .defaultHideMarkdown))
        XCTAssertNil(AppShortcut.decode("   ", default: .defaultStripMarkdownOnCopy))
        XCTAssertEqual(AppShortcut.decode("not-a-valid-shortcut", default: .defaultHideMarkdown), .defaultHideMarkdown)
        XCTAssertEqual(AppShortcut.decode("shift+m", default: .defaultHideMarkdown), .defaultHideMarkdown)

        let custom = AppShortcut(key: "k", modifiers: [.control, .option, .command])
        let encoded = AppShortcut.encode(custom)
        XCTAssertEqual(encoded, "control+option+command+k")
        XCTAssertEqual(AppShortcut.decode(encoded, default: .defaultHideMarkdown), custom)
        XCTAssertEqual(custom.displayString, "⌃⌥⌘K")
        XCTAssertEqual(AppShortcut.encode(nil), "")
    }

    func testValidationRejectsMissingModifiersReservedAndDuplicates() {
        XCTAssertEqual(AppShortcut.validate(AppShortcut(key: "m", modifiers: []), conflictingWith: nil), .missingModifier)
        XCTAssertEqual(AppShortcut.validate(AppShortcut(key: "m", modifiers: [.shift]), conflictingWith: nil), .missingModifier)
        XCTAssertEqual(AppShortcut.validate(AppShortcut(key: "m", modifiers: [.option]), conflictingWith: nil), .missingModifier)
        XCTAssertEqual(AppShortcut.validate(AppShortcut(key: "m", modifiers: [.option, .shift]), conflictingWith: nil), .missingModifier)

        for reserved in [
            AppShortcut(key: "c", modifiers: .command),
            AppShortcut(key: "c", modifiers: [.command, .option]),
            AppShortcut(key: "m", modifiers: .command),
            AppShortcut(key: "m", modifiers: [.command, .option]),
            AppShortcut(key: "s", modifiers: .command),
        ] {
            XCTAssertEqual(AppShortcut.validate(reserved, conflictingWith: nil), .reserved)
        }

        let validControl = AppShortcut(key: "m", modifiers: [.control, .shift])
        XCTAssertEqual(AppShortcut.validate(validControl, conflictingWith: validControl), .duplicate)
        XCTAssertEqual(AppShortcut.validate(validControl, conflictingWith: .defaultHideMarkdown), .valid(validControl))
    }

    func testSpecialKeysFormatAndConvertToKeyboardShortcut() {
        for key in ["space", "return", "tab", "up", "down", "left", "right", "/"] {
            let shortcut = AppShortcut(key: key, modifiers: [.command, .shift])
            XCTAssertNotNil(shortcut.keyboardShortcut, "expected KeyboardShortcut for \(key)")
            XCTAssertFalse(shortcut.displayString.isEmpty)
        }
    }

    func testNSEventParsingUsesVirtualKeyCodeSafely() throws {
        // Keycode 0x08 is 'c'; even if charactersIgnoringModifiers were transformed by Option/IME,
        // virtual keycode resolves cleanly to "c".
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .option, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "Ç",
                charactersIgnoringModifiers: "Ç",
                isARepeat: false,
                keyCode: 0x08
            )
        )
        let parsed = AppShortcut.from(event: event)
        XCTAssertEqual(parsed, AppShortcut.defaultStripMarkdownOnCopy)

        // Keycode 0x2C is '/'
        let slashEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .option],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "÷",
                charactersIgnoringModifiers: "/",
                isARepeat: false,
                keyCode: 0x2C
            )
        )
        XCTAssertEqual(AppShortcut.from(event: slashEvent), AppShortcut.defaultHideMarkdown)
    }
}
