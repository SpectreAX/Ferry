import XCTest
@testable import Ferry

/// Links, task boxes, Tab / ⇧Tab, ⌘B / ⌘I / ⌘K, pasting a link over text, and text size.
final class EditorEditingTests: XCTestCase {
    private var dir: URL!
    private var docURL: URL!

    override func setUpWithError() throws {
        dir = try makeTempDirectory(self, name: "Doc")
        docURL = dir.appendingPathComponent("n.md")
        try writePNG(at: dir.appendingPathComponent("assets/a.png"), size: 20)
    }

    private func styledEditor(_ markdown: String) -> EditorTextView {
        let editor = makeEditor(markdown: markdown, documentURL: docURL)
        SyntaxHighlighter().highlightAll(editor.textStorage!)
        return editor
    }

    /// An editor in a window (layout, hit testing, undo).
    /// `stepUndo`: undo groups come only from `step` (one per simulated keypress or click).
    private func windowed(_ markdown: String, stepUndo: Bool = false) -> (EditorTextView, NSWindow) {
        let editor = styledEditor(markdown)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
        addTeardownBlock { window.close() }
        undoManager = editor.undoManager
        if stepUndo { undoManager?.groupsByEvent = false }
        return (editor, window)
    }

    private func center(of text: String, in editor: EditorTextView, offset: Int = 0) -> NSPoint {
        let index = (editor.string as NSString).range(of: text).location + offset
        let layoutManager = editor.layoutManager!
        let rect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                                                                       actualCharacterRange: nil),
                                              in: editor.textContainer!)
        return NSPoint(x: rect.midX + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y)
    }

    private var undoManager: UndoManager?

    /// One keypress or click: its own undo group, as AppKit makes one per event.
    private func step(_ action: () -> Void) {
        undoManager?.beginUndoGrouping()
        action()
        undoManager?.endUndoGrouping()
    }

    private func url(_ storage: NSTextStorage, at text: String) -> URL? {
        storage.attribute(.ferryLinkURL, at: (storage.string as NSString).range(of: text).location, effectiveRange: nil) as? URL
    }

    // MARK: Links

    func testLinksGetTheirURLOnlyForSafeSchemes() {
        let storage = styledEditor("[a](https://a.test \"t\") <https://b.test> https://c.test <mailto:x@y.test> ![img](https://d.test/i.png) [bad](javascript:alert(1)) [file](file:///etc)").textStorage!
        XCTAssertEqual(url(storage, at: "[a")?.absoluteString, "https://a.test")
        XCTAssertEqual(url(storage, at: "a.test \"t\")")?.absoluteString, "https://a.test", "the whole link, target included")
        XCTAssertEqual(url(storage, at: "<https://b")?.absoluteString, "https://b.test")
        XCTAssertEqual(url(storage, at: "https://c")?.absoluteString, "https://c.test")
        XCTAssertEqual(url(storage, at: "<mailto")?.absoluteString, "mailto:x@y.test")
        XCTAssertNil(url(storage, at: "![img"))
        XCTAssertNil(url(storage, at: "[bad"))
        XCTAssertNil(url(storage, at: "[file"))
    }

    func testLinkHitTestingAndMenuWithSyntaxHidden() throws {
        let (editor, window) = windowed("Read [the docs](https://docs.test) today\n\nOther paragraph")
        let hider = SyntaxHider(textView: editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)) // cursor elsewhere: syntax hidden
        hider.setEnabled(true)
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
        let onText = center(of: "the docs", in: editor, offset: 2)
        XCTAssertEqual(editor.linkURL(at: onText)?.absoluteString, "https://docs.test")
        XCTAssertNil(editor.linkURL(at: center(of: "Read", in: editor)))
        XCTAssertNil(editor.linkURL(at: NSPoint(x: editor.bounds.width - 30, y: onText.y)), "past the end of the line")

        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: editor.convert(onText, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = try XCTUnwrap(editor.menu(for: event))
        XCTAssertEqual(menu.items.prefix(2).map(\.title), ["Open Link", "Copy Link"])
        XCTAssertEqual((menu.items[0].representedObject as? URL)?.absoluteString, "https://docs.test")
    }

    // MARK: Task boxes

    func testTaskBoxesToggleByClickAndUndo() throws {
        let (editor, _) = windowed("- [ ] write tests\n- [X] ship\n- not a task [ ]", stepUndo: true)
        let storage = editor.textStorage!
        var box = NSRange()
        XCTAssertNotNil(storage.attribute(.ferryTaskCheckbox, at: 2, longestEffectiveRange: &box, in: NSRange(location: 0, length: storage.length)))
        XCTAssertEqual(box, NSRange(location: 2, length: 3), "exactly [ ]")
        XCTAssertNil(storage.attribute(.ferryTaskCheckbox, at: (storage.string as NSString).range(of: "task [ ]").location + 5, effectiveRange: nil))

        let first = try XCTUnwrap(editor.taskCheckboxRange(at: center(of: "[ ]", in: editor, offset: 1)))
        step { editor.toggleTask(first) }
        XCTAssertTrue(editor.string.hasPrefix("- [x] write tests"))
        let second = try XCTUnwrap(editor.taskCheckboxRange(at: center(of: "[X]", in: editor, offset: 1)))
        step { editor.toggleTask(second) }
        XCTAssertTrue(editor.string.contains("- [ ] ship"))
        editor.undoManager?.undo()
        XCTAssertTrue(editor.string.contains("- [X] ship"))
        XCTAssertTrue(editor.string.hasPrefix("- [x] write tests"), "one click, one undo step")
        XCTAssertNil(editor.taskCheckboxRange(at: center(of: "write", in: editor)))
    }

    // MARK: Tab and ⇧Tab

    func testIndentationLogic() {
        let single = ListIndentation.indent(in: "- a\n- b", selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(single?.range, NSRange(location: 4, length: 3))
        XCTAssertEqual(single?.replacement, "  - b")
        XCTAssertEqual(single?.selection, NSRange(location: 7, length: 0))
        XCTAssertNil(ListIndentation.indent(in: "plain text", selection: NSRange(location: 3, length: 0)), "a tab character instead")
        // Several lines: every non-empty line, the selection grows with them.
        let lines = ListIndentation.indent(in: "one\n\ntwo\nthree", selection: NSRange(location: 0, length: 8))!
        XCTAssertEqual(lines.replacement, "  one\n\n  two")
        XCTAssertEqual(lines.selection, NSRange(location: 0, length: 12))
        // ⇧Tab: a tab or up to two spaces per line; the cursor stays on its line.
        XCTAssertEqual(ListIndentation.outdent(in: "    - a\n\t- b", selection: NSRange(location: 0, length: 12))?.replacement, "  - a\n- b")
        XCTAssertEqual(ListIndentation.outdent(in: " - a", selection: NSRange(location: 2, length: 0))?.selection, NSRange(location: 1, length: 0))
        XCTAssertNil(ListIndentation.outdent(in: "- a", selection: NSRange(location: 1, length: 0)))
        XCTAssertEqual(ListIndentation.indent(in: "- a\n- b\n", selection: NSRange(location: 0, length: 4))?.replacement, "  - a",
                       "a selection ending at a line's start leaves that line alone")
    }

    func testTabInTheEditorIsOneUndoStep() {
        let (editor, _) = windowed("- item\n- next", stepUndo: true)
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        step { editor.insertTab(nil) }
        XCTAssertEqual(editor.string, "- item\n  - next")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 11, length: 0))
        step { editor.insertBacktab(nil) }
        XCTAssertEqual(editor.string, "- item\n- next")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "- item\n  - next")
    }

    func testTabKeepsImagesOnTheLines() {
        let markdown = "- see ![shot](assets/a.png) here\n- and ![](assets/a.png)\ntext"
        let (editor, _) = windowed(markdown, stepUndo: true)
        func images() -> Int { imageAttachments(in: editor.textStorage!).count }
        XCTAssertEqual(images(), 2)

        editor.setSelectedRange(NSRange(location: 3, length: 0)) // one list item
        step { editor.insertTab(nil) }
        XCTAssertEqual(images(), 2)
        XCTAssertEqual(editor.markdown, "  " + markdown)
        step { editor.insertBacktab(nil) }
        XCTAssertEqual(editor.markdown, markdown)

        editor.selectAll(nil) // several lines, both images
        step { editor.insertTab(nil) }
        XCTAssertEqual(images(), 2)
        XCTAssertEqual(editor.markdown, "  - see ![shot](assets/a.png) here\n  - and ![](assets/a.png)\n  text")
        XCTAssertEqual(imageAttachments(in: editor.textStorage!).first?.alt, "shot")
        step { editor.insertBacktab(nil) }
        XCTAssertEqual(editor.markdown, markdown)

        editor.undoManager?.undo()
        XCTAssertEqual(editor.markdown, "  - see ![shot](assets/a.png) here\n  - and ![](assets/a.png)\n  text")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.markdown, markdown)
        XCTAssertEqual(images(), 2, "undo brings the images back too")
    }

    // MARK: ⌘B / ⌘I

    func testBoldAndItalicWrapAndUnwrap() {
        let (editor, _) = windowed("say word now")
        func select(_ text: String) { editor.setSelectedRange((editor.string as NSString).range(of: text)) }
        select("word")
        editor.toggleBoldMarkdown(nil)
        XCTAssertEqual(editor.string, "say **word** now")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 4), "the word stays selected")
        editor.toggleItalicMarkdown(nil)
        XCTAssertEqual(editor.string, "say ***word*** now")
        editor.toggleBoldMarkdown(nil)
        XCTAssertEqual(editor.string, "say *word* now", "bold off, italic kept")
        editor.toggleItalicMarkdown(nil)
        XCTAssertEqual(editor.string, "say word now")
        select("say")
        editor.toggleItalicMarkdown(nil)
        select("*say*")
        editor.toggleItalicMarkdown(nil)
        XCTAssertEqual(editor.string, "say word now", "markers inside the selection count too")
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.toggleBoldMarkdown(nil)
        XCTAssertEqual(editor.string, "say**** word now")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testBoldKeepsImagesInTheSelection() {
        let (editor, _) = windowed("A ![](assets/a.png) B")
        editor.selectAll(nil)
        editor.toggleBoldMarkdown(nil)
        XCTAssertEqual(imageAttachments(in: editor.textStorage!).count, 1)
        XCTAssertEqual(editor.markdown, "**A ![](assets/a.png) B**")
    }

    // MARK: ⌘K and pasting a link

    func testInsertLink() {
        let (editor, _) = windowed("see docs")
        let pasteboard = testPasteboard()
        editor.linkSourcePasteboard = pasteboard
        func run(_ markdown: String, select: NSRange, clipboard: String?) -> (String, NSRange) {
            editor.string = markdown
            pasteboard.clearContents()
            if let clipboard { pasteboard.setString(clipboard, forType: .string) }
            editor.setSelectedRange(select)
            editor.insertMarkdownLink(nil)
            return (editor.string, editor.selectedRange())
        }
        XCTAssertTrue(run("see docs", select: NSRange(location: 4, length: 4), clipboard: "https://d.test") == ("see [docs](https://d.test)", NSRange(location: 26, length: 0)))
        XCTAssertTrue(run("see docs", select: NSRange(location: 4, length: 4), clipboard: "not a url") == ("see [docs]()", NSRange(location: 11, length: 0)))
        XCTAssertTrue(run("see ", select: NSRange(location: 4, length: 0), clipboard: "https://d.test") == ("see [](https://d.test)", NSRange(location: 5, length: 0)))
        XCTAssertTrue(run("see ", select: NSRange(location: 4, length: 0), clipboard: nil) == ("see []()", NSRange(location: 5, length: 0)))
    }

    func testPastingAURLOverSelectedTextMakesALink() {
        let (editor, _) = windowed("read the docs", stepUndo: true)
        let pasteboard = testPasteboard()
        pasteboard.setString("https://docs.test/a?b=1", forType: .string)
        editor.setSelectedRange(NSRange(location: 9, length: 4))
        step { editor.paste(from: pasteboard) }
        XCTAssertEqual(editor.string, "read the [docs](https://docs.test/a?b=1)")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "read the docs")
        editor.setSelectedRange(NSRange(location: 9, length: 4))
        step { editor.paste(from: pasteboard, smartLink: false) } // Paste and Match Style
        XCTAssertEqual(editor.string, "read the https://docs.test/a?b=1")
        // Not a URL, or no selection: a normal paste.
        pasteboard.clearContents()
        pasteboard.setString("words", forType: .string)
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        step { editor.paste(from: pasteboard) }
        XCTAssertTrue(editor.string.hasPrefix("words the"))
        XCTAssertNil(MarkdownFormatting.httpURL(from: "https://a.test b"))
        XCTAssertNil(MarkdownFormatting.httpURL(from: "ftp://a.test"))
    }

    // MARK: Text size

    func testTextSizeIsClampedAndHeadingsScale() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SettingsKeys.editorFontSize)
        addTeardownBlock { previous.map { defaults.set($0, forKey: SettingsKeys.editorFontSize) } ?? defaults.removeObject(forKey: SettingsKeys.editorFontSize) }

        defaults.removeObject(forKey: SettingsKeys.editorFontSize)
        XCTAssertEqual(EditorStyle.fontSize, 14)
        XCTAssertEqual((1...6).map { EditorStyle.headingFont(level: $0).pointSize }, [24, 20, 17, 15, 15, 15])
        defaults.set(18.0, forKey: SettingsKeys.editorFontSize)
        XCTAssertEqual(EditorStyle.bodyFont.pointSize, 18)
        XCTAssertEqual(EditorStyle.codeFont.pointSize, 17)
        XCTAssertEqual(EditorStyle.headingFont(level: 1).pointSize, 28)
        defaults.set(99.0, forKey: SettingsKeys.editorFontSize)
        XCTAssertEqual(EditorStyle.fontSize, EditorStyle.maxFontSize)
        defaults.set(2.0, forKey: SettingsKeys.editorFontSize)
        XCTAssertEqual(EditorStyle.fontSize, EditorStyle.minFontSize)
    }

    func testNewShortcutsAreReserved() {
        for shortcut in [AppShortcut(key: "b", modifiers: .command), AppShortcut(key: "i", modifiers: .command), AppShortcut(key: "k", modifiers: .command),
                         AppShortcut(key: "=", modifiers: .command), AppShortcut(key: "+", modifiers: .command),
                         AppShortcut(key: "-", modifiers: .command), AppShortcut(key: "0", modifiers: .command)] {
            XCTAssertEqual(AppShortcut.validate(shortcut, conflictingWith: nil), .reserved, shortcut.displayString)
        }
    }
}
