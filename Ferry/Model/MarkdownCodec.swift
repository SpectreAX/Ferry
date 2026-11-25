import AppKit

/// Converts between Markdown source and an attributed string with inline `ImageAttachment`s.
enum MarkdownCodec {
    /// `![alt](<path>)` or `![alt](path)`. Titles and nested parens are not supported (left as text).
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[([^\]\n]*)\]\((?:<([^<>\n]+)>|([^()\s<>]+))\)"#)

    // MARK: Load

    static func attributedString(from markdown: String, baseDirectory: URL?,
                                 attributes: [NSAttributedString.Key: Any] = EditorStyle.baseAttributes) -> NSAttributedString {
        let source = markdown as NSString
        let result = NSMutableAttributedString()
        var cursor = 0
        for match in imagePattern.matches(in: markdown, range: NSRange(location: 0, length: source.length)) {
            let alt = source.substring(with: match.range(at: 1))
            let pathRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            let raw = source.substring(with: match.range)
            guard let url = resolve(source.substring(with: pathRange), baseDirectory: baseDirectory),
                  let attachment = ImageAttachment(fileURL: url, alt: alt, markdownSource: raw)
            else { continue } // missing or unreadable: keep the Markdown text untouched
            let before = NSRange(location: cursor, length: match.range.location - cursor)
            result.append(NSAttributedString(string: source.substring(with: before), attributes: attributes))
            result.append(attachmentString(attachment, attributes: attributes))
            cursor = NSMaxRange(match.range)
        }
        result.append(NSAttributedString(string: source.substring(from: cursor), attributes: attributes))
        return result
    }

    static func attachmentString(_ attachment: ImageAttachment,
                                 attributes: [NSAttributedString.Key: Any] = EditorStyle.baseAttributes) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Resolves an image path (absolute, `~`, `file://`, or relative to the document) to an existing file URL.
    static func resolve(_ path: String, baseDirectory: URL?) -> URL? {
        let candidates = [path, path.removingPercentEncoding].compactMap { $0 }
        for candidate in candidates {
            let url: URL?
            if candidate.hasPrefix("file://") {
                url = URL(string: candidate)
            } else if candidate.contains("://") {
                url = nil // remote images stay as text
            } else {
                let expanded = (candidate as NSString).expandingTildeInPath
                if expanded.hasPrefix("/") {
                    url = URL(fileURLWithPath: expanded, isDirectory: false)
                } else {
                    url = baseDirectory?.appendingPathComponent(candidate, isDirectory: false).standardizedFileURL
                }
            }
            if let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: Save

    /// Serializes back to Markdown. Parsed images keep their original text; new images use relative paths.
    static func markdown(from attributed: NSAttributedString, baseDirectory: URL?) -> String {
        var output = ""
        let string = attributed.string as NSString
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else {
                output += string.substring(with: range)
                return
            }
            guard let image = attachment as? ImageAttachment else { return } // foreign attachments are dropped
            for _ in 0..<range.length {
                output += image.markdownSource ?? reference(for: image.fileURL, alt: image.alt, baseDirectory: baseDirectory)
            }
        }
        return output
    }

    static func reference(for fileURL: URL, alt: String, baseDirectory: URL?) -> String {
        imageMarkdown(alt: alt, path: relativePath(of: fileURL, to: baseDirectory) ?? fileURL.path)
    }

    /// `![alt](path)`, switching to `![alt](<path>)` when the path has spaces, non-ASCII, or parens.
    static func imageMarkdown(alt: String, path: String, forceAngleBrackets: Bool = false) -> String {
        let needsBrackets = forceAngleBrackets || path.unicodeScalars.contains {
            $0.value <= 0x20 || $0.value >= 0x7F || "()<>".unicodeScalars.contains($0)
        }
        let safeAlt = alt.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\n", with: " ")
        return needsBrackets ? "![\(safeAlt)](<\(path)>)" : "![\(safeAlt)](\(path))"
    }

    /// Path of `fileURL` relative to `directory`, or nil if it isn't inside it.
    static func relativePath(of fileURL: URL, to directory: URL?) -> String? {
        guard let directory else { return nil }
        let dir = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let file = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        return file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : nil
    }
}
