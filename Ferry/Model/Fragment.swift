import AppKit

/// A copied slice of a document: text runs and images (absolute paths). Serialized as
/// `dev.spectreax.ferry.fragment` JSON for pasting back into Ferry.
struct Fragment: Codable, Equatable {
    struct Image: Codable, Equatable {
        var path: String
        var alt: String
    }

    /// Exactly one of `text` / `image` is set.
    struct Segment: Codable, Equatable {
        var text: String?
        var image: Image?
    }

    var version = 1
    var sourceDirectory: String?
    var segments: [Segment]

    var images: [Image] { segments.compactMap(\.image) }

    init(segments: [Segment], sourceDirectory: String? = nil) {
        self.segments = segments
        self.sourceDirectory = sourceDirectory
    }

    /// Builds a fragment from editor content. Non-image attachments are dropped.
    init(attributedString: NSAttributedString, sourceDirectory: URL?) {
        var segments: [Segment] = []
        let string = attributedString.string as NSString
        attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedString.length)) { value, range, _ in
            if let image = value as? ImageAttachment {
                for _ in 0..<range.length {
                    segments.append(Segment(image: Image(path: image.fileURL.path, alt: image.alt)))
                }
            } else if value == nil {
                let text = string.substring(with: range)
                if let last = segments.last, let lastText = last.text {
                    segments[segments.count - 1].text = lastText + text
                } else {
                    segments.append(Segment(text: text))
                }
            }
        }
        self.init(segments: segments, sourceDirectory: sourceDirectory?.path)
    }
}
