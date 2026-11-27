import SwiftUI
import AppKit

/// SwiftUI wrapper around `EditorTextView`.
struct MarkdownEditor: NSViewRepresentable {
    let document: MarkdownDocument
    let fileURL: URL?
    /// The native document (a tab): its undo manager and file location win over the environment's.
    var owner: NSDocument? = nil
    var hideMarkdownSyntax = false
    var fontSize = Double(EditorStyle.defaultFontSize)
    let onCopyToast: (String) -> Void
    @Environment(\.undoManager) private var undoManager

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorTextView.make()
        textView.delegate = context.coordinator
        textView.owningDocument = owner
        textView.onCopyToast = onCopyToast

        if let storage = textView.textStorage {
            let content = MarkdownCodec.attributedString(from: document.markdown,
                                                         baseDirectory: fileURL?.deletingLastPathComponent())
            storage.setAttributedString(content)
            textView.setSelectedRange(NSRange(location: 0, length: 0)) // open at the top, not the last paragraph
            context.coordinator.highlighter.highlightAll(storage)
            storage.delegate = context.coordinator
        }
        context.coordinator.didLoad(document.markdown, baseDirectory: fileURL?.deletingLastPathComponent())
        let hider = SyntaxHider(textView: textView)
        hider.setEnabled(hideMarkdownSyntax)
        context.coordinator.hider = hider

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        textView.onCopyToast = onCopyToast
        context.coordinator.syncFromDocument(textView, scrollView: scrollView)
        context.coordinator.applyFontSize(fontSize, to: textView)
        context.coordinator.hider?.setEnabled(hideMarkdownSyntax)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor
        let highlighter = SyntaxHighlighter()
        var hider: SyntaxHider?
        private var pendingHighlight: NSRange?
        /// What the editor last showed or wrote. The document holding anything else means it changed outside
        /// the editor: File › Revert To, or the file changed on disk and was reloaded.
        private var lastSyncedMarkdown = ""
        private var lastBaseDirectory: URL?

        init(_ parent: MarkdownEditor) { self.parent = parent }

        /// Use the document's undo manager so text edits mark the document dirty.
        func undoManager(for view: NSTextView) -> UndoManager? { documentUndoManager }

        /// Each tab's document keeps its own undo history, whichever tab is shown.
        var documentUndoManager: UndoManager? { parent.owner?.undoManager ?? parent.undoManager }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            pendingHighlight = pendingHighlight.map { NSUnionRange($0, editedRange) } ?? editedRange
        }

        private var appliedFontSize = EditorStyle.fontSize

        /// View › Bigger / Smaller / Actual Size: restyles in place (the text, undo and saved state don't change).
        func applyFontSize(_ size: Double, to textView: EditorTextView) {
            let size = EditorStyle.clamped(CGFloat(size))
            guard size != appliedFontSize, let storage = textView.textStorage else { return }
            appliedFontSize = size
            textView.typingAttributes = EditorStyle.baseAttributes
            highlighter.highlightAll(storage)
            hider?.refreshAll()
        }

        func didLoad(_ markdown: String, baseDirectory: URL?) {
            lastSyncedMarkdown = markdown
            lastBaseDirectory = baseDirectory
        }

        /// Shows the document's text when it changed outside the editor, keeping the selection and scroll
        /// position where they still fit. Also reloads once when an untitled document is first saved, so
        /// relative image links typed into it show their images.
        func syncFromDocument(_ textView: EditorTextView, scrollView: NSScrollView) {
            let markdown = parent.document.markdown
            let baseDirectory = parent.fileURL?.deletingLastPathComponent()
            let firstSave = lastBaseDirectory == nil && baseDirectory != nil && markdown.contains("![")
            guard markdown != lastSyncedMarkdown || firstSave else {
                lastBaseDirectory = baseDirectory
                return
            }
            guard let storage = textView.textStorage else { return }
            if textView.hasMarkedText() { // the new text replaces an unfinished input-method composition too
                textView.inputContext?.discardMarkedText()
                textView.unmarkText()
            }
            let selection = textView.selectedRange()
            let origin = scrollView.contentView.bounds.origin

            storage.setAttributedString(MarkdownCodec.attributedString(from: markdown, baseDirectory: baseDirectory))
            pendingHighlight = nil
            highlighter.highlightAll(storage)
            let location = min(selection.location, storage.length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, storage.length - location)))
            hider?.refreshAll()
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let maxY = max(0, textView.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: min(origin.y, maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            // Undo steps refer to the old text; replaying them on the new one would garble it.
            documentUndoManager?.removeAllActions()
            didLoad(markdown, baseDirectory: baseDirectory)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? EditorTextView else { return }
            let markdown = textView.markdown
            parent.document.markdown = markdown
            lastSyncedMarkdown = markdown
            // Never restyle while an input method is composing (Chinese/Japanese IME).
            guard !textView.hasMarkedText(), let range = pendingHighlight, let storage = textView.textStorage else { return }
            pendingHighlight = nil
            highlighter.update(storage, edited: range)
            hider?.update()
        }

        func textViewDidChangeSelection(_ notification: Notification) { hider?.update() }
    }
}
