import AppKit

/// Base typography shared by the editor, the codec, and the highlighter.
enum EditorStyle {
    static let fontSize: CGFloat = 14
    static let bodyFont = NSFont.systemFont(ofSize: fontSize)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return style
    }()

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle]
    }

    /// Markup characters (`#`, `**`, backticks, `>`, `|`, link targets): visible but quiet.
    static var markerColor: NSColor { .tertiaryLabelColor }
    static var quoteColor: NSColor { .secondaryLabelColor }
    static var linkColor: NSColor { .linkColor }
    static var codeBackground: NSColor { .quaternaryLabelColor }

    static func headingFont(level: Int) -> NSFont {
        let sizes: [CGFloat] = [24, 20, 17, 15, 15, 15]
        return NSFont.systemFont(ofSize: sizes[max(0, min(level, 6) - 1)], weight: .bold)
    }
}
