import AppKit
import QuickLookUI

/// The Markdown editor view (TextKit 1). ⌘C/⌘X are "Copy for AI"; paste/drop import images into `assets/`.
final class EditorTextView: NSTextView {
    /// Called after a copy that included images, with the toast message to show.
    var onCopyToast: ((String) -> Void)?
    /// Overrides the document location (tests). Defaults to the window's NSDocument file URL.
    var documentURLProvider: (() -> URL?)?
    /// The document this editor belongs to (a tab). Several tabs share one window, so the window can't tell.
    weak var owningDocument: NSDocument?
    /// Where "Copy for AI" writes the `.md` attachment (tests use a temporary folder).
    var clipboardAttachmentsDirectory = ClipboardAttachments.defaultDirectory
    /// The Settings choice for selections with images (tests set it directly).
    var copyMode: () -> CopyMode = { CopyMode.current }
    /// "Ignore Markdown Syntax When Copying" (tests set it directly). ⌥⌘C and pasting into Ferry keep the syntax.
    var stripMarkdownOnCopy: () -> Bool = { Preferences.stripMarkdownOnCopy }
    var twoStepClipboard = TwoStepClipboard.shared
    var onePasteController: () -> OnePasteController = { OnePasteController.shared }
    /// Where ⌘K looks for a URL to link to (tests use a private pasteboard).
    var linkSourcePasteboard: NSPasteboard = .general

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
        if let owningDocument { return owningDocument.fileURL }
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

    // MARK: Focus

    private var didRequestInitialFocus = false

    /// A newly opened window starts with the cursor in the text, unless something else already has the keyboard.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !didRequestInitialFocus else { return }
        didRequestInitialFocus = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.firstResponder == nil || window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }
    }

    // MARK: Tab and ⇧Tab

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText(), selectedRanges.count == 1, let storage = textStorage,
              let edit = ListIndentation.indent(in: storage.string, selection: selectedRange()) else { return super.insertTab(sender) }
        apply(edit, name: "Indent")
    }

    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText(), selectedRanges.count == 1, let storage = textStorage else { return super.insertBacktab(sender) }
        guard let edit = ListIndentation.outdent(in: storage.string, selection: selectedRange()) else { return } // nothing to outdent
        apply(edit, name: "Outdent")
    }

    /// Rebuilds the touched lines from the text storage, only adding or removing leading whitespace, so images
    /// and anything else on the lines are kept as they are.
    private func apply(_ edit: ListIndentation.Edit, name: String) {
        guard let storage = textStorage else { return }
        let rebuilt = NSMutableAttributedString()
        var cursor = edit.range.location
        for change in edit.changes {
            rebuilt.append(storage.attributedSubstring(from: NSRange(location: cursor, length: change.line.location - cursor)))
            rebuilt.append(NSAttributedString(string: String(repeating: " ", count: change.added), attributes: EditorStyle.baseAttributes))
            rebuilt.append(storage.attributedSubstring(from: NSRange(location: change.line.location + change.removed,
                                                                     length: change.line.length - change.removed)))
            cursor = NSMaxRange(change.line)
        }
        replaceMarkdown(edit.range, with: rebuilt, select: edit.selection)
        undoManager?.setActionName(name)
    }

    /// One undoable replacement with plain Markdown text, then a new selection.
    private func replaceMarkdown(_ range: NSRange, with text: String, select selection: NSRange) {
        replaceMarkdown(range, with: NSAttributedString(string: text, attributes: EditorStyle.baseAttributes), select: selection)
    }

    /// Its own undo step, never merged into the typing around it.
    private func replaceMarkdown(_ range: NSRange, with text: NSAttributedString, select selection: NSRange) {
        breakUndoCoalescing()
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(selection)
        breakUndoCoalescing()
    }

    // MARK: ⌘B, ⌘I, ⌘K

    @objc func toggleBoldMarkdown(_ sender: Any?) { toggleEmphasis("**", name: "Bold") }
    @objc func toggleItalicMarkdown(_ sender: Any?) { toggleEmphasis("*", name: "Italic") }

    /// Wraps the selection in `marker`, or unwraps it when it already is (markers just outside or just inside the
    /// selection). Images in the selection are kept: the selection is never turned into plain text.
    private func toggleEmphasis(_ marker: String, name: String) {
        guard !hasMarkedText(), selectedRanges.count == 1, let storage = textStorage else { return }
        let string = storage.string as NSString
        let selection = selectedRange()
        let m = marker.utf16.count
        defer { undoManager?.setActionName(name) }
        guard selection.length > 0 else {
            return replaceMarkdown(selection, with: marker + marker, select: NSRange(location: selection.location + m, length: 0))
        }
        let outside = min(MarkdownFormatting.stars(in: string, from: selection.location, forward: false),
                          MarkdownFormatting.stars(in: string, from: NSMaxRange(selection), forward: true))
        if MarkdownFormatting.isWrapped(stars: outside, marker: marker) {
            let range = NSRange(location: selection.location - m, length: selection.length + 2 * m)
            return replaceMarkdown(range, with: storage.attributedSubstring(from: selection),
                                   select: NSRange(location: range.location, length: selection.length))
        }
        let inside = min(MarkdownFormatting.stars(in: string, from: selection.location, forward: true),
                         MarkdownFormatting.stars(in: string, from: NSMaxRange(selection), forward: false))
        if selection.length > 2 * m, MarkdownFormatting.isWrapped(stars: inside, marker: marker) {
            let inner = NSRange(location: selection.location + m, length: selection.length - 2 * m)
            return replaceMarkdown(selection, with: storage.attributedSubstring(from: inner),
                                   select: NSRange(location: selection.location, length: inner.length))
        }
        let wrapped = NSMutableAttributedString(string: marker, attributes: EditorStyle.baseAttributes)
        wrapped.append(storage.attributedSubstring(from: selection))
        wrapped.append(NSAttributedString(string: marker, attributes: EditorStyle.baseAttributes))
        replaceMarkdown(selection, with: wrapped, select: NSRange(location: selection.location + m, length: selection.length))
    }

    /// `[text](url)` with a URL from the clipboard, or `[text]()` ready for one.
    @objc func insertMarkdownLink(_ sender: Any?) {
        guard !hasMarkedText(), selectedRanges.count == 1, let storage = textStorage else { return }
        let selection = selectedRange()
        let text = (storage.string as NSString).substring(with: selection)
        let url = linkSourcePasteboard.string(forType: .string).flatMap(MarkdownFormatting.httpURL(from:))
        let link = "[" + text + "](" + (url ?? "") + ")"
        let start = selection.location
        let caret: Int
        switch (text.isEmpty, url) {
        case (false, .some): caret = start + link.utf16.count                // after the link
        case (false, nil): caret = start + text.utf16.count + 3             // inside ()
        case (true, _): caret = start + 1                                    // inside []
        }
        if text.contains("\u{FFFC}") { // keep images: wrap the attributed selection
            let wrapped = NSMutableAttributedString(string: "[", attributes: EditorStyle.baseAttributes)
            wrapped.append(storage.attributedSubstring(from: selection))
            wrapped.append(NSAttributedString(string: "](" + (url ?? "") + ")", attributes: EditorStyle.baseAttributes))
            replaceMarkdown(selection, with: wrapped, select: NSRange(location: caret, length: 0))
        } else {
            replaceMarkdown(selection, with: link, select: NSRange(location: caret, length: 0))
        }
        undoManager?.setActionName("Insert Link")
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
    override func pasteAsPlainText(_ sender: Any?) { paste(from: .general, smartLink: false) }
    override func pasteAsRichText(_ sender: Any?) { paste(from: .general) }

    /// `smartLink`: pasting a URL over selected text makes `[text](url)` (Paste and Match Style pastes it as is).
    func paste(from pasteboard: NSPasteboard, smartLink: Bool = true) {
        guard let content = FerryPasteboard.read(from: pasteboard) else { return }
        if smartLink, case .text(let raw) = content, let url = MarkdownFormatting.httpURL(from: raw), linkOverSelection(url) { return }
        insert(content, replacing: rangeForUserTextChange)
    }

    /// Turns selected text (one line, no images, not itself a URL) into a link to `url`.
    private func linkOverSelection(_ url: String) -> Bool {
        let selection = selectedRange()
        guard selection.length > 0, selectedRanges.count == 1, let storage = textStorage else { return false }
        let text = (storage.string as NSString).substring(with: selection)
        guard !text.contains("\n"), !text.contains("\u{FFFC}"), MarkdownFormatting.httpURL(from: text) == nil else { return false }
        replaceMarkdown(selection, with: "[" + text + "](" + url + ")", select: NSRange(location: selection.location + text.utf16.count + url.utf16.count + 4, length: 0))
        return true
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
            attributes[.ferryLinkURL] = nil
            attributes[.ferryTaskCheckbox] = nil
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
        guard let document = owningDocument ?? window.flatMap({ NSDocumentController.shared.document(for: $0) }) else { return }
        pendingAfterSave = action
        document.save(withDelegate: self, didSave: #selector(document(_:didSave:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let action = pendingAfterSave
        pendingAfterSave = nil
        if didSave, let url = document.fileURL { action?(url) }
    }

    // MARK: Images: Quick Look and context menu

    /// The character drawn under a point in view coordinates: on its glyph, not beside it past the line's end.
    func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(inContainer)
        else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < storage.length ? index : nil
    }

    /// The image under a point: on the picture itself.
    func imageAttachment(at point: NSPoint) -> (attachment: ImageAttachment, characterIndex: Int)? {
        guard let index = characterIndex(at: point),
              let image = textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? ImageAttachment,
              FileManager.default.fileExists(atPath: image.fileURL.path) else { return nil }
        return (image, index)
    }

    /// The link (http, https, mailto) under a point: its text, or its target while the syntax shows.
    func linkURL(at point: NSPoint) -> URL? {
        characterIndex(at: point).flatMap { textStorage?.attribute(.ferryLinkURL, at: $0, effectiveRange: nil) as? URL }
    }

    /// The three characters of the task box (`[ ]`, `[x]`) under a point.
    func taskCheckboxRange(at point: NSPoint) -> NSRange? {
        guard let index = characterIndex(at: point), let storage = textStorage else { return nil }
        var box = NSRange()
        guard storage.attribute(.ferryTaskCheckbox, at: index, longestEffectiveRange: &box,
                                in: NSRange(location: 0, length: storage.length)) != nil, box.length == 3 else { return nil }
        let text = (storage.string as NSString).substring(with: box)
        return text.hasPrefix("[") && text.hasSuffix("]") ? box : nil
    }

    private static let clickModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Drag an image's resize handle: resize it. Double-click an image: Quick Look. ⌘-click a link: open it.
    /// Click a task box: check or uncheck it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection(Self.clickModifiers)
        if event.clickCount == 1, modifiers.isEmpty, !hasMarkedText(), beginImageResize(at: point) { return }
        if event.clickCount == 2, let hit = imageAttachment(at: point) {
            setSelectedRange(NSRange(location: hit.characterIndex, length: 1))
            showQuickLook(hit.attachment.fileURL)
            return
        }
        if event.clickCount == 1, modifiers == .command, let url = linkURL(at: point) {
            NSWorkspace.shared.open(url)
            return
        }
        if event.clickCount == 1, modifiers.isEmpty, !hasMarkedText(), let box = taskCheckboxRange(at: point) {
            toggleTask(box)
            return
        }
        super.mouseDown(with: event)
    }

    /// `[ ]` ↔ `[x]` (undoable).
    func toggleTask(_ box: NSRange) {
        guard let storage = textStorage else { return }
        let mark = NSRange(location: box.location + 1, length: 1)
        let next = (storage.string as NSString).substring(with: mark) == " " ? "x" : " "
        breakUndoCoalescing()
        guard shouldChangeText(in: mark, replacementString: next) else { return }
        storage.replaceCharacters(in: mark, with: next)
        didChangeText()
        breakUndoCoalescing()
        undoManager?.setActionName(next == "x" ? "Check Task" : "Uncheck Task")
    }

    // MARK: Pointer over links and task boxes

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoverCursor(event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateHoverCursor(event.modifierFlags)
    }

    /// A pointing hand where a click does something: a link with ⌘ held, a task box with no modifier.
    private func updateHoverCursor(_ flags: NSEvent.ModifierFlags) {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        let modifiers = flags.intersection(Self.clickModifiers)
        if resizeSession != nil || modifiers.isEmpty && resizeHandleHit(at: point) != nil { return NSCursor.resizeLeftRight.set() }
        let clickable = modifiers == .command && linkURL(at: point) != nil || modifiers.isEmpty && taskCheckboxRange(at: point) != nil
        (clickable ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    /// The image a context-menu item acts on: this one, even when the same file appears more than once.
    final class ImageMenuTarget: NSObject {
        let characterIndex: Int
        let attachment: ImageAttachment
        let size: CGFloat?
        let operation: ImageTransform.Operation?
        init(_ characterIndex: Int, _ attachment: ImageAttachment, size: CGFloat? = nil, operation: ImageTransform.Operation? = nil) {
            self.characterIndex = characterIndex
            self.attachment = attachment
            self.size = size
            self.operation = operation
        }
    }

    /// Right-clicking an image adds Quick Look, Reveal in Finder, Open Image, Size, flips and quarter turns above
    /// the usual items; a link adds Open Link and Copy Link.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: Selector, _ object: Any) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            items.append(item)
        }
        if let hit = imageAttachment(at: point) {
            let url = hit.attachment.fileURL
            add("Quick Look", #selector(quickLookImage(_:)), url)
            add("Reveal in Finder", #selector(revealImage(_:)), url)
            add("Open Image", #selector(openImage(_:)), url)
            items.append(.separator())
            let size = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
            size.submenu = sizeMenu(for: hit.characterIndex, hit.attachment)
            items.append(size)
            for operation in ImageTransform.Operation.allCases {
                add(operation.name, #selector(transformImageFromMenu(_:)), ImageMenuTarget(hit.characterIndex, hit.attachment, operation: operation))
            }
        } else if let url = linkURL(at: point) {
            add("Open Link", #selector(openLink(_:)), url)
            add("Copy Link", #selector(copyLink(_:)), url)
        } else {
            return menu
        }
        for (offset, item) in (items + [.separator()]).enumerated() { menu.insertItem(item, at: offset) }
        return menu
    }

    /// 25 %, 50 %, 75 % of the text width, and Fit Width (the image's own size, never wider than the text).
    private func sizeMenu(for index: Int, _ attachment: ImageAttachment) -> NSMenu {
        let menu = NSMenu()
        let available = textContainer.map(ImageAttachmentCell.availableWidth(in:)) ?? 600
        for percent in [25, 50, 75] {
            let width = floor(available * CGFloat(percent) / 100)
            let item = NSMenuItem(title: "\(percent)%", action: #selector(resizeImageFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ImageMenuTarget(index, attachment, size: width)
            item.state = attachment.displayWidth.map { abs($0 - width) < 1 } ?? false ? .on : .off
            menu.addItem(item)
        }
        let fit = NSMenuItem(title: "Fit Width", action: #selector(resizeImageFromMenu(_:)), keyEquivalent: "")
        fit.target = self
        fit.representedObject = ImageMenuTarget(index, attachment)
        fit.state = attachment.displayWidth == nil ? .on : .off
        menu.addItem(fit)
        return menu
    }

    @objc private func resizeImageFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ImageMenuTarget, isStill(target) else { return }
        resizeImage(at: target.characterIndex, width: target.size)
    }

    @objc private func transformImageFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ImageMenuTarget, let operation = target.operation, isStill(target) else { return }
        transformImage(at: target.characterIndex, operation: operation)
    }

    /// The menu's image is still where it was (nothing was edited while the menu was open).
    private func isStill(_ target: ImageMenuTarget) -> Bool {
        imageAttachment(atCharacter: target.characterIndex) === target.attachment
    }

    private func imageAttachment(atCharacter index: Int) -> ImageAttachment? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        return storage.attribute(.attachment, at: index, effectiveRange: nil) as? ImageAttachment
    }

    // MARK: Image size and orientation

    /// Shows the image at `width` points (nil: its own size, fitted to the text). The file is untouched; saved as
    /// `<img … width="…">` or, without a width, `![alt](path)`. One undo step; the image stays selected.
    func resizeImage(at index: Int, width: CGFloat?) {
        guard let old = imageAttachment(atCharacter: index),
              let new = ImageAttachment(fileURL: old.fileURL, alt: old.alt, displayWidth: width.map { $0.rounded() }) else { return }
        replaceImage(at: index, with: new, name: width == nil ? "Reset Image Size" : "Resize Image")
    }

    /// Flips or turns the image's pixels into a new PNG in `assets/` (the original file is kept) and shows that
    /// instead, keeping its alt text and width. One undo step brings back the original.
    func transformImage(at index: Int, operation: ImageTransform.Operation) {
        transformImage(at: index, operation: operation, documentURL: documentURL)
    }

    private func transformImage(at index: Int, operation: ImageTransform.Operation, documentURL targetURL: URL?) {
        guard let old = imageAttachment(atCharacter: index) else { return }
        guard let targetURL else {
            return saveDocumentFirst { [weak self] savedURL in
                guard let self, self.imageAttachment(atCharacter: index) === old else { return }
                self.transformImage(at: index, operation: operation, documentURL: savedURL)
            }
        }
        guard let data = ImageTransform.transform(fileURL: old.fileURL, operation: operation),
              let url = try? AssetStore.saveImage(data: data, documentURL: targetURL),
              let new = ImageAttachment(fileURL: url, alt: old.alt, displayWidth: old.displayWidth) else { return NSSound.beep() }
        replaceImage(at: index, with: new, name: operation.name.replacingOccurrences(of: " 90°", with: ""))
    }

    private func replaceImage(at index: Int, with image: ImageAttachment, name: String) {
        replaceMarkdown(NSRange(location: index, length: 1), with: MarkdownCodec.attachmentString(image),
                        select: NSRange(location: index, length: 1))
        undoManager?.setActionName(name)
    }

    // MARK: Resize handle

    private struct ResizeSession {
        let characterIndex: Int
        let attachment: ImageAttachment
        let startX: CGFloat
        let startWidth: CGFloat
        var width: CGFloat
    }

    private var resizeSession: ResizeSession?

    /// Where an image is drawn, in view coordinates.
    func imageFrame(at index: Int) -> NSRect? {
        guard imageAttachment(atCharacter: index) != nil, let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    /// A 14 pt square inset 4 pt from the image's bottom-right corner; none for images smaller than 40 pt.
    func imageResizeHandleRect(for imageFrame: NSRect) -> NSRect? {
        guard imageFrame.width >= 40, imageFrame.height >= 40 else { return nil }
        return NSRect(x: imageFrame.maxX - 18, y: imageFrame.maxY - 18, width: 14, height: 14) // flipped: maxY is the bottom
    }

    /// The image whose resize handle is under the point.
    private func resizeHandleHit(at point: NSPoint) -> (index: Int, attachment: ImageAttachment, frame: NSRect)? {
        guard let hit = imageAttachment(at: point), let frame = imageFrame(at: hit.characterIndex),
              imageResizeHandleRect(for: frame)?.contains(point) == true else { return nil }
        return (hit.characterIndex, hit.attachment, frame)
    }

    private func beginImageResize(at point: NSPoint) -> Bool {
        guard let hit = resizeHandleHit(at: point) else { return false }
        setSelectedRange(NSRange(location: hit.index, length: 1))
        resizeSession = ResizeSession(characterIndex: hit.index, attachment: hit.attachment, startX: point.x,
                                      startWidth: hit.frame.width, width: hit.frame.width)
        NSCursor.resizeLeftRight.set()
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var session = resizeSession, let textContainer, let cell = session.attachment.cell else { return super.mouseDragged(with: event) }
        let x = convert(event.locationInWindow, from: nil).x
        session.width = floor(min(max(session.startWidth + x - session.startX, cell.minimumWidth),
                                  ImageAttachmentCell.availableWidth(in: textContainer)))
        resizeSession = session
        cell.liveWidth = session.width // display only: the text and the document don't change until the drag ends
        relayoutImage(at: session.characterIndex)
    }

    override func mouseUp(with event: NSEvent) {
        guard let session = resizeSession else { return super.mouseUp(with: event) }
        resizeSession = nil
        session.attachment.cell?.liveWidth = nil
        if abs(session.width - session.startWidth) >= 2 {
            resizeImage(at: session.characterIndex, width: session.width)
        } else {
            relayoutImage(at: session.characterIndex)
        }
        needsDisplay = true
        updateHoverCursor(event.modifierFlags)
    }

    private func relayoutImage(at index: Int) {
        guard let layoutManager, let storage = textStorage, index < storage.length else { return }
        let range = NSRange(location: index, length: 1)
        layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.invalidateDisplay(forCharacterRange: range)
        needsDisplay = true
    }

    /// The resize handle on the selected image; while dragging, an outline and the width in points.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let index: Int
        if let session = resizeSession {
            index = session.characterIndex
        } else {
            let selection = selectedRange()
            guard selection.length == 1, selectedRanges.count == 1, imageAttachment(atCharacter: selection.location) != nil else { return }
            index = selection.location
        }
        guard let frame = imageFrame(at: index) else { return }
        if let session = resizeSession {
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let outline = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            let label = "\(Int(session.width)) pt" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                             .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attributes)
            let pill = NSRect(x: frame.minX + 6, y: frame.maxY - size.height - 12, width: size.width + 12, height: size.height + 6)
            if pill.maxX < frame.maxX - 22 {
                NSColor.black.withAlphaComponent(0.6).setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                label.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 3), withAttributes: attributes)
            }
        }
        guard let handle = imageResizeHandleRect(for: frame) else { return }
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let grip = NSBezierPath() // two diagonal strokes
        grip.lineWidth = 1.2
        grip.move(to: NSPoint(x: handle.maxX - 3, y: handle.minY + 5)); grip.line(to: NSPoint(x: handle.minX + 5, y: handle.maxY - 3))
        grip.move(to: NSPoint(x: handle.maxX - 3, y: handle.minY + 9)); grip.line(to: NSPoint(x: handle.minX + 9, y: handle.maxY - 3))
        grip.stroke()
    }

    /// The handle appears and disappears with the selection.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let before = selectedRange()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        for range in [before, selectedRange()] where range.length == 1 {
            if let frame = imageFrame(at: range.location) { setNeedsDisplay(frame.insetBy(dx: -2, dy: -2)) }
        }
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        (sender.representedObject as? URL).map { NSWorkspace.shared.open($0) }
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onePasteController().standDown()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
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
