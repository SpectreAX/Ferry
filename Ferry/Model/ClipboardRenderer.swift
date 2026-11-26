import Foundation

/// Renders a `Fragment` into the clipboard representations used by AI apps.
enum ClipboardRenderer {
    /// Markdown with absolute image paths, e.g. `![alt](</abs/path.png>)` (Codex / Claude Code read the path).
    static func aiMarkdown(_ fragment: Fragment) -> String {
        fragment.segments.map { segment in
            if let image = segment.image {
                return MarkdownCodec.imageMarkdown(alt: image.alt, path: image.path, forceAngleBrackets: true)
            }
            return segment.text ?? ""
        }.joined()
    }

    /// Text for the second paste in "paste twice" mode: attached images become `[Image N]` (or
    /// `[Image N: alt]`), numbered in attachment order; images that weren't attached keep their Markdown.
    static func textWithImagePlaceholders(_ fragment: Fragment, attached paths: [String]) -> String {
        fragment.segments.map { segment in
            guard let image = segment.image else { return segment.text ?? "" }
            guard let index = paths.firstIndex(of: image.path) else {
                return MarkdownCodec.imageMarkdown(alt: image.alt, path: image.path, forceAngleBrackets: true)
            }
            return image.alt.isEmpty ? "[Image \(index + 1)]" : "[Image \(index + 1): \(image.alt)]"
        }.joined()
    }

    /// HTML with escaped text, `<br>` line breaks, and `file://` image references (never base64).
    static func html(_ fragment: Fragment) -> String {
        var html = #"<meta charset="utf-8">"#
        for segment in fragment.segments {
            if let image = segment.image {
                let width = image.displayWidth.map { #" width="\#(Int($0.rounded()))""# } ?? ""
                html += #"<img src="\#(escape(fileURLString(image.path)))" alt="\#(escape(image.alt))"\#(width)>"#
            } else if let text = segment.text {
                html += escape(text)
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: "\n", with: "<br>")
            }
        }
        return html
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(char)
            }
        }
        return out
    }

    /// Percent-encoded `file:///…` URL for an absolute path.
    static func fileURLString(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).absoluteString
    }
}
