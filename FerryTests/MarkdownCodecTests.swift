import XCTest
@testable import Ferry

final class MarkdownCodecTests: XCTestCase {
    func testRoundTripIsLossless() throws {
        let dir = try makeTempDirectory(self)
        try writePNG(at: dir.appendingPathComponent("assets/plain.png"))
        try writePNG(at: dir.appendingPathComponent("assets/with space.png"))
        try writePNG(at: dir.appendingPathComponent("assets/猫の写真 图.png"))
        let absolute = try writePNG(at: dir.appendingPathComponent("elsewhere/abs.png"))

        let markdown = """
        # Title 你好

        Text before ![plain](assets/plain.png) and after.
        ![space](<assets/with space.png>)
        ![cjk](<assets/猫の写真 图.png>)
        ![abs](\(absolute.path))
        ![dotted](./assets/plain.png)
        ![encoded](assets/with%20space.png)
        ![missing](assets/nope.png)
        ![remote](https://example.com/a.png)
        Trailing line without newline
        """

        let attributed = MarkdownCodec.attributedString(from: markdown, baseDirectory: dir)
        let images = imageAttachments(in: attributed)
        XCTAssertEqual(images.map(\.alt), ["plain", "space", "cjk", "abs", "dotted", "encoded"])
        XCTAssertEqual(images[2].fileURL.lastPathComponent, "猫の写真 图.png")
        XCTAssertTrue(attributed.string.contains("![missing](assets/nope.png)"), "missing files stay as text")
        XCTAssertTrue(attributed.string.contains("![remote](https://example.com/a.png)"))

        XCTAssertEqual(MarkdownCodec.markdown(from: attributed, baseDirectory: dir), markdown)
    }

    func testUnsavedDocumentKeepsRelativeImagesAsText() {
        let markdown = "![a](assets/a.png)"
        let attributed = MarkdownCodec.attributedString(from: markdown, baseDirectory: nil)
        XCTAssertTrue(imageAttachments(in: attributed).isEmpty)
        XCTAssertEqual(MarkdownCodec.markdown(from: attributed, baseDirectory: nil), markdown)
    }

    func testNewAttachmentsSerializeAsRelativePaths() throws {
        let dir = try makeTempDirectory(self)
        let plain = try writePNG(at: dir.appendingPathComponent("assets/20260101-120000-abcd1234.png"))
        let spaced = try writePNG(at: dir.appendingPathComponent("assets/my shot.png"))
        let cjk = try writePNG(at: dir.appendingPathComponent("assets/截图.png"))

        let text = NSMutableAttributedString(string: "A ")
        for (url, alt) in [(plain, "p"), (spaced, "s"), (cjk, "c")] {
            text.append(MarkdownCodec.attachmentString(try XCTUnwrap(ImageAttachment(fileURL: url, alt: alt))))
        }
        XCTAssertEqual(MarkdownCodec.markdown(from: text, baseDirectory: dir),
                       "A ![p](assets/20260101-120000-abcd1234.png)![s](<assets/my shot.png>)![c](<assets/截图.png>)")
    }

    func testMissingOrInvalidImageNeverCrashes() throws {
        let dir = try makeTempDirectory(self)
        let bogus = dir.appendingPathComponent("assets/bogus.png")
        try FileManager.default.createDirectory(at: bogus.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: bogus)
        let markdown = "![x](assets/bogus.png) ![y](<>) ![z]( ) ![](assets/)"
        let attributed = MarkdownCodec.attributedString(from: markdown, baseDirectory: dir)
        XCTAssertTrue(imageAttachments(in: attributed).isEmpty)
        XCTAssertEqual(MarkdownCodec.markdown(from: attributed, baseDirectory: dir), markdown)
    }
}
