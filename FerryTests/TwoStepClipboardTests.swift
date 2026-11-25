import XCTest
@testable import Ferry

/// "Paste twice" mode: step 1 offers only the image files; once an app reads them, the clipboard
/// switches to the text with `[Image N]` placeholders.
final class TwoStepClipboardTests: XCTestCase {
    private var dir: URL!
    private var docURL: URL!
    private var image: URL!
    private let markdown = "Intro <tag> & \"q\"\n![shot](<assets/my shot.png>)\nEnd"

    override func setUpWithError() throws {
        dir = try makeTempDirectory(self, name: "Source Folder")
        docURL = dir.appendingPathComponent("note.md")
        image = try writePNG(at: dir.appendingPathComponent("assets/my shot.png"))
    }

    private func pause(_ seconds: TimeInterval = 0.3) {
        let done = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    private func readFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func testFirstPasteGetsImagesThenClipboardSwitchesToText() {
        let editor = makeEditor(markdown: markdown, documentURL: docURL, copyMode: .twoPastes)
        var toast: String?
        editor.onCopyToast = { toast = $0 }
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        XCTAssertTrue(editor.copySelection(to: pasteboard))
        XCTAssertEqual(toast, "Paste twice: 1 image, then text")

        // Step 1: only files, no text (Chromium would drop the text anyway).
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(readFileURLs(pasteboard).map(\.path), [image.path]) // an app pastes: provider fires

        pause()
        // Step 2: the text, images as placeholders.
        XCTAssertNil(pasteboard.availableType(from: [.fileURL]))
        XCTAssertEqual(pasteboard.string(forType: .string), "Intro <tag> & \"q\"\n[Image 1: shot]\nEnd")
    }

    func testSecondStepTextCanLeaveOutSyntax() {
        let editor = makeEditor(markdown: "## Intro **now**\n![shot](<assets/my shot.png>)\n- End", documentURL: docURL, copyMode: .twoPastes)
        editor.stripMarkdownOnCopy = { true }
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        XCTAssertEqual(readFileURLs(pasteboard).map(\.path), [image.path])
        pause()
        XCTAssertEqual(pasteboard.string(forType: .string), "Intro now\n[Image 1: shot]\nEnd")
    }

    func testNoSwitchUntilAnAppReadsTheImages() {
        let editor = makeEditor(markdown: markdown, documentURL: docURL, copyMode: .twoPastes)
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        pause()
        XCTAssertNotNil(pasteboard.availableType(from: [.fileURL]))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testImagesOnlySelectionNeverSwitches() {
        let editor = makeEditor(markdown: "![shot](<assets/my shot.png>)", documentURL: docURL, copyMode: .twoPastes)
        var toast: String?
        editor.onCopyToast = { toast = $0 }
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        XCTAssertEqual(toast, "Copied 1 image")
        XCTAssertEqual(readFileURLs(pasteboard).count, 1)
        pause()
        XCTAssertEqual(readFileURLs(pasteboard).count, 1, "second paste repeats the images")
        XCTAssertNil(pasteboard.string(forType: .string))
        withExtendedLifetime(editor) {} // the provider lives as long as the editor (the app uses a shared one)
    }

    func testTextOnlySelectionIsPlainText() {
        let editor = makeEditor(markdown: "just text", documentURL: docURL, copyMode: .twoPastes)
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "just text")
        XCTAssertNil(pasteboard.availableType(from: [.fileURL]))
    }

    func testPastingIntoFerryRestoresImagesAtBothSteps() {
        let source = makeEditor(markdown: markdown, documentURL: docURL, copyMode: .twoPastes)
        source.selectAll(nil)
        let pasteboard = testPasteboard()
        source.copySelection(to: pasteboard)

        let target = makeEditor(markdown: "", documentURL: docURL)
        target.paste(from: pasteboard) // reads the fragment, not the files: no switch
        XCTAssertEqual(imageAttachments(in: target.textStorage!).count, 1)
        XCTAssertNotNil(pasteboard.availableType(from: [.fileURL]))

        _ = readFileURLs(pasteboard)
        pause()
        target.paste(from: pasteboard)
        XCTAssertEqual(imageAttachments(in: target.textStorage!).count, 2)
        XCTAssertEqual(target.markdown, markdown + markdown)
    }

    func testAnotherCopyCancelsThePendingSwitch() {
        let editor = makeEditor(markdown: markdown, documentURL: docURL, copyMode: .twoPastes)
        editor.selectAll(nil)
        let pasteboard = testPasteboard()
        editor.copySelection(to: pasteboard)
        _ = readFileURLs(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)
        pause()
        XCTAssertEqual(pasteboard.string(forType: .string), "something else")
    }
}
