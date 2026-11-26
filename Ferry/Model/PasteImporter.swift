import AppKit

/// Turns pasted content into editor text, importing images into the document's `assets/` as needed.
enum PasteImporter {
    /// Whether inserting this content needs the document to have a location on disk first.
    static func needsDocumentLocation(_ content: PastedContent) -> Bool {
        switch content {
        case .text: return false
        case .imageData, .imageFiles: return true
        case .fragment(let fragment): return !fragment.images.isEmpty
        case .mixed(let segments): return segments.contains(where: \.isImage)
        }
    }

    static func attributedString(for content: PastedContent, documentURL: URL?,
                                 attributes: [NSAttributedString.Key: Any] = EditorStyle.baseAttributes) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func appendText(_ text: String) { result.append(NSAttributedString(string: text, attributes: attributes)) }
        func appendImage(_ url: URL, alt: String, displayWidth: CGFloat? = nil) {
            if let attachment = ImageAttachment(fileURL: url, alt: alt, displayWidth: displayWidth) {
                result.append(MarkdownCodec.attachmentString(attachment, attributes: attributes))
            } else {
                appendText(MarkdownCodec.imageMarkdown(alt: alt, path: url.path, forceAngleBrackets: true))
            }
        }

        switch content {
        case .text(let text):
            appendText(text)
        case .imageData(let data):
            guard let documentURL, let url = try? AssetStore.saveImage(data: data, documentURL: documentURL) else { break }
            appendImage(url, alt: "")
        case .imageFiles(let urls):
            for (index, source) in urls.enumerated() {
                if index > 0 { appendText("\n") }
                let url = documentURL.flatMap { try? AssetStore.importImageFile(source, documentURL: $0) } ?? source
                appendImage(url, alt: "")
            }
        case .fragment(let fragment):
            for segment in fragment.segments {
                if let text = segment.text { appendText(text) }
                guard let image = segment.image else { continue }
                let source = URL(fileURLWithPath: image.path, isDirectory: false)
                let url = documentURL.flatMap { try? AssetStore.adoptImage(source, documentURL: $0) } ?? source
                appendImage(url, alt: image.alt, displayWidth: image.displayWidth)
            }
        case .mixed(let segments):
            for segment in segments {
                switch segment {
                case .text(let text):
                    appendText(text)
                case .imageData(let data, let alt):
                    // Saving can only fail on a disk error; the image is then left out rather than inventing a path.
                    guard let documentURL, let url = try? AssetStore.saveImage(data: data, documentURL: documentURL) else { continue }
                    appendImage(url, alt: alt)
                case .imageFile(let source, let alt):
                    let url = documentURL.flatMap { try? AssetStore.importImageFile(source, documentURL: $0) } ?? source
                    appendImage(url, alt: alt)
                case .remoteImage(let url, let alt):
                    // Inserted as its Markdown link now; the editor swaps in the downloaded asset later.
                    let pending = PendingRemoteImage(url: url, alt: alt)
                    var pendingAttributes = attributes
                    pendingAttributes[.ferryPendingImage] = pending
                    result.append(NSAttributedString(string: pending.markdown, attributes: pendingAttributes))
                }
            }
        }
        return result
    }
}
