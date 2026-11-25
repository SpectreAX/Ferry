import AppKit

/// "Hide Markdown Syntax": hides the glyphs of `.ferryHideableMarker` characters in layout only. The text,
/// undo, saving and copying never change. The paragraph with the cursor keeps its syntax visible, so what you
/// edit always shows its Markdown. A selection (drag, ⌘A) keeps the current paragraph revealed instead of
/// following the mouse, so text doesn't jump while you select.
final class SyntaxHider: NSObject, NSLayoutManagerDelegate {
    private(set) var isEnabled = false
    /// The paragraph shown with its syntax.
    private(set) var revealed: NSRange?
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init()
        textView.layoutManager?.delegate = self
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled, let storage = textView?.textStorage else { return }
        isEnabled = enabled
        revealed = enabled ? caretParagraph() : nil
        refresh(NSRange(location: 0, length: storage.length))
    }

    /// Call when the selection changed, and after an edit was restyled.
    func update() {
        guard isEnabled, let textView, !textView.hasMarkedText(), textView.selectedRange().length == 0 else { return }
        let paragraph = caretParagraph()
        guard paragraph != revealed else { return }
        let previous = revealed
        revealed = paragraph
        if let previous { refresh(previous) }
        if let paragraph { refresh(paragraph) }
    }

    private func caretParagraph() -> NSRange? {
        guard let textView, let storage = textView.textStorage else { return nil }
        let caret = min(textView.selectedRange().location, storage.length)
        return (storage.string as NSString).paragraphRange(for: NSRange(location: caret, length: 0))
    }

    private func refresh(_ range: NSRange) {
        guard let textView, let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }
        let location = min(range.location, storage.length)
        let clamped = NSRange(location: location, length: min(range.length, storage.length - location))
        guard clamped.length > 0 else { return }
        layoutManager.invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
        textView.needsDisplay = true
        textView.updateInsertionPointStateAndRestartTimer(true)
    }

    // MARK: NSLayoutManagerDelegate

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard isEnabled, let storage = layoutManager.textStorage else { return 0 }
        var changed: [NSLayoutManager.GlyphProperty]?
        for i in 0..<glyphRange.length {
            let index = characterIndexes[i]
            guard index < storage.length, !(revealed.map { NSLocationInRange(index, $0) } ?? false),
                  storage.attribute(.ferryHideableMarker, at: index, effectiveRange: nil) != nil else { continue }
            if changed == nil { changed = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length)) }
            changed![i] = .null
        }
        guard var changed else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: &changed, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }
}
