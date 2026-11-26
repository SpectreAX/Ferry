import AppKit
import XCTest
@testable import Ferry

/// A temporary folder that is deleted at the end of the test.
func makeTempDirectory(_ testCase: XCTestCase, name: String = "doc") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FerryTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    return url
}

/// Writes a small solid-color PNG and returns its URL.
@discardableResult
func writePNG(at url: URL, size: Int = 8) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(deviceRed: 0.2, green: 0.6, blue: 0.7, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

func testPasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(name: .init("ferry.test"))
    pasteboard.clearContents()
    return pasteboard
}

/// An editor showing `markdown` for a document at `documentURL`.
func makeEditor(markdown: String, documentURL: URL, copyMode: CopyMode = .attachments) -> EditorTextView {
    let editor = EditorTextView.make()
    editor.documentURLProvider = { documentURL }
    editor.copyMode = { copyMode }
    let twoStep = TwoStepClipboard()
    twoStep.swapDelay = 0.05
    editor.twoStepClipboard = twoStep
    editor.clipboardAttachmentsDirectory = documentURL.deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Clipboard-\(UUID().uuidString)", isDirectory: true)
    editor.textStorage?.setAttributedString(
        MarkdownCodec.attributedString(from: markdown, baseDirectory: documentURL.deletingLastPathComponent()))
    return editor
}

func imageAttachments(in attributed: NSAttributedString) -> [ImageAttachment] {
    var result: [ImageAttachment] = []
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if let image = value as? ImageAttachment { result.append(image) }
    }
    return result
}
