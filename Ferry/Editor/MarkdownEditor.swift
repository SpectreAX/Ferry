import SwiftUI
import AppKit

/// SwiftUI wrapper around `EditorTextView`.
struct MarkdownEditor: NSViewRepresentable {
    let document: MarkdownDocument
    let fileURL: URL?
    var hideMarkdownSyntax = false
    let onCopyToast: (String) -> Void
    @Environment(\.undoManager) private var undoManager

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorTextView.make()
        textView.delegate = context.coordinator
        textView.onCopyToast = onCopyToast

        if let storage = textView.textStorage {
            let content = MarkdownCodec.attributedString(from: document.markdown,
                                                         baseDirectory: fileURL?.deletingLastPathComponent())
            storage.setAttributedString(content)
            textView.setSelectedRange(NSRange(location: 0, length: 0)) // open at the top, not the last paragraph
            context.coordinator.highlighter.highlightAll(storage)
            storage.delegate = context.coordinator
        }
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
        (scrollView.documentView as? EditorTextView)?.onCopyToast = onCopyToast
        context.coordinator.hider?.setEnabled(hideMarkdownSyntax)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor
        let highlighter = SyntaxHighlighter()
        var hider: SyntaxHider?
        private var pendingHighlight: NSRange?

        init(_ parent: MarkdownEditor) { self.parent = parent }

        /// Use the document's undo manager so text edits mark the document dirty.
        func undoManager(for view: NSTextView) -> UndoManager? { parent.undoManager }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            pendingHighlight = pendingHighlight.map { NSUnionRange($0, editedRange) } ?? editedRange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? EditorTextView else { return }
            parent.document.markdown = textView.markdown
            // Never restyle while an input method is composing (Chinese/Japanese IME).
            guard !textView.hasMarkedText(), let range = pendingHighlight, let storage = textView.textStorage else { return }
            pendingHighlight = nil
            highlighter.update(storage, edited: range)
            hider?.update()
        }

        func textViewDidChangeSelection(_ notification: Notification) { hider?.update() }
    }
}
