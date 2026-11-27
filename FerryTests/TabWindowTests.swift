import XCTest
@testable import Ferry

/// Documents as tabs of one window: the window follows the shown tab, every tab keeps its own editor and undo.
final class TabWindowTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTempDirectory(self, name: "Docs")
    }

    private func document(_ name: String, _ markdown: String) throws -> FerryDocument {
        let url = dir.appendingPathComponent(name)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let document = try FerryDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
        addTeardownBlock { if document.tabWindowController != nil { document.close() } }
        return document
    }

    private func window(_ documents: FerryDocument...) -> TabWindowController {
        let controller = TabWindowController()
        for document in documents { controller.addTab(for: document) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        addTeardownBlock { controller.window?.close() }
        return controller
    }

    private func editor(_ controller: TabWindowController, _ document: FerryDocument) throws -> EditorTextView {
        let session = try XCTUnwrap(controller.sessions[document.id])
        session.host.layoutSubtreeIfNeeded()
        return try XCTUnwrap(session.editor)
    }

    func testTheWindowFollowsTheShownTab() throws {
        let first = try document("First.md", "# One"), second = try document("Second.md", "# Two")
        let controller = window(first, second)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.strip.showsTabBar)
        XCTAssertTrue(NSDocumentController.shared.document(for: window) === second)
        XCTAssertEqual(window.title, "Second.md")
        XCTAssertEqual(window.representedURL?.lastPathComponent, "Second.md")
        XCTAssertEqual(controller.bar.items.map(\.title), ["First.md", "Second.md"])

        controller.select(first.id)
        XCTAssertTrue(controller.document === first)
        XCTAssertEqual(window.title, "First.md")
        XCTAssertFalse(controller.sessions[first.id]!.host.isHidden)
        XCTAssertTrue(controller.sessions[second.id]!.host.isHidden)
    }

    func testEachTabKeepsItsEditorSelectionAndUndo() throws {
        let first = try document("First.md", "Hello world"), second = try document("Second.md", "Other")
        let controller = window(first, second)
        let firstEditor = try editor(controller, first), secondEditor = try editor(controller, second)
        XCTAssertTrue(firstEditor.undoManager === first.undoManager, "the editor uses its own document's undo history")
        XCTAssertTrue(secondEditor.undoManager === second.undoManager)
        XCTAssertTrue(firstEditor.owningDocument === first)

        controller.select(first.id)
        firstEditor.setSelectedRange(NSRange(location: 6, length: 5))
        controller.select(second.id)
        controller.select(first.id)
        XCTAssertTrue(try editor(controller, first) === firstEditor, "the same editor, kept alive")
        XCTAssertEqual(firstEditor.selectedRange(), NSRange(location: 6, length: 5))
    }

    func testEditsMarkOnlyTheirDocument() throws {
        let first = try document("First.md", "a"), second = try document("Second.md", "b")
        let controller = window(first, second)
        controller.select(first.id)
        first.updateChangeCount(.changeDone)
        XCTAssertTrue(controller.bar.items.first { $0.id == first.id }!.edited)
        XCTAssertFalse(controller.bar.items.first { $0.id == second.id }!.edited)
        XCTAssertTrue(controller.window!.isDocumentEdited)
        controller.select(second.id)
        XCTAssertFalse(controller.window!.isDocumentEdited, "the window shows the shown tab's state")
        first.updateChangeCount(.changeCleared)
    }

    func testClosingTabsBackToOne() throws {
        let first = try document("First.md", "a"), second = try document("Second.md", "b")
        let controller = window(first, second)
        second.close()
        XCTAssertFalse(controller.strip.showsTabBar)
        XCTAssertNil(controller.sessions[second.id])
        XCTAssertTrue(controller.document === first, "the remaining document is untouched")
        XCTAssertNotNil(controller.sessions[first.id]?.host.superview)
        XCTAssertEqual(controller.bar.items.map(\.title), ["First.md"])
    }

    func testMoveTabToNewWindowKeepsItsEditor() throws {
        let first = try document("First.md", "a"), second = try document("Second.md", "b")
        let controller = window(first, second)
        let secondEditor = try editor(controller, second)
        controller.moveTabToNewWindow(second.id)
        let other = try XCTUnwrap(second.tabWindowController)
        addTeardownBlock { other.window?.close() }
        XCTAssertFalse(other === controller)
        XCTAssertTrue(try editor(other, second) === secondEditor)
        XCTAssertEqual(secondEditor.string, "b")
        XCTAssertEqual(controller.strip.tabs, [first.id])
        controller.moveTabToNewWindow(first.id)
        XCTAssertTrue(first.tabWindowController === controller, "the only tab stays where it is")
    }

    func testRevertShowsTheFileAgain() throws {
        let first = try document("First.md", "Saved text")
        let controller = window(first)
        first.model.markdown = "Unsaved text"
        try first.revert(toContentsOf: first.fileURL!, ofType: first.fileType!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(try editor(controller, first).string, "Saved text")
    }

    // MARK: Keys and the front window

    private func key(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    func testNumberKeysAndControlTabSwitchTabs() throws {
        let first = try document("First.md", "a"), second = try document("Second.md", "b"), third = try document("Third.md", "c")
        let controller = window(first, second, third)
        XCTAssertTrue(controller.handleTabKey(key(0x12, .command, characters: "&")), "⌘1 by key position (AZERTY types &)")
        XCTAssertTrue(controller.document === first)
        XCTAssertTrue(controller.handleTabKey(key(0x19, .command, characters: "9")))
        XCTAssertTrue(controller.document === third, "⌘9: the last tab")
        XCTAssertTrue(controller.handleTabKey(key(0x13, .command, characters: "2")))
        XCTAssertTrue(controller.document === second)
        XCTAssertTrue(controller.handleTabKey(key(48, .control, characters: "\t")))
        XCTAssertTrue(controller.document === third)
        XCTAssertTrue(controller.handleTabKey(key(48, [.control, .shift], characters: "\t")))
        XCTAssertTrue(controller.document === second)
        XCTAssertFalse(controller.handleTabKey(key(0x12, [.command, .shift], characters: "1")), "other modifiers pass through")
        XCTAssertFalse(controller.handleTabKey(key(0x00, .command, characters: "a")))
    }

    func testOneTabLeavesTheKeysToTheEditor() throws {
        let only = try document("Only.md", "a")
        let controller = window(only)
        XCTAssertFalse(controller.handleTabKey(key(0x12, .command, characters: "1")))
        XCTAssertFalse(controller.handleTabKey(key(48, .control, characters: "\t")))
    }

    func testANewWindowCountsAsFrontBeforeItIsOnScreen() throws {
        let controller = window(try document("New.md", "a"))
        XCTAssertFalse(controller.window!.isVisible)
        XCTAssertTrue(TabWindowController.frontmost === controller, "files opened one after another join it")
    }
}
