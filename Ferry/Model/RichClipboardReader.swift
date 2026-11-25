import AppKit

/// One piece of rich content copied in another app, in reading order.
enum MixedSegment: Equatable {
    case text(String)
    case imageData(Data, alt: String)
    case imageFile(URL, alt: String)
    case remoteImage(URL, alt: String)

    var isImage: Bool {
        if case .text = self { return false }
        return true
    }
}

/// Reads text and images, in order, from rich content copied elsewhere: RTFD (Notes, Pages, TextEdit,
/// Safari) or HTML (browsers, Notion, Word). Text comes out plain; formatting is dropped on purpose.
enum RichClipboardReader {
    static let chromiumSourceURL = NSPasteboard.PasteboardType("org.chromium.source-url")

    /// Segments when the content contains images; nil otherwise (a plain-text paste is right then).
    static func read(from pasteboard: NSPasteboard) -> [MixedSegment]? {
        if let data = pasteboard.data(forType: .rtfd), let segments = segments(fromRTFD: data), segments.contains(where: \.isImage) {
            return segments
        }
        if let html = pasteboard.string(forType: .html) {
            let base = (pasteboard.string(forType: chromiumSourceURL) ?? pasteboard.string(forType: .URL)).flatMap(URL.init(string:))
            if let segments = segments(fromHTML: html, baseURL: base), segments.contains(where: \.isImage) { return segments }
        }
        return nil
    }

    // MARK: RTFD

    static func segments(fromRTFD data: Data) -> [MixedSegment]? {
        guard let attributed = NSAttributedString(rtfd: data, documentAttributes: nil) else { return nil }
        var builder = SegmentBuilder()
        let string = attributed.string as NSString
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else {
                builder.text(string.substring(with: range))
                return
            }
            let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents ?? attachment.image?.tiffRepresentation
            guard let data, NSImage(data: data) != nil else { return } // non-image attachments are dropped
            for _ in 0..<range.length { builder.segments.append(.imageData(data, alt: "")) }
        }
        return builder.finish()
    }

    // MARK: HTML

    private static let imageTag = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)
    private static let unsafeTags = try! NSRegularExpression(
        pattern: #"<(script|style|iframe|object|video|audio|svg|noscript|template|canvas)\b[\s\S]*?</\1\s*>|<(?:link|embed|source|track|base)\b[^>]*>|<meta\b[^>]*http-equiv[^>]*>"#,
        options: .caseInsensitive)
    private static let token = try! NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")

    static func segments(fromHTML html: String, baseURL: URL?) -> [MixedSegment]? {
        // Replace each <img> with a private-use token so the HTML importer never loads images itself,
        // then convert the rest to plain text and split it at the tokens.
        var images: [(src: String, alt: String)] = []
        let source = html as NSString
        var withTokens = ""
        var cursor = 0
        for match in imageTag.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            withTokens += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let tag = source.substring(with: match.range)
            if let src = attribute("src", in: tag), !src.isEmpty {
                withTokens += "\u{E000}\(images.count)\u{E001}"
                images.append((src, attribute("alt", in: tag) ?? ""))
            }
            cursor = NSMaxRange(match.range)
        }
        withTokens += source.substring(from: cursor)
        guard !images.isEmpty else { return nil }

        let cleaned = unsafeTags.stringByReplacingMatches(in: withTokens, range: NSRange(location: 0, length: (withTokens as NSString).length),
                                                          withTemplate: "")
        guard let text = plainText(fromHTML: cleaned) else { return nil }

        var builder = SegmentBuilder()
        let textNS = text as NSString
        var position = 0
        for match in token.matches(in: text, range: NSRange(location: 0, length: textNS.length)) {
            builder.text(textNS.substring(with: NSRange(location: position, length: match.range.location - position)))
            let index = Int(textNS.substring(with: match.range(at: 1))) ?? -1
            if images.indices.contains(index), let image = segment(src: images[index].src, alt: images[index].alt, baseURL: baseURL) {
                builder.segments.append(image)
            }
            position = NSMaxRange(match.range)
        }
        builder.text(textNS.substring(from: position))
        return builder.finish()
    }

    /// Turns an <img src> into a segment: inline data, a local file, or a web image to download.
    static func segment(src rawSource: String, alt: String, baseURL: URL?) -> MixedSegment? {
        let src = decodeEntities(rawSource).trimmingCharacters(in: .whitespacesAndNewlines)
        if src.lowercased().hasPrefix("data:") {
            guard let comma = src.firstIndex(of: ","), src[..<comma].lowercased().contains(";base64"),
                  let data = Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters),
                  NSImage(data: data) != nil else { return nil }
            return .imageData(data, alt: alt)
        }
        let absolute = src.hasPrefix("//") ? "https:" + src : src
        guard let url = URL(string: absolute, relativeTo: baseURL)?.absoluteURL
            ?? URL(string: absolute.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "", relativeTo: baseURL)?.absoluteURL
        else { return nil }
        switch url.scheme?.lowercased() {
        case "file": return .imageFile(url, alt: alt)
        case "http", "https": return .remoteImage(url, alt: alt)
        default: return nil
        }
    }

    static func plainText(fromHTML html: String) -> String? {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        else { return nil }
        return attributed.string.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            return decodeEntities((tag as NSString).substring(with: match.range(at: group)))
        }
        return nil
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Merges adjacent text and trims the trailing newline importers add.
    private struct SegmentBuilder {
        var segments: [MixedSegment] = []

        mutating func text(_ text: String) {
            let cleaned = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !cleaned.isEmpty else { return }
            if case .text(let previous)? = segments.last {
                segments[segments.count - 1] = .text(previous + cleaned)
            } else {
                segments.append(.text(cleaned))
            }
        }

        mutating func finish() -> [MixedSegment] {
            if case .text(let last)? = segments.last {
                let trimmed = String(last.reversed().drop(while: { $0 == "\n" || $0 == "\r" }).reversed())
                if trimmed.isEmpty { segments.removeLast() } else { segments[segments.count - 1] = .text(trimmed) }
            }
            return segments
        }
    }
}
