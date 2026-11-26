import AppKit

/// Base typography shared by the editor, the codec, and the highlighter.
enum EditorStyle {
    static let defaultFontSize: CGFloat = 14
    static let minFontSize: CGFloat = 10
    static let maxFontSize: CGFloat = 28

    /// The text size from View › Bigger / Smaller / Actual Size, kept within 10…28 pt.
    static var fontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: SettingsKeys.editorFontSize)
        return stored == 0 ? defaultFontSize : clamped(CGFloat(stored))
    }

    static func clamped(_ size: CGFloat) -> CGFloat { min(max(size.rounded(), minFontSize), maxFontSize) }

    static var bodyFont: NSFont { NSFont.systemFont(ofSize: fontSize) }
    static var codeFont: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular) }

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
        let steps: [CGFloat] = [10, 6, 3, 1, 1, 1] // 24, 20, 17, 15, 15, 15 at the default 14 pt
        return NSFont.systemFont(ofSize: fontSize + steps[max(0, min(level, 6) - 1)], weight: .bold)
    }
}
