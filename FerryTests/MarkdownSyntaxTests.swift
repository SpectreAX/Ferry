import XCTest
@testable import Ferry

final class MarkdownSyntaxTests: XCTestCase {
    private func styled(_ markdown: String) -> NSTextStorage {
        let storage = NSTextStorage(string: markdown, attributes: EditorStyle.baseAttributes)
        SyntaxHighlighter().highlightAll(storage)
        return storage
    }

    private func at(_ storage: NSTextStorage, _ text: String, occurrence: Int = 0) -> Int {
        var search = NSRange(location: 0, length: storage.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = (storage.string as NSString).range(of: text, range: search)
            search = NSRange(location: NSMaxRange(found), length: storage.length - NSMaxRange(found))
        }
        XCTAssertNotEqual(found.location, NSNotFound, "missing \(text)")
        return found.location
    }

    private func font(_ storage: NSTextStorage, _ text: String) -> NSFont {
        storage.attribute(.font, at: at(storage, text), effectiveRange: nil) as! NSFont
    }

    private func color(_ storage: NSTextStorage, _ text: String, occurrence: Int = 0) -> NSColor? {
        storage.attribute(.foregroundColor, at: at(storage, text, occurrence: occurrence), effectiveRange: nil) as? NSColor
    }

    private func has(_ trait: NSFontTraitMask, _ font: NSFont) -> Bool {
        NSFontManager.shared.traits(of: font).contains(trait)
    }

    private func isMono(_ font: NSFont) -> Bool { font.fontDescriptor.symbolicTraits.contains(.monoSpace) }

    // MARK: Blocks

    func testHeadings() {
        let s = styled("# Title #\n\nSetext one\n===\n\nSetext two\n---\n\nText\n\n---\n")
        XCTAssertEqual(font(s, "Title").pointSize, EditorStyle.headingFont(level: 1).pointSize)
        XCTAssertEqual(color(s, "# Title"), EditorStyle.markerColor)
        XCTAssertEqual(font(s, "Setext one").pointSize, EditorStyle.headingFont(level: 1).pointSize)
        XCTAssertEqual(font(s, "Setext two").pointSize, EditorStyle.headingFont(level: 2).pointSize)
        XCTAssertEqual(color(s, "==="), EditorStyle.markerColor)
        XCTAssertEqual(font(s, "Text").pointSize, EditorStyle.fontSize, "a rule after a blank line is not a heading")
        XCTAssertEqual(color(s, "---", occurrence: 1), EditorStyle.markerColor)
    }

    func testQuotesListsAndTasks() {
        let s = styled("> quoted **b**\n\n- [x] done\n- [ ] todo\n1. one\n* star\n")
        XCTAssertEqual(color(s, "quoted"), EditorStyle.quoteColor)
        XCTAssertEqual(color(s, ">"), EditorStyle.markerColor)
        XCTAssertTrue(has(.boldFontMask, font(s, "b**")))
        XCTAssertEqual(color(s, "- [x]"), EditorStyle.markerColor)
        XCTAssertEqual(color(s, "done"), EditorStyle.quoteColor, "checked items are quieter")
        XCTAssertEqual(color(s, "todo"), NSColor.textColor)
        XCTAssertEqual(color(s, "1."), EditorStyle.markerColor)
        XCTAssertEqual(color(s, "* "), EditorStyle.markerColor)
    }

    func testFencedCodeIsMonospacedAndNotStyledInside() {
        let s = styled("```swift\nlet *x* = `y`\n```\nafter *em*\n")
        XCTAssertTrue(isMono(font(s, "let")))
        XCTAssertFalse(has(.italicFontMask, font(s, "x*")))
        XCTAssertEqual(color(s, "```swift"), EditorStyle.markerColor)
        XCTAssertFalse(isMono(font(s, "after")))
        XCTAssertTrue(has(.italicFontMask, font(s, "em")))
    }

    func testUnclosedFenceRunsToTheEnd() {
        let s = styled("text\n~~~\ncode *a*\nmore")
        XCTAssertTrue(isMono(font(s, "more")))
        XCTAssertFalse(isMono(font(s, "text")))
    }

    func testTables() {
        let s = styled("| a | b |\n|---|:-:|\n| 1 | 2 |\n")
        XCTAssertEqual(color(s, "|"), EditorStyle.markerColor)
        XCTAssertEqual(color(s, "a"), NSColor.textColor)
        XCTAssertEqual(color(s, "|---"), EditorStyle.markerColor)
    }

    // MARK: Inline

    func testEmphasisAndStrikethrough() {
        let s = styled("**bold** and *it* and _u_ and ~~gone~~ and __b2__")
        XCTAssertTrue(has(.boldFontMask, font(s, "bold")))
        XCTAssertEqual(color(s, "**"), EditorStyle.markerColor)
        XCTAssertTrue(has(.italicFontMask, font(s, "it")))
        XCTAssertTrue(has(.italicFontMask, font(s, "u_")))
        XCTAssertNotNil(s.attribute(.strikethroughStyle, at: at(s, "gone"), effectiveRange: nil))
        XCTAssertTrue(has(.boldFontMask, font(s, "b2")))
        XCTAssertFalse(has(.italicFontMask, font(s, "and")))
    }

    func testInlineCodeShieldsItsContent() {
        let s = styled("use `a*b*c` here")
        XCTAssertTrue(isMono(font(s, "a*b")))
        XCTAssertFalse(has(.italicFontMask, font(s, "b*c")))
        XCTAssertNotNil(s.attribute(.backgroundColor, at: at(s, "a*b"), effectiveRange: nil))
        XCTAssertEqual(color(s, "`"), EditorStyle.markerColor)
    }

    func testLinksAutolinksHTMLAndEscapes() {
        let s = styled("[site](https://a.test) ![pic](x.png) https://b.test <br> \\*not\\* snake_case_name")
        XCTAssertEqual(color(s, "site"), EditorStyle.linkColor)
        XCTAssertEqual(color(s, "](https://a.test)"), EditorStyle.markerColor)
        XCTAssertEqual(color(s, "pic"), EditorStyle.linkColor)
        XCTAssertEqual(color(s, "https://b.test"), EditorStyle.linkColor)
        XCTAssertEqual(color(s, "<br>"), EditorStyle.markerColor)
        XCTAssertEqual(color(s, "\\*"), EditorStyle.markerColor)
        XCTAssertFalse(has(.italicFontMask, font(s, "not")))
        XCTAssertFalse(has(.italicFontMask, font(s, "case")), "underscores inside words are not emphasis")
    }

    // MARK: Safety

    func testStylingNeverChangesTextOrAttachments() throws {
        let dir = try makeTempDirectory(self)
        try writePNG(at: dir.appendingPathComponent("assets/a.png"))
        let markdown = "# H\n**b** ![a](assets/a.png) `c`\n"
        let storage = NSTextStorage(attributedString: MarkdownCodec.attributedString(from: markdown, baseDirectory: dir))
        SyntaxHighlighter().highlightAll(storage)
        XCTAssertEqual(imageAttachments(in: storage).count, 1)
        XCTAssertEqual(MarkdownCodec.markdown(from: storage, baseDirectory: dir), markdown)
    }

    func testAddingOrRemovingAFenceRestylesTheRest() {
        let storage = NSTextStorage(string: "intro\n\ncode *y*\n", attributes: EditorStyle.baseAttributes)
        let highlighter = SyntaxHighlighter()
        highlighter.highlightAll(storage)
        XCTAssertTrue(has(.italicFontMask, font(storage, "y*")))

        storage.replaceCharacters(in: NSRange(location: 6, length: 0), with: "```\n")
        highlighter.update(storage, edited: NSRange(location: 6, length: 4))
        XCTAssertTrue(isMono(font(storage, "code")))
        XCTAssertFalse(has(.italicFontMask, font(storage, "y*")))

        storage.replaceCharacters(in: NSRange(location: 6, length: 4), with: "")
        highlighter.update(storage, edited: NSRange(location: 6, length: 0))
        XCTAssertFalse(isMono(font(storage, "code")))
        XCTAssertTrue(has(.italicFontMask, font(storage, "y*")))
    }

    // MARK: Return in lists

    func testListContinuationRules() {
        typealias A = ListContinuation.Action
        XCTAssertEqual(ListContinuation.action(line: "- item", rest: ""), A.insert("\n- "))
        XCTAssertEqual(ListContinuation.action(line: "  * item", rest: ""), A.insert("\n  * "))
        XCTAssertEqual(ListContinuation.action(line: "9. nine", rest: ""), A.insert("\n10. "))
        XCTAssertEqual(ListContinuation.action(line: "3) three", rest: ""), A.insert("\n4) "))
        XCTAssertEqual(ListContinuation.action(line: "- [x] done", rest: ""), A.insert("\n- [ ] "))
        XCTAssertEqual(ListContinuation.action(line: "> quote", rest: ""), A.insert("\n> "))
        XCTAssertEqual(ListContinuation.action(line: "- ", rest: ""), A.end(markerLength: 2))
        XCTAssertEqual(ListContinuation.action(line: "- [ ] ", rest: ""), A.end(markerLength: 6))
        XCTAssertEqual(ListContinuation.action(line: "> ", rest: ""), A.end(markerLength: 2))
        XCTAssertNil(ListContinuation.action(line: "- ", rest: "text after"))
        XCTAssertNil(ListContinuation.action(line: "---", rest: ""))
        XCTAssertNil(ListContinuation.action(line: "* * *", rest: ""))
        XCTAssertNil(ListContinuation.action(line: "plain text", rest: ""))
        XCTAssertNil(ListContinuation.action(line: "-not a list", rest: ""))
    }

    func testReturnInTheEditor() {
        let editor = EditorTextView.make()
        func type(_ text: String, caretAt caret: Int? = nil) -> String {
            editor.string = text
            editor.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
            editor.insertNewline(nil)
            return editor.string
        }
        XCTAssertEqual(type("- item"), "- item\n- ")
        XCTAssertEqual(type("1. one"), "1. one\n2. ")
        XCTAssertEqual(type("- [x] done"), "- [x] done\n- [ ] ")
        XCTAssertEqual(type("- abcd", caretAt: 4), "- ab\n- cd", "splitting an item keeps both as items")
        XCTAssertEqual(type("- a\n- "), "- a\n", "Return on an empty item ends the list")
        XCTAssertEqual(type("> q"), "> q\n> ")
        XCTAssertEqual(type("plain"), "plain\n")
        XCTAssertEqual(editor.selectedRange().location, ("plain\n" as NSString).length)
    }

    // MARK: Hide Markdown Syntax

    private func hideable(_ storage: NSTextStorage, _ index: Int) -> Bool {
        storage.attribute(.ferryHideableMarker, at: index, effectiveRange: nil) != nil
    }

    func testHideableMarkers() {
        let s = styled("# Title\n**b** *i* ~~s~~ `c` [l](u) \\* ![img](x.png)\n- item\n1. one\n> q\n| a | b |\n```\ncode\n```\n")
        for marker in ["# ", "**", "*i", "~~", "`c", "[l", "](u)", "\\*"] {
            XCTAssertTrue(hideable(s, at(s, marker)), marker)
        }
        XCTAssertTrue(hideable(s, at(s, "# ") + 1), "the space after #, so a hidden heading starts flush")
        for visible in ["Title", "b**", "i*", "s~~", "c`", "l](", "![img", "](x.png)", "- item", "1. one", "> q", "| a", "```"] {
            XCTAssertFalse(hideable(s, at(s, visible)), visible)
        }
    }

    func testHidingIsLayoutOnlyAndFollowsTheCursor() throws {
        let markdown = "# Title\n\nSome **bold** text\n"
        let editor = makeEditor(markdown: markdown, documentURL: try makeTempDirectory(self).appendingPathComponent("n.md"))
        let storage = editor.textStorage!
        SyntaxHighlighter().highlightAll(storage)
        let hider = SyntaxHider(textView: editor)
        let layoutManager = editor.layoutManager!
        func isHidden(_ index: Int) -> Bool {
            layoutManager.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length))
            return layoutManager.propertyForGlyph(at: layoutManager.glyphIndexForCharacter(at: index)).contains(.null)
        }
        let bold = (storage.string as NSString).range(of: "**").location

        editor.setSelectedRange(NSRange(location: 1, length: 0)) // in the heading
        hider.setEnabled(true)
        XCTAssertFalse(isHidden(0), "the cursor's paragraph shows its syntax")
        XCTAssertTrue(isHidden(bold))
        XCTAssertFalse(isHidden(bold + 2))

        editor.setSelectedRange(NSRange(location: bold + 3, length: 0))
        hider.update()
        XCTAssertTrue(isHidden(0))
        XCTAssertTrue(isHidden(1), "with the space after #")
        XCTAssertFalse(isHidden(bold))

        editor.selectAll(nil) // a selection keeps the revealed paragraph
        hider.update()
        XCTAssertFalse(isHidden(bold))
        XCTAssertTrue(isHidden(0))

        hider.setEnabled(false)
        XCTAssertFalse(isHidden(0))
        XCTAssertFalse(isHidden(bold))
        XCTAssertEqual(editor.markdown, markdown, "the text never changes")
    }

    func testRestyledLinesHideRightAwayAfterAMultiLinePaste() throws {
        let editor = makeEditor(markdown: "Top line\n", documentURL: try makeTempDirectory(self).appendingPathComponent("n.md"))
        let storage = editor.textStorage!
        let highlighter = SyntaxHighlighter()
        highlighter.highlightAll(storage)
        let hider = SyntaxHider(textView: editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        hider.setEnabled(true)
        let layoutManager = editor.layoutManager!
        layoutManager.ensureLayout(for: editor.textContainer!) // glyphs exist before the edit, as on screen

        let pasted = "See [link](https://x.test) and ~~old~~ and \\*\nMore [two](u)\n"
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: pasted)
        // As MarkdownEditor does after an edit: the restyle alone must refresh the glyphs.
        highlighter.update(storage, edited: NSRange(location: 9, length: (pasted as NSString).length))
        hider.update()

        func isHidden(_ marker: String) -> Bool {
            let index = (storage.string as NSString).range(of: marker).location
            layoutManager.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length))
            return layoutManager.propertyForGlyph(at: layoutManager.glyphIndexForCharacter(at: index)).contains(.null)
        }
        for marker in ["[link", "](https", "~~old", "\\*", "[two"] { XCTAssertTrue(isHidden(marker), marker) }
        XCTAssertFalse(isHidden("Top"))
    }

    func testRemovingAFenceHidesTheSyntaxThatWasCode() throws {
        let editor = makeEditor(markdown: "Top\n```\nSee [link](u) ~~old~~ \\*\n", documentURL: try makeTempDirectory(self).appendingPathComponent("n.md"))
        let storage = editor.textStorage!
        let highlighter = SyntaxHighlighter()
        highlighter.highlightAll(storage)
        let hider = SyntaxHider(textView: editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        hider.setEnabled(true)
        let layoutManager = editor.layoutManager!
        layoutManager.ensureLayout(for: editor.textContainer!)
        func isHidden(_ marker: String) -> Bool {
            let index = (storage.string as NSString).range(of: marker).location
            layoutManager.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length))
            return layoutManager.propertyForGlyph(at: layoutManager.glyphIndexForCharacter(at: index)).contains(.null)
        }
        XCTAssertFalse(isHidden("[link"), "inside an unclosed code block")

        let fence = (storage.string as NSString).range(of: "```\n")
        storage.replaceCharacters(in: fence, with: "")
        highlighter.update(storage, edited: NSRange(location: fence.location, length: 0)) // fence count changed: full restyle
        hider.update()
        for marker in ["[link", "](u)", "~~old", "\\*"] { XCTAssertTrue(isHidden(marker), marker) }
    }

    func testDoubleUnderscoresInsideAWordAreNotBold() {
        let s = styled("snake__double__name and __bold__ here")
        XCTAssertFalse(has(.boldFontMask, font(s, "double")))
        XCTAssertFalse(hideable(s, at(s, "__double")))
        XCTAssertTrue(has(.boldFontMask, font(s, "bold")))
        XCTAssertTrue(hideable(s, at(s, "__bold")))
        XCTAssertEqual(MarkdownStripper.strip("snake__double__name and __bold__ here"), "snake__double__name and bold here")
    }
}
