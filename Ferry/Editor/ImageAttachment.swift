import AppKit

/// An inline image backed by a file on disk.
/// `markdownSource` is the exact text it was parsed from, written back verbatim on save (lossless round trip).
/// `displayWidth` (points) is a size chosen in Ferry; saved as `<img src="…" width="…">`. The file is untouched.
final class ImageAttachment: NSTextAttachment {
    let fileURL: URL
    let alt: String
    let markdownSource: String?
    let displayWidth: CGFloat?

    /// Returns nil when the file is missing or isn't a readable image.
    init?(fileURL: URL, alt: String, markdownSource: String? = nil, displayWidth: CGFloat? = nil) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = NSImage(contentsOf: fileURL), image.size.width > 0, image.size.height > 0
        else { return nil }
        self.fileURL = fileURL
        self.alt = alt
        self.markdownSource = markdownSource
        self.displayWidth = displayWidth.flatMap { $0 > 0 ? $0 : nil }
        super.init(data: nil, ofType: nil)
        let cell = ImageAttachmentCell(imageCell: image)
        cell.displayWidth = self.displayWidth
        attachmentCell = cell
    }

    var cell: ImageAttachmentCell? { attachmentCell as? ImageAttachmentCell }

    required init?(coder: NSCoder) { nil }
}

/// TextKit 1 cell that scales the image to fit the text container width, or to a chosen width.
final class ImageAttachmentCell: NSTextAttachmentCell {
    /// The saved width, if one was chosen.
    var displayWidth: CGFloat?
    /// The width while the resize handle is dragged (display only; nothing is saved until the drag ends).
    var liveWidth: CGFloat?

    /// The smallest width a resize may set: 48 pt, or the image's own width if it's smaller than that.
    var minimumWidth: CGFloat { min(48, image?.size.width ?? 48) }

    static func availableWidth(in textContainer: NSTextContainer) -> CGFloat {
        max(16, textContainer.size.width - 2 * textContainer.lineFragmentPadding)
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let image else { return .zero }
        let maxWidth = Self.availableWidth(in: textContainer)
        guard let target = liveWidth ?? displayWidth else {
            let scale = min(1, maxWidth / image.size.width)
            return NSRect(x: 0, y: 0, width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        }
        let width = floor(min(maxWidth, max(minimumWidth, target)))
        return NSRect(x: 0, y: 0, width: width, height: max(16, floor(width * image.size.height / image.size.width)))
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
