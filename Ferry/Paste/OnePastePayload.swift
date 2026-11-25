import Foundation

/// What One ⌘V delivers: the image files first, then the text with `[Image N]` placeholders.
struct OnePastePayload: Equatable {
    let images: [URL]
    let text: String
    let fragment: Data?

    /// Claude turns pasted text of 500+ characters into an attachment; start accepting that a bit earlier.
    static let attachmentThreshold = 400
    var textMayBecomeAttachment: Bool { text.count >= Self.attachmentThreshold }

    /// Only selections with both text and images need One ⌘V; others paste fine in one step.
    init?(fragment: Fragment) {
        let images = FerryPasteboard.attachableImageURLs(fragment)
        guard !images.isEmpty, TwoStepClipboard.hasText(fragment) else { return nil }
        self.images = images
        text = ClipboardRenderer.textWithImagePlaceholders(fragment, attached: images.map(\.path))
        self.fragment = try? JSONEncoder().encode(fragment)
    }
}
