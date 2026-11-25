import XCTest
@testable import Ferry

/// Serves fake web images for https://images.test/… so downloads never touch the network.
final class StubImageProtocol: URLProtocol {
    static var responses: [String: (status: Int, data: Data, delay: TimeInterval)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "images.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let entry = Self.responses[url.absoluteString] ?? (404, Data(), 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + entry.delay) { [self] in
            let response = HTTPURLResponse(url: url, statusCode: entry.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: entry.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

final class RichPasteTests: XCTestCase {
    private var dir: URL!
    private var docURL: URL!
    private var png: Data!

    override func setUpWithError() throws {
        dir = try makeTempDirectory(self, name: "Rich Doc")
        docURL = dir.appendingPathComponent("note.md")
        let scratch = try makeTempDirectory(self, name: "scratch")
        png = try Data(contentsOf: writePNG(at: scratch.appendingPathComponent("p.png")))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubImageProtocol.self]
        RemoteImageLoader.session = URLSession(configuration: configuration)
        StubImageProtocol.responses = [:]
    }

    private func pasteHTML(_ html: String, plain: String, into editor: EditorTextView, extra: (NSPasteboard) -> Void = { _ in }) {
        let pasteboard = testPasteboard()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString(html, forType: .html)
        pasteboard.setString(plain, forType: .string)
        extra(pasteboard)
        editor.paste(from: pasteboard)
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private func assertOrder(_ markdown: String, _ parts: [String], file: StaticString = #filePath, line: UInt = #line) {
        var cursor = markdown.startIndex
        for part in parts {
            guard let found = markdown.range(of: part, range: cursor..<markdown.endIndex) else {
                return XCTFail("\"\(part)\" missing or out of order in: \(markdown)", file: file, line: line)
            }
            cursor = found.upperBound
        }
    }

    // MARK: Browsers

    func testHTMLWithInlineImageKeepsTextAndImageInOrder() {
        let editor = makeEditor(markdown: "", documentURL: docURL)
        let html = #"<meta charset="utf-8"><p>Before the chart</p><img src="data:image/png;base64,\#(png.base64EncodedString())" alt="chart"><p>After the chart</p>"#
        pasteHTML(html, plain: "Before the chart\nAfter the chart", into: editor)
        let images = imageAttachments(in: editor.textStorage!)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.alt, "chart")
        XCTAssertTrue(images.first?.fileURL.path.contains("/Rich Doc/assets/") ?? false)
        assertOrder(editor.markdown, ["Before the chart", "![chart](assets/", "After the chart"])
    }

    func testHTMLWithLocalFileImageIsCopiedIntoAssets() throws {
        let outside = try makeTempDirectory(self, name: "word temp")
        let file = try writePNG(at: outside.appendingPathComponent("image001.png"))
        let editor = makeEditor(markdown: "", documentURL: docURL)
        pasteHTML(#"<p>Report</p><img src="\#(file.absoluteString)"><p>End</p>"#, plain: "Report\nEnd", into: editor)
        XCTAssertEqual(imageAttachments(in: editor.textStorage!).count, 1)
        assertOrder(editor.markdown, ["Report", "](assets/", "End"])
    }

    func testWebImageIsDownloadedAndReplacesItsLink() {
        StubImageProtocol.responses["https://images.test/pic.png"] = (200, png, 0.05)
        let editor = makeEditor(markdown: "", documentURL: docURL)
        pasteHTML(#"<p>Look:</p><img src="https://images.test/pic.png" alt="pic"><p>done</p>"#, plain: "Look:\ndone", into: editor)
        XCTAssertTrue(editor.markdown.contains("![pic](https://images.test/pic.png)"), "the link shows right away")
        XCTAssertTrue(spin { imageAttachments(in: editor.textStorage!).count == 1 })
        assertOrder(editor.markdown, ["Look:", "![pic](assets/", "done"])
        XCTAssertFalse(editor.markdown.contains("https://"))
    }

    func testRelativeAndProtocolRelativeSourcesResolve() {
        let base = URL(string: "https://site.test/blog/post.html")
        XCTAssertEqual(RichClipboardReader.segment(src: "img/a.png", alt: "", baseURL: base),
                       .remoteImage(URL(string: "https://site.test/blog/img/a.png")!, alt: ""))
        XCTAssertEqual(RichClipboardReader.segment(src: "//cdn.test/b.png", alt: "", baseURL: nil),
                       .remoteImage(URL(string: "https://cdn.test/b.png")!, alt: ""))
        XCTAssertNil(RichClipboardReader.segment(src: "data:text/plain;base64,aGk=", alt: "", baseURL: nil))
        XCTAssertNil(RichClipboardReader.segment(src: "javascript:alert(1)", alt: "", baseURL: nil))
    }

    func testFailedDownloadKeepsTheLink() {
        StubImageProtocol.responses["https://images.test/missing.png"] = (404, Data(), 0)
        let editor = makeEditor(markdown: "", documentURL: docURL)
        pasteHTML(#"<p>Text</p><img src="https://images.test/missing.png" alt="gone">"#, plain: "Text", into: editor)
        XCTAssertTrue(spin { editor.textStorage?.attribute(.ferryPendingImage, at: editor.string.utf16.count - 1, effectiveRange: nil) == nil })
        XCTAssertTrue(editor.markdown.contains("![gone](https://images.test/missing.png)"))
        XCTAssertTrue(imageAttachments(in: editor.textStorage!).isEmpty)
    }

    func testTypingWhileDownloadingIsKept() {
        StubImageProtocol.responses["https://images.test/slow.png"] = (200, png, 0.3)
        let editor = makeEditor(markdown: "", documentURL: docURL)
        pasteHTML(#"<p>Intro</p><img src="https://images.test/slow.png">"#, plain: "Intro", into: editor)
        editor.insertText(" typed later", replacementRange: editor.selectedRange())
        XCTAssertTrue(spin { imageAttachments(in: editor.textStorage!).count == 1 })
        XCTAssertTrue(editor.markdown.hasSuffix(" typed later"), editor.markdown)
        XCTAssertEqual(editor.selectedRange().location, editor.string.utf16.count, "cursor stays after the typed text")
    }

    func testCopyImageInBrowserUsesThePictureData() {
        let pasteboard = testPasteboard()
        pasteboard.declareTypes([.html, .png], owner: nil)
        pasteboard.setString(#"<img src="https://images.test/pic.png">"#, forType: .html)
        pasteboard.setData(png, forType: .png)
        XCTAssertEqual(FerryPasteboard.read(from: pasteboard), .imageData(png))
    }

    func testHTMLDropsStylesFramesAndMediaButKeepsImages() {
        let html = #"<style>p{color:red} .x{background:url(https://images.test/bg.png)}</style><p>Kept text</p>"#
            + #"<iframe src="https://evil.test/"><p>frame text</p></iframe><svg><text>svg text</text></svg>"#
            + #"<img src="data:image/png;base64,\#(png.base64EncodedString())"><video><source src="https://v.test/a.mp4">video text</video>"#
        let segments = RichClipboardReader.segments(fromHTML: html, baseURL: nil) ?? []
        let text = segments.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        XCTAssertTrue(text.contains("Kept text"))
        for hidden in ["color:red", "frame text", "svg text", "video text"] { XCTAssertFalse(text.contains(hidden), hidden) }
        XCTAssertEqual(segments.filter(\.isImage).count, 1)
    }

    func testHTMLWithoutImagesStaysPlainText() {
        let pasteboard = testPasteboard()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString("<b>bold</b> words", forType: .html)
        pasteboard.setString("bold words", forType: .string)
        XCTAssertEqual(FerryPasteboard.read(from: pasteboard), .text("bold words"))
    }

    // MARK: Notes, Pages, TextEdit (RTFD)

    func testRTFDKeepsImagesAndTextInOrder() throws {
        let content = NSMutableAttributedString(string: "Hello ")
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "Pasted Graphic.png"
        content.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        content.append(NSAttributedString(string: " world", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)]))
        let rtfd = try XCTUnwrap(content.rtfd(from: NSRange(location: 0, length: content.length)))

        let pasteboard = testPasteboard()
        pasteboard.declareTypes([.rtfd, .string], owner: nil)
        pasteboard.setData(rtfd, forType: .rtfd)
        pasteboard.setString("Hello  world", forType: .string)
        let editor = makeEditor(markdown: "", documentURL: docURL)
        editor.paste(from: pasteboard)

        XCTAssertEqual(imageAttachments(in: editor.textStorage!).count, 1)
        assertOrder(editor.markdown, ["Hello ", "](assets/", " world"])
        let font = editor.textStorage?.attribute(.font, at: editor.string.utf16.count - 1, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, EditorStyle.fontSize, "formatting from outside is dropped")
    }

    // MARK: Word (RTF + HTML image + a picture of the whole selection)

    func testWordLikeClipboardPastesTextAndImageNotThePreview() throws {
        let outside = try makeTempDirectory(self, name: "msohtmlclip")
        let file = try writePNG(at: outside.appendingPathComponent("image001.png"))
        let pasteboard = testPasteboard()
        pasteboard.declareTypes([.rtf, .html, .png, .string], owner: nil)
        pasteboard.setData(Data(#"{\rtf1 Quarterly results}"#.utf8), forType: .rtf)
        pasteboard.setString(#"<p>Quarterly results</p><img src="\#(file.absoluteString)">"#, forType: .html)
        pasteboard.setData(png, forType: .png) // Office's picture of the selection
        pasteboard.setString("Quarterly results", forType: .string)
        guard case .mixed(let segments)? = FerryPasteboard.read(from: pasteboard) else { return XCTFail("expected text + image") }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.last, .imageFile(file, alt: ""))
    }
}
