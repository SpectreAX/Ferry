import XCTest
@testable import Ferry

/// The editor following its document (Revert To, a reload after an outside change) and the image interactions.
final class EditorSyncAndImageTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTempDirectory(self, name: "Doc")
        try writePNG(at: dir.appendingPathComponent("assets/a.png"), size: 40)
    }

    // MARK: Sync

    private func editor(_ document: MarkdownDocument, fileURL: URL?) -> (MarkdownEditor.Coordinator, EditorTextView, NSScrollView) {
        let coordinator = MarkdownEditor.Coordinator(MarkdownEditor(document: document, fileURL: fileURL, onCopyToast: { _ in }))
        let textView = EditorTextView.make()
        textView.documentURLProvider = { fileURL }
        textView.delegate = coordinator
        let storage = textView.textStorage!
        storage.setAttributedString(MarkdownCodec.attributedString(from: document.markdown, baseDirectory: fileURL?.deletingLastPathComponent()))
        coordinator.highlighter.highlightAll(storage)
        storage.delegate = coordinator
        coordinator.didLoad(document.markdown, baseDirectory: fileURL?.deletingLastPathComponent())
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        return (coordinator, textView, scrollView)
    }

    func testRevertShowsTheDocumentsTextAgain() {
        let url = dir.appendingPathComponent("n.md")
        let (coordinator, textView, scrollView) = editor(MarkdownDocument(markdown: "Old text that is fairly long"), fileURL: url)
        textView.setSelectedRange(NSRange(location: 20, length: 5))

        coordinator.parent = MarkdownEditor(document: MarkdownDocument(markdown: "# New\nShort"), fileURL: url, onCopyToast: { _ in })
        coordinator.syncFromDocument(textView, scrollView: scrollView)
        XCTAssertEqual(textView.string, "# New\nShort")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 11, length: 0), "kept where it still fits")
        let font = textView.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        XCTAssertEqual(font.pointSize, EditorStyle.headingFont(level: 1).pointSize, "restyled")
    }

    func testTypingInTheEditorIsNotReloaded() {
        let document = MarkdownDocument(markdown: "Hello")
        let (coordinator, textView, scrollView) = editor(document, fileURL: dir.appendingPathComponent("n.md"))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText(" world", replacementRange: textView.selectedRange())
        XCTAssertEqual(document.markdown, "Hello world")
        let storage = textView.textStorage!
        storage.addAttribute(.toolTip, value: "marker", range: NSRange(location: 0, length: 1)) // gone if reloaded
        coordinator.syncFromDocument(textView, scrollView: scrollView)
        XCTAssertNotNil(storage.attribute(.toolTip, at: 0, effectiveRange: nil))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 11, length: 0))
    }

    func testFirstSaveShowsRelativeImages() {
        let document = MarkdownDocument(markdown: "See ![](assets/a.png)")
        let (coordinator, textView, scrollView) = editor(document, fileURL: nil)
        XCTAssertTrue(imageAttachments(in: textView.textStorage!).isEmpty, "untitled: nowhere to look")
        coordinator.parent = MarkdownEditor(document: document, fileURL: dir.appendingPathComponent("n.md"), onCopyToast: { _ in })
        coordinator.syncFromDocument(textView, scrollView: scrollView)
        XCTAssertEqual(imageAttachments(in: textView.textStorage!).count, 1)
    }

    // MARK: Images

    private func windowedEditor() -> (EditorTextView, NSWindow) {
        let editor = makeEditor(markdown: "Text before\n![pic](assets/a.png) and after", documentURL: dir.appendingPathComponent("n.md"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false // ARC owns it
        window.contentView = editor
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
        addTeardownBlock { window.close() }
        return (editor, window)
    }

    private func imageCenter(_ editor: EditorTextView) -> NSPoint {
        let index = (editor.string as NSString).range(of: "\u{FFFC}").location
        let layoutManager = editor.layoutManager!
        let rect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                                                                       actualCharacterRange: nil),
                                              in: editor.textContainer!)
        return NSPoint(x: rect.midX + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y)
    }

    func testFindsTheImageOnlyOnThePicture() {
        let (editor, _) = windowedEditor()
        let center = imageCenter(editor)
        let hit = editor.imageAttachment(at: center)
        XCTAssertEqual(hit?.attachment.alt, "pic")
        XCTAssertEqual(hit?.characterIndex, (editor.string as NSString).range(of: "\u{FFFC}").location)
        XCTAssertNil(editor.imageAttachment(at: NSPoint(x: editor.bounds.width - 40, y: center.y)), "beside it, past the line's end")
        XCTAssertNil(editor.imageAttachment(at: NSPoint(x: editor.textContainerOrigin.x + 5, y: editor.textContainerOrigin.y + 5)), "text")
    }

    func testImageContextMenu() throws {
        let (editor, window) = windowedEditor()
        func rightClick(_ point: NSPoint) -> NSMenu? {
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: editor.convert(point, to: nil), modifierFlags: [],
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1)!
            return editor.menu(for: event)
        }
        let menu = try XCTUnwrap(rightClick(imageCenter(editor)))
        XCTAssertEqual(menu.items.prefix(3).map(\.title), ["Quick Look", "Reveal in Finder", "Open Image"])
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        let url = menu.items[1].representedObject as? URL
        XCTAssertEqual(url?.lastPathComponent, "a.png")

        let textMenu = rightClick(NSPoint(x: editor.textContainerOrigin.x + 5, y: editor.textContainerOrigin.y + 5))
        XCTAssertFalse(textMenu?.items.contains { $0.title == "Quick Look" } ?? false)
    }
}
