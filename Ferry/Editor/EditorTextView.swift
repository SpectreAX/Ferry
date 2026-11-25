import AppKit

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
        if copyMode() == .oneCommandV, let payload = OnePastePayload(fragment: fragment) {
            let directory = clipboardAttachmentsDirectory, name = attachmentName()
            let armed = onePasteController().arm(payload) { pasteboard in
                FerryPasteboard.writeForAI(fragment, to: pasteboard, attachmentsDirectory: directory, documentName: name)
            }
            if armed {
                onCopyToast?("Copied text + \(imagesLabel(payload.images.count)): one ⌘V pastes both")
                return true
            }
            // No Accessibility permission: copy as attachments and say why.
            onePasteController().standDown()
            FerryPasteboard.writeForAI(fragment, to: pasteboard, attachmentsDirectory: directory, documentName: name)
            onCopyToast?("One ⌘V needs Accessibility access (Ferry › Settings). Copied as attachments.")
            return true
        }
        onePasteController().standDown() // this copy replaces any armed One ⌘V copy
        if copyMode() == .twoPastes {
            let count = twoStepClipboard.write(fragment, to: pasteboard)
            if count > 0 {
                onCopyToast?(TwoStepClipboard.hasText(fragment) ?"Paste twice: \(imagesLabel(count)), then text" : "Copied \(imagesLabel(count))")
                return true
            }
        }
        let attached = FerryPasteboard.writeForAI(fragment, to: pasteboard,
                                                  attachmentsDirectory: clipboardAttachmentsDirectory, documentName: attachmentName())
        if attached > 0 {
            onCopyToast?(TwoStepClipboard.hasText(fragment) ? "Copied text + \(imagesLabel(attached))" : "Copied \(imagesLabel(attached))")
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
        FerryPasteboard.writeForAI(fragment, to: pboard, attachFiles: false)
        return true
    }
}
