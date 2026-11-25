import XCTest
@testable import Ferry

final class CopyPasteTests: XCTestCase {
    private var dir: URL!
    private var docURL: URL!
    private var image: URL!
    private let markdown = "Intro <tag> & \"q\"\n![shot](<assets/my shot.png>)\nEnd"

    override func setUpWithError() throws {
        dir = try makeTempDirectory(self, name: "Source Folder")
        docURL = dir.appendingPathComponent("note.md")
        image = try writePNG(at: dir.appendingPathComponent("assets/my shot.png"))
    }

    // MARK: ⌘C

    func testCopyWritesStringHTMLAndFragment() throws {
        let editor = makeEditor(markdown: markdown, documentURL: docURL)
        var toast: String?
        editor.onCopyToast = { toast = $0 }
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        XCTAssertTrue(editor.copySelection(to: pasteboard))

        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2, "Markdown item + one image file")
        let path = image.path
        XCTAssertEqual(pasteboard.string(forType: .string),
                       "Intro <tag> & \"q\"\n![shot](<\(path)>)\nEnd")

        let html = try XCTUnwrap(pasteboard.string(forType: .html))
        XCTAssertTrue(html.hasPrefix(#"<meta charset="utf-8">"#))
        XCTAssertTrue(html.contains("Intro &lt;tag&gt; &amp; &quot;q&quot;<br>"))
        XCTAssertTrue(html.contains(#"<img src="\#(URL(fileURLWithPath: path).absoluteString)" alt="shot">"#))
        XCTAssertTrue(html.contains("%20"))

        let json = try XCTUnwrap(pasteboard.data(forType: FerryPasteboard.fragmentType))
        let fragment = try JSONDecoder().decode(Fragment.self, from: json)
        XCTAssertEqual(fragment.images, [.init(path: path, alt: "shot")])
        XCTAssertEqual(fragment.segments.first?.text, "Intro <tag> & \"q\"\n")
        XCTAssertEqual(toast, "Copied text + 1 image")
    }

    func testCopyWithoutImagesShowsNoToast() {
        let editor = makeEditor(markdown: "just text", documentURL: docURL)
        var toast: String?
        editor.onCopyToast = { toast = $0 }
        editor.selectAll(nil)
        XCTAssertTrue(editor.copySelection(to: testPasteboard()))
        XCTAssertNil(toast)
    }

    func testCopyWithNoSelectionDoesNothing() {
        let editor = makeEditor(markdown: markdown, documentURL: docURL)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        let pasteboard = testPasteboard()
        pasteboard.setString("untouched", forType: .string)
        XCTAssertFalse(editor.copySelection(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
    }

    /// Chromium apps (Claude, Codex desktop) drop text when files are present, so with images
    /// everything goes as files: the text as `<document>.md`, then each image file.
    func testCopyWithImagesAttachesMarkdownFileThenImages() throws {
        let editor = makeEditor(markdown: markdown, documentURL: docURL)
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)

        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0].lastPathComponent, "note.md")
        XCTAssertTrue(urls[0].path.hasPrefix(editor.clipboardAttachmentsDirectory.path))
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), pasteboard.string(forType: .string))
        XCTAssertEqual(urls[1].path, image.path)

        let first = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(Set(first.types), [.string, .html, FerryPasteboard.fragmentType, .fileURL])
    }

    func testPartialSelectionIsNamedExcerptAndHoldsOnlyTheSelection() throws {
        let editor = makeEditor(markdown: "Before\n" + markdown, documentURL: docURL)
        let start = ("Before\n" as NSString).length
        editor.setSelectedRange(NSRange(location: start, length: editor.string.utf16.count - start))
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.first?.lastPathComponent, "note (excerpt).md")
        let text = try String(contentsOf: urls[0], encoding: .utf8)
        XCTAssertFalse(text.contains("Before"))
        XCTAssertTrue(text.hasPrefix("Intro <tag>"))
    }

    func testImagesOnlySelectionCopiesJustTheImages() throws {
        let editor = makeEditor(markdown: "![shot](<assets/my shot.png>)", documentURL: docURL)
        var toast: String?
        editor.onCopyToast = { toast = $0 }
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.map(\.lastPathComponent), ["my shot.png"], "no .md holding only image paths")
        XCTAssertEqual(toast, "Copied 1 image")
        XCTAssertNotNil(pasteboard.data(forType: FerryPasteboard.fragmentType), "pasting back into Ferry still works")
    }

    func testRepeatedImageIsAttachedOnce() throws {
        let editor = makeEditor(markdown: markdown + "\n" + markdown, documentURL: docURL)
        var toast: String?
        editor.onCopyToast = { toast = $0 }
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.map(\.lastPathComponent), ["note.md", "my shot.png"])
        XCTAssertEqual(toast, "Copied text + 1 image")
    }

    func testTextOnlyCopyAttachesNoFiles() {
        let editor = makeEditor(markdown: "just text", documentURL: docURL)
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertNil(pasteboard.availableType(from: [.fileURL]))
        XCTAssertEqual(pasteboard.string(forType: .string), "just text")
    }

    func testMissingImageFileIsNotAttached() throws {
        let editor = makeEditor(markdown: markdown, documentURL: docURL)
        try FileManager.default.removeItem(at: image)
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        XCTAssertNil(pasteboard.availableType(from: [.fileURL]), "no files means text stays visible to every app")
        XCTAssertNotNil(pasteboard.string(forType: .string))
    }

    func testUnwritableAttachmentsFolderFallsBackToText() {
        let editor = makeEditor(markdown: markdown, documentURL: docURL)
        editor.clipboardAttachmentsDirectory = URL(fileURLWithPath: "/dev/null/not-a-folder")
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertNil(pasteboard.availableType(from: [.fileURL]))
        XCTAssertNotNil(pasteboard.data(forType: FerryPasteboard.fragmentType))
    }

    // MARK: Ignore Markdown Syntax When Copying

    func testIgnoringSyntaxStripsWhatOtherAppsGetButNotFerry() throws {
        let source = "# Plan\n- **Bold** step\n![shot](<assets/my shot.png>)\nSee [docs](https://x.com)"
        let editor = makeEditor(markdown: source, documentURL: docURL)
        editor.stripMarkdownOnCopy = { true }
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)

        let stripped = "Plan\nBold step\n![shot](<\(image.path)>)\nSee docs"
        XCTAssertEqual(pasteboard.string(forType: .string), stripped)
        XCTAssertTrue(try XCTUnwrap(pasteboard.string(forType: .html)).contains("Plan<br>Bold step<br><img"))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(urls.first), encoding: .utf8), stripped, "the .md attachment too")

        // Pasting back into Ferry restores the Markdown; ⌥⌘C still copies it.
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.paste(from: pasteboard)
        XCTAssertEqual(editor.markdown, source + source)
        editor.selectAll(nil)
        editor.copyPlainMarkdown(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), source + source)
    }

    // MARK: ⌥⌘C

    func testCopyAsPlainMarkdownWritesOnlyRelativeString() {
        let editor = makeEditor(markdown: markdown, documentURL: docURL)
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        XCTAssertTrue(editor.copyPlainMarkdown(to: pasteboard))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.types, [.string])
        XCTAssertNil(pasteboard.availableType(from: [.html, FerryPasteboard.fragmentType, .fileURL]))
        XCTAssertEqual(pasteboard.string(forType: .string), markdown)
    }

    func testPlainMarkdownForNewlyInsertedImageIsRelative() throws {
        let editor = makeEditor(markdown: "", documentURL: docURL)
        let pasteboard = testPasteboard()
        pasteboard.setData(try Data(contentsOf: image), forType: .png)
        editor.paste(from: pasteboard)
        editor.selectAll(nil)
        editor.copyPlainMarkdown(to: pasteboard)
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.hasPrefix("![](assets/"), copied)
        XCTAssertFalse(copied.contains(dir.path))
    }

    // MARK: ⌘C → ⌘V

    func testCopyPasteWithinSameDocumentRestoresAttachments() throws {
        let editor = makeEditor(markdown: markdown, documentURL: docURL)
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)

        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.paste(from: pasteboard)

        let images = imageAttachments(in: editor.textStorage!)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images.map { $0.fileURL.standardizedFileURL.path }, [image.path, image.path].map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        XCTAssertEqual(editor.markdown, markdown + markdown)
        let assets = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("assets").path)
        XCTAssertEqual(assets, ["my shot.png"], "no duplicate files within the same document")
    }

    func testCopyPasteAcrossFoldersCopiesImagesIntoTargetAssets() throws {
        let source = makeEditor(markdown: markdown, documentURL: docURL)
        source.selectAll(nil)
        let pasteboard = testPasteboard()
        source.copySelection(to: pasteboard)

        let targetDir = try makeTempDirectory(self, name: "目标 Folder")
        let targetURL = targetDir.appendingPathComponent("other.md")
        let target = makeEditor(markdown: "Top\n", documentURL: targetURL)
        target.setSelectedRange(NSRange(location: 4, length: 0))
        target.paste(from: pasteboard)

        let images = imageAttachments(in: target.textStorage!)
        XCTAssertEqual(images.count, 1)
        let copied = targetDir.appendingPathComponent("assets/my shot.png")
        XCTAssertEqual(images[0].fileURL.resolvingSymlinksInPath().path, copied.resolvingSymlinksInPath().path)
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: image))
        XCTAssertEqual(images[0].alt, "shot")
        XCTAssertEqual(target.markdown, "Top\nIntro <tag> & \"q\"\n![shot](<assets/my shot.png>)\nEnd")
    }

    func testCutCopiesThenDeletesSelection() {
        let editor = makeEditor(markdown: "keep REMOVE", documentURL: docURL)
        editor.setSelectedRange(NSRange(location: 5, length: 6))
        let pasteboard = testPasteboard()
        XCTAssertTrue(editor.copySelection(to: pasteboard))
        editor.delete(nil)
        XCTAssertEqual(editor.string, "keep ")
        XCTAssertEqual(pasteboard.string(forType: .string), "REMOVE")
    }

    // MARK: External pastes

    func testPastedImageDataIsSavedAsPNGInAssets() throws {
        let editor = makeEditor(markdown: "", documentURL: docURL)
        let pasteboard = testPasteboard()
        let tiff = try XCTUnwrap(NSImage(contentsOf: image)?.tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)
        editor.paste(from: pasteboard)

        let images = imageAttachments(in: editor.textStorage!)
        XCTAssertEqual(images.count, 1)
        let name = images[0].fileURL.lastPathComponent
        XCTAssertNotNil(name.range(of: #"^\d{8}-\d{6}-[0-9a-f]{8}\.png$"#, options: .regularExpression), name)
        XCTAssertEqual(images[0].fileURL.deletingLastPathComponent().lastPathComponent, "assets")
        XCTAssertTrue(try Data(contentsOf: images[0].fileURL).starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testPastedImageFileFromElsewhereIsImported() throws {
        let outside = try makeTempDirectory(self, name: "outside")
        let external = try writePNG(at: outside.appendingPathComponent("photo.png"))
        let editor = makeEditor(markdown: "", documentURL: docURL)
        let pasteboard = testPasteboard()
        pasteboard.writeObjects([external as NSURL])
        editor.paste(from: pasteboard)

        let images = imageAttachments(in: editor.textStorage!)
        XCTAssertEqual(images.count, 1)
        XCTAssertTrue(images[0].fileURL.path.contains("/Source Folder/assets/"))
    }

    func testRichTextPastesAsPlainText() {
        let editor = makeEditor(markdown: "", documentURL: docURL)
        let pasteboard = testPasteboard()
        let rtf = NSAttributedString(string: "styled", attributes: [.font: NSFont.boldSystemFont(ofSize: 30)])
        pasteboard.writeObjects([rtf])
        editor.paste(from: pasteboard)
        XCTAssertEqual(editor.string, "styled")
        let font = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, EditorStyle.fontSize)
    }
}
