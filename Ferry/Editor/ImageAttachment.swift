import AppKit

/// An inline image backed by a file on disk.
/// `markdownSource` is the exact text it was parsed from, written back verbatim on save (lossless round trip).
final class ImageAttachment: NSTextAttachment {
    let fileURL: URL
    let alt: String
    let markdownSource: String?

    /// Returns nil when the file is missing or isn't a readable image.
    init?(fileURL: URL, alt: String, markdownSource: String? = nil) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = NSImage(contentsOf: fileURL), image.size.width > 0, image.size.height > 0
        else { return nil }
        self.fileURL = fileURL
        self.alt = alt
        self.markdownSource = markdownSource
        super.init(data: nil, ofType: nil)
        attachmentCell = ImageAttachmentCell(imageCell: image)
    }

    required init?(coder: NSCoder) { nil }
}

/// TextKit 1 cell that scales the image to fit the text container width.
final class ImageAttachmentCell: NSTextAttachmentCell {
    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let image else { return .zero }
        let maxWidth = max(16, textContainer.size.width - 2 * textContainer.lineFragmentPadding)
        let scale = min(1, maxWidth / image.size.width)
        return NSRect(x: 0, y: 0, width: floor(image.size.width * scale), height: floor(image.size.height * scale))
    }

    override func cellSize() -> NSSize { image?.size ?? .zero }
    override func cellBaselineOffset() -> NSPoint { .zero }
    override func wantsToTrackMouse() -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        // NSImage picks the best representation for the destination, so Retina stays crisp.
        image?.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                       characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}
