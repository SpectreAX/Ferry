import XCTest
@testable import Ferry

/// Image width (saved as `<img … width>`), the resize handle, and flips / quarter turns in the editor.
final class ImageSizeTests: XCTestCase {
    private var dir: URL!
    private var docURL: URL!

    override func setUpWithError() throws {
        dir = try makeTempDirectory(self, name: "Doc")
        docURL = dir.appendingPathComponent("n.md")
        try writePNG(at: dir.appendingPathComponent("assets/a.png"), size: 200)
    }

    // MARK: Codec

    func testImgTagsRoundTrip() {
        for markdown in [#"A <img src="assets/a.png" width="320"> B"#, #"<img src="assets/a.png" alt="shot" width=320px>"#,
                         #"<IMG SRC='assets/a.png'>"#] {
            let attributed = MarkdownCodec.attributedString(from: markdown, baseDirectory: dir)
            XCTAssertEqual(imageAttachments(in: attributed).count, 1, markdown)
            XCTAssertEqual(MarkdownCodec.markdown(from: attributed, baseDirectory: dir), markdown, "written back as it was")
        }
        let image = imageAttachments(in: MarkdownCodec.attributedString(from: #"<img src="assets/a.png" alt="shot" width="320">"#, baseDirectory: dir))[0]
        XCTAssertEqual(image.alt, "shot")
        XCTAssertEqual(image.displayWidth, 320)
        XCTAssertNil(imageAttachments(in: MarkdownCodec.attributedString(from: #"<img src="assets/a.png" width="50%">"#, baseDirectory: dir))[0].displayWidth)
    }

    func testRemoteAndMissingImgTagsStayText() {
        for markdown in [#"<img src="https://example.com/a.png" width="200">"#, #"<img src="assets/missing.png">"#, "<img alt=x>"] {
            let attributed = MarkdownCodec.attributedString(from: markdown, baseDirectory: dir)
            XCTAssertTrue(imageAttachments(in: attributed).isEmpty)
            XCTAssertEqual(attributed.string, markdown)
        }
    }

    func testBothFormsInDocumentOrder() {
        let markdown = #"![one](assets/a.png) and <img src="assets/a.png" alt="two" width="90"> and ![three](assets/a.png)"#
        let images = imageAttachments(in: MarkdownCodec.attributedString(from: markdown, baseDirectory: dir))
        XCTAssertEqual(images.map(\.alt), ["one", "two", "three"])
    }

    func testFragmentsKeepTheWidth() throws {
        let editor = makeEditor(markdown: #"x <img src="assets/a.png" alt="s" width="120"> y"#, documentURL: docURL)
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        let json = try XCTUnwrap(pasteboard.data(forType: FerryPasteboard.fragmentType))
        XCTAssertEqual(try JSONDecoder().decode(Fragment.self, from: json).images.first?.displayWidth, 120)
        XCTAssertTrue(pasteboard.string(forType: .html)?.contains(#"width="120""#) ?? false)
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("![s](<") ?? false, "AI apps get the full image file")

        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.paste(from: pasteboard)
        XCTAssertEqual(imageAttachments(in: editor.textStorage!).map(\.displayWidth), [120, 120])
        // Fragments from before widths existed still decode.
        let old = Data(#"{"version":1,"segments":[{"image":{"path":"/x.png","alt":""}}]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Fragment.self, from: old).images.first?.displayWidth)
    }

    // MARK: Editor

    private func windowed(_ markdown: String) -> (EditorTextView, NSWindow) {
        let editor = makeEditor(markdown: markdown, documentURL: docURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
        editor.undoManager?.groupsByEvent = false
        addTeardownBlock { window.close() }
        return (editor, window)
    }

    private func step(_ editor: EditorTextView, _ action: () -> Void) {
        editor.undoManager?.beginUndoGrouping()
        action()
        editor.undoManager?.endUndoGrouping()
    }

    private func imageIndex(_ editor: EditorTextView) -> Int { (editor.string as NSString).range(of: "\u{FFFC}").location }

    func testResizeAndResetAreUndoable() throws {
        let (editor, _) = windowed("Before ![shot](assets/a.png) after")
        let index = imageIndex(editor)
        step(editor) { editor.resizeImage(at: index, width: 120) }
        XCTAssertEqual(editor.markdown, #"Before <img src="assets/a.png" alt="shot" width="120"> after"#)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: index, length: 1), "the image stays selected")
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
        XCTAssertEqual(try XCTUnwrap(editor.imageFrame(at: index)).width, 120)
        step(editor) { editor.resizeImage(at: index, width: nil) }
        XCTAssertEqual(editor.markdown, "Before ![shot](assets/a.png) after")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.markdown, #"Before <img src="assets/a.png" alt="shot" width="120"> after"#)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.markdown, "Before ![shot](assets/a.png) after", "back to the text as it was")
    }

    func testFlipWritesANewFileAndUndoRestoresTheOriginal() throws {
        let original = dir.appendingPathComponent("assets/a.png")
        let originalBytes = try Data(contentsOf: original)
        let (editor, _) = windowed(#"<img src="assets/a.png" alt="shot" width="150">"#)
        let index = imageIndex(editor)
        step(editor) { editor.transformImage(at: index, operation: .rotateRight) }
        let image = try XCTUnwrap(imageAttachments(in: editor.textStorage!).first)
        XCTAssertNotEqual(image.fileURL.standardizedFileURL, original.standardizedFileURL)
        XCTAssertEqual(image.fileURL.deletingLastPathComponent().lastPathComponent, "assets")
        XCTAssertEqual(image.alt, "shot")
        XCTAssertEqual(image.displayWidth, 150)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes, "the original file is never changed")
        XCTAssertTrue(editor.markdown.hasPrefix(#"<img src="assets/2"#))
        XCTAssertEqual(editor.undoManager?.undoActionName, "Rotate Right")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.markdown, #"<img src="assets/a.png" alt="shot" width="150">"#)
    }

    func testResizeHandleDrag() throws {
        let (editor, window) = windowed("![](assets/a.png)\nText")
        let frame = try XCTUnwrap(editor.imageFrame(at: 0))
        XCTAssertEqual(frame.width, 200)
        let handle = try XCTUnwrap(editor.imageResizeHandleRect(for: frame))
        XCTAssertEqual(handle.size, NSSize(width: 14, height: 14))
        XCTAssertEqual(handle.maxX, frame.maxX - 4)
        XCTAssertEqual(handle.maxY, frame.maxY - 4)
        XCTAssertNil(editor.imageResizeHandleRect(for: NSRect(x: 0, y: 0, width: 30, height: 100)), "too small for a handle")

        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = NSPoint(x: handle.midX, y: handle.midY)
        editor.mouseDown(with: mouse(.leftMouseDown, start))
        editor.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: start.x - 80, y: start.y)))
        XCTAssertEqual(editor.markdown, "![](assets/a.png)\nText", "nothing changes while dragging")
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
        XCTAssertEqual(try XCTUnwrap(editor.imageFrame(at: 0)).width, 120, "but it shows the new width")
        step(editor) { editor.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: start.x - 80, y: start.y))) }
        XCTAssertEqual(editor.markdown, #"<img src="assets/a.png" width="120">"# + "\nText")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.markdown, "![](assets/a.png)\nText", "one undo step for the whole drag")
    }

    func testImageMenuOffersSizesFlipsAndTurns() throws {
        let (editor, window) = windowed(#"<img src="assets/a.png" width="300">"#)
        let frame = try XCTUnwrap(editor.imageFrame(at: 0))
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: editor.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil),
                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = try XCTUnwrap(editor.menu(for: event))
        let titles = menu.items.map(\.title)
        for title in ["Quick Look", "Size", "Flip Horizontal", "Flip Vertical", "Rotate Left 90°", "Rotate Right 90°"] {
            XCTAssertTrue(titles.contains(title), title)
        }
        let size = try XCTUnwrap(menu.items.first { $0.title == "Size" }?.submenu)
        XCTAssertEqual(size.items.map(\.title), ["25%", "50%", "75%", "Fit Width"])
        XCTAssertEqual(size.items.last?.state, .off, "this image has a width")
    }
}
