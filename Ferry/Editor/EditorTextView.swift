import AppKit
import QuickLookUI

/// The Markdown editor view (TextKit 1). ⌘C/⌘X are "Copy for AI"; paste/drop import images into `assets/`.
final class EditorTextView: NSTextView {
    /// Called after a copy that included images, with the toast message to show.
    var onCopyToast: ((String) -> Void)?
    /// Overrides the document location (tests). Defaults to the window's NSDocument file URL.
    var documentURLProvider: (() -> URL?)?
    /// Where "Copy for AI" writes the `.md` attachment (tests use a temporary folder).
    var clipboardAttachmentsDirectory = ClipboardAttachments.defaultDirectory
    /// The Settings choice for selections with images (tests set it directly).
    var copyMode: () -> CopyMode = { CopyMode.current }
    /// "Ignore Markdown Syntax When Copying" (tests set it directly). ⌥⌘C and pasting into Ferry keep the syntax.
    var stripMarkdownOnCopy: () -> Bool = { Preferences.stripMarkdownOnCopy }
    var twoStepClipboard = TwoStepClipboard.shared
    var onePasteController: () -> OnePasteController = { OnePasteController.shared }

    private var ownedTextStorage: NSTextStorage?
    private var pendingAfterSave: ((URL) -> Void)?

    /// Builds an explicit TextKit 1 stack (NSTextView's default initializers use TextKit 2).
    static func make() -> EditorTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.ownedTextStorage = storage
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 28, height: 24)
        view.isRichText = true // required to hold attachments; formatting from outside is never imported
        view.importsGraphics = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.typingAttributes = EditorStyle.baseAttributes
        view.registerForDraggedTypes(view.readablePasteboardTypes)
        return view
    }

    var documentURL: URL? {
        if let documentURLProvider { return documentURLProvider() }
        guard let window else { return nil }
        return NSDocumentController.shared.document(for: window)?.fileURL ?? window.representedURL
    }

    var markdown: String {
        MarkdownCodec.markdown(from: textStorage ?? NSAttributedString(), baseDirectory: documentURL?.deletingLastPathComponent())
    }

    // MARK: Lists

    /// Return continues a list or quote, and ends it on an empty item. Input methods confirm candidates with
    /// Return without reaching here, and anything unusual (multiple selections) gets a plain newline.
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), selectedRanges.count == 1, let storage = textStorage else { return super.insertNewline(sender) }
        let caret = selectedRange()
        let string = storage.string as NSString
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        string.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: caret.location, length: 0))
        let before = string.substring(with: NSRange(location: lineStart, length: caret.location - lineStart))
        let afterEnd = max(contentsEnd, NSMaxRange(caret))
        let rest = string.substring(with: NSRange(location: NSMaxRange(caret), length: afterEnd - NSMaxRange(caret)))

        switch ListContinuation.action(line: before, rest: rest) {
        case .insert(let text)?:
            insertText(text, replacementRange: caret)
        case .end(let markerLength)?:
            insertText("", replacementRange: NSRange(location: lineStart, length: markerLength))
        case nil:
            super.insertNewline(sender)
        }
    }

    // MARK: Copy

    override func copy(_ sender: Any?) {
        copySelection(to: .general)
    }

    override func cut(_ sender: Any?) {
        guard copySelection(to: .general) else { return }
        delete(sender)
        undoManager?.setActionName("Cut")
    }

    @objc func copyAsPlainMarkdown(_ sender: Any?) {
        copyPlainMarkdown(to: .general)
    }

    /// Writes the selection in "Copy for AI" format. Returns false (and writes nothing) with no selection.
    @discardableResult
    func copySelection(to pasteboard: NSPasteboard) -> Bool {
        guard let fragment = selectedFragment() else { return false }
        let strip = stripMarkdownOnCopy()
        let hasText = TwoStepClipboard.hasText(strip ? fragment.strippingMarkdown() : fragment) // what other apps get
        if copyMode() == .oneCommandV, let payload = OnePastePayload(fragment: fragment, stripMarkdown: strip) {
            let directory = clipboardAttachmentsDirectory, name = attachmentName()
            let armed = onePasteController().arm(payload) { pasteboard in
                FerryPasteboard.writeForAI(fragment, to: pasteboard, attachmentsDirectory: directory, documentName: name, stripMarkdown: strip)
            }
            if armed {
                onCopyToast?("Copied text + \(imagesLabel(payload.images.count)): one ⌘V pastes both")
                return true
            }
            // No Accessibility permission: copy as attachments and say why.
            onePasteController().standDown()
            FerryPasteboard.writeForAI(fragment, to: pasteboard, attachmentsDirectory: directory, documentName: name, stripMarkdown: strip)
            onCopyToast?("One ⌘V needs Accessibility access (Ferry › Settings). Copied as attachments.")
            return true
        }
        onePasteController().standDown() // this copy replaces any armed One ⌘V copy
        if copyMode() == .twoPastes {
            let count = twoStepClipboard.write(fragment, to: pasteboard, stripMarkdown: strip)
            if count > 0 {
                onCopyToast?(hasText ? "Paste twice: \(imagesLabel(count)), then text" : "Copied \(imagesLabel(count))")
                return true
            }
        }
        let attached = FerryPasteboard.writeForAI(fragment, to: pasteboard, attachmentsDirectory: clipboardAttachmentsDirectory,
                                                  documentName: attachmentName(), stripMarkdown: strip)
        if attached > 0 {
            onCopyToast?(hasText ? "Copied text + \(imagesLabel(attached))" : "Copied \(imagesLabel(attached))")
        }
        return true
    }

    /// `<document>.md` for the whole document, `<document> (excerpt).md` for part of it.
    private func attachmentName() -> String {
        let base = documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        let isWholeDocument = selectedRange().length == (textStorage?.length ?? 0)
        return isWholeDocument ? base : "\(base) (excerpt)"
    }

    private func imagesLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "image" : "images")"
    }

    @discardableResult
    func copyPlainMarkdown(to pasteboard: NSPasteboard) -> Bool {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return false }
        let markdown = MarkdownCodec.markdown(from: storage.attributedSubstring(from: range),
                                              baseDirectory: documentURL?.deletingLastPathComponent())
        onePasteController().standDown()
        FerryPasteboard.writePlainMarkdown(markdown, to: pasteboard)
        return true
    }

    private func selectedFragment() -> Fragment? {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return nil }
        return Fragment(attributedString: storage.attributedSubstring(from: range),
                        sourceDirectory: documentURL?.deletingLastPathComponent())
    }

    // MARK: Paste

    override func paste(_ sender: Any?) { paste(from: .general) }
    override func pasteAsPlainText(_ sender: Any?) { paste(from: .general) }
    override func pasteAsRichText(_ sender: Any?) { paste(from: .general) }

    func paste(from pasteboard: NSPasteboard) {
        guard let content = FerryPasteboard.read(from: pasteboard) else { return }
        insert(content, replacing: rangeForUserTextChange)
    }

    private func insert(_ content: PastedContent, replacing range: NSRange) {
        guard range.location != NSNotFound else { return }
        if PasteImporter.needsDocumentLocation(content), documentURL == nil {
            saveDocumentFirst { [weak self] _ in self?.insert(content, replacing: range) }
            return
        }
        let text = PasteImporter.attributedString(for: content, documentURL: documentURL, attributes: EditorStyle.baseAttributes)
        let target = clamp(range)
        replace(target, with: text)
        startPendingImageDownloads(in: NSRange(location: target.location, length: text.length))
    }

    // MARK: Web images pasted from rich content

    /// Typing right after a pending link must not extend it.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var attributes = newValue
            attributes[.ferryPendingImage] = nil
            attributes[.ferryHideableMarker] = nil
            super.typingAttributes = attributes
        }
    }

    private func startPendingImageDownloads(in range: NSRange) {
        guard let storage = textStorage, range.length > 0 else { return }
        storage.enumerateAttribute(.ferryPendingImage, in: range) { value, _, _ in
            guard let pending = value as? PendingRemoteImage else { return }
            Task { @MainActor [weak self] in
                let data = await RemoteImageLoader.data(from: pending.url)
                self?.finishPendingImage(pending, data: data)
            }
        }
    }

    /// Swaps a downloaded web image in for its Markdown link (undoable, cursor kept). On failure, or if the
    /// user edited or deleted the link meanwhile, the text stays as it is.
    private func finishPendingImage(_ pending: PendingRemoteImage, data: Data?) {
        guard let storage = textStorage else { return }
        var runs: [NSRange] = []
        storage.enumerateAttribute(.ferryPendingImage, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            if (value as? PendingRemoteImage) === pending { runs.append(run) }
        }
        var link: NSRange?
        for run in runs {
            storage.removeAttribute(.ferryPendingImage, range: run)
            let found = (storage.string as NSString).range(of: pending.markdown, range: run)
            if link == nil, found.location != NSNotFound { link = found }
        }
        guard let link, let data, let documentURL,
              let url = try? AssetStore.saveImage(data: data, documentURL: documentURL),
              let attachment = ImageAttachment(fileURL: url, alt: pending.alt),
              shouldChangeText(in: link, replacementString: "\u{FFFC}") else { return }
        let selection = selectedRange()
        let replacement = MarkdownCodec.attachmentString(attachment, attributes: EditorStyle.baseAttributes)
        storage.replaceCharacters(in: link, with: replacement)
        didChangeText()
        let delta = replacement.length - link.length
        if selection.location >= NSMaxRange(link) {
            setSelectedRange(NSRange(location: selection.location + delta, length: selection.length))
        } else if selection.location > link.location {
            setSelectedRange(NSRange(location: link.location + replacement.length, length: 0))
        }
    }

    private func replace(_ range: NSRange, with text: NSAttributedString) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: range, with: text)
        didChangeText()
        let caret = NSRange(location: range.location + text.length, length: 0)
        setSelectedRange(caret)
        scrollRangeToVisible(caret)
    }

    private func clamp(_ range: NSRange) -> NSRange {
        let length = textStorage?.length ?? 0
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    // MARK: Save before importing images into an untitled document

    private func saveDocumentFirst(then action: @escaping (URL) -> Void) {
        guard let window, let document = NSDocumentController.shared.document(for: window) else { return }
        pendingAfterSave = action
        document.save(withDelegate: self, didSave: #selector(document(_:didSave:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let action = pendingAfterSave
        pendingAfterSave = nil
        if didSave, let url = document.fileURL { action?(url) }
    }

    // MARK: Images: Quick Look and context menu

    /// The image under a point in view coordinates: on the picture itself, not beside it at the end of the line.
    func imageAttachment(at point: NSPoint) -> (attachment: ImageAttachment, characterIndex: Int)? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(inContainer)
        else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length, let image = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ImageAttachment,
              FileManager.default.fileExists(atPath: image.fileURL.path) else { return nil }
        return (image, index)
    }

    /// Double-clicking an image opens it in Quick Look.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let hit = imageAttachment(at: convert(event.locationInWindow, from: nil)) {
            setSelectedRange(NSRange(location: hit.characterIndex, length: 1))
            showQuickLook(hit.attachment.fileURL)
            return
        }
        super.mouseDown(with: event)
    }

    /// Right-clicking an image adds Quick Look, Reveal in Finder and Open Image above the usual items.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let hit = imageAttachment(at: convert(event.locationInWindow, from: nil)) else { return menu }
        let items = [
            NSMenuItem(title: "Quick Look", action: #selector(quickLookImage(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Reveal in Finder", action: #selector(revealImage(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Open Image", action: #selector(openImage(_:)), keyEquivalent: ""),
            NSMenuItem.separator(),
        ]
        for (offset, item) in items.enumerated() {
            item.target = self
            item.representedObject = hit.attachment.fileURL
            menu.insertItem(item, at: offset)
        }
        return menu
    }

    @objc private func quickLookImage(_ sender: NSMenuItem) {
        (sender.representedObject as? URL).map(showQuickLook)
    }

    @objc private func revealImage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openImage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private var quickLookURL: URL?

    private func showQuickLook(_ url: URL) {
        quickLookURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, panel.dataSource === self {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLookURL != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookURL = nil
    }

    // MARK: Drag and drop, services

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [FerryPasteboard.fragmentType, .fileURL] + FerryPasteboard.imageDataTypes + [.string]
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let content = FerryPasteboard.read(from: pboard) else { return false }
        insert(content, replacing: rangeForUserTextChange)
        return true
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [FerryPasteboard.fragmentType, .html, .string]
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let fragment = selectedFragment() else { return false }
        FerryPasteboard.writeForAI(fragment, to: pboard, attachFiles: false, stripMarkdown: stripMarkdownOnCopy())
        return true
    }
}

extension EditorTextView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { quickLookURL as NSURL? }

    /// Zooms from the image in the text.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = quickLookURL, let storage = textStorage, let layoutManager, let textContainer, let window else { return .zero }
        var frame = NSRect.zero
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard (value as? ImageAttachment)?.fileURL == url else { return }
            var rect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                                  in: textContainer)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            frame = window.convertToScreen(convert(rect, to: nil))
            stop.pointee = true
        }
        return frame
    }
}
