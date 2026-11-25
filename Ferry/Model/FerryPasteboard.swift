import AppKit

/// What a paste or drop brings into the editor, in priority order.
enum PastedContent: Equatable {
    case fragment(Fragment)
    case imageFiles([URL])
    case imageData(Data)
    /// Text and images in order, from rich content copied in another app.
    case mixed([MixedSegment])
    case text(String)
}

/// Pure pasteboard read/write. Takes the pasteboard as a parameter so tests can use a private one.
enum FerryPasteboard {
    static let fragmentType = NSPasteboard.PasteboardType("dev.spectreax.ferry.fragment")
    static let imageDataTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg")]

    /// "Copy for AI".
    /// - Text only: one item with `.string`, `.html`, and the Ferry fragment.
    /// - With images: everything as attachments, because Chromium apps (Claude, Codex desktop) ignore
    ///   clipboard text whenever files are present. The first item is a `.md` file holding the text
    ///   (it also keeps `.string`, `.html` and the fragment for native apps and for pasting back into
    ///   Ferry), followed by each image file.
    /// `attachFiles: false` (drags) or a failed `.md` write keeps the text-only form.
    /// Returns the number of image files attached.
    @discardableResult
    static func writeForAI(_ fragment: Fragment, to pasteboard: NSPasteboard, attachFiles: Bool = true,
                           attachmentsDirectory: URL = ClipboardAttachments.defaultDirectory,
                           documentName: String = "Untitled") -> Int {
        let markdown = ClipboardRenderer.aiMarkdown(fragment)
        let item = NSPasteboardItem()
        item.setString(markdown, forType: .string)
        item.setString(ClipboardRenderer.html(fragment), forType: .html)
        if let json = try? JSONEncoder().encode(fragment) {
            item.setData(json, forType: fragmentType)
        }

        let imageURLs = attachableImageURLs(fragment)
        var attached: [URL] = []
        var extraFiles: [URL] = []
        if attachFiles, !imageURLs.isEmpty {
            if !TwoStepClipboard.hasText(fragment) {
                // Images only: the image files themselves (a .md would hold nothing but their paths).
                item.setString(imageURLs[0].absoluteString, forType: .fileURL)
                attached = imageURLs
                extraFiles = Array(imageURLs.dropFirst())
            } else if let file = try? ClipboardAttachments.writeMarkdown(markdown, named: documentName, in: attachmentsDirectory) {
                item.setString(file.absoluteString, forType: .fileURL)
                attached = imageURLs
                extraFiles = imageURLs
            }
        }

        pasteboard.clearContents()
        pasteboard.writeObjects([item] + extraFiles.map { $0 as NSURL })
        return attached.count
    }

    /// The fragment's image files that exist on disk, each once, in order of appearance.
    static func attachableImageURLs(_ fragment: Fragment) -> [URL] {
        var seen = Set<String>()
        return fragment.images
            .filter { seen.insert($0.path).inserted && FileManager.default.fileExists(atPath: $0.path) }
            .map { URL(fileURLWithPath: $0.path, isDirectory: false) }
    }

    /// "Copy as Plain Markdown": `.string` only.
    static func writePlainMarkdown(_ markdown: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    static func read(from pasteboard: NSPasteboard) -> PastedContent? {
        if let data = pasteboard.data(forType: fragmentType),
           let fragment = try? JSONDecoder().decode(Fragment.self, from: data) {
            return .fragment(fragment)
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let imageURLs = urls.filter(AssetStore.isImageFile)
        if !imageURLs.isEmpty { return .imageFiles(imageURLs) }

        // Rich content with images (web pages, Notes, Word…). Images alone with picture data on the clipboard
        // (a browser's "Copy Image") paste that picture directly instead of re-downloading it.
        if let segments = RichClipboardReader.read(from: pasteboard) {
            let hasText = segments.contains {
                if case .text(let text) = $0 { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                return false
            }
            if hasText || pasteboard.availableType(from: imageDataTypes) == nil { return .mixed(segments) }
        }

        // Office/Pages put a picture of copied text next to RTF; treat those as text.
        let hasRichText = pasteboard.availableType(from: [.rtf, .rtfd]) != nil
        if !hasRichText, let type = pasteboard.availableType(from: imageDataTypes),
           let data = pasteboard.data(forType: type) {
            return .imageData(data)
        }
        if let string = pasteboard.string(forType: .string) { return .text(string) }
        if let type = pasteboard.availableType(from: imageDataTypes), let data = pasteboard.data(forType: type) {
            return .imageData(data)
        }
        return nil
    }
}
