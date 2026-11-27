import AppKit

/// A `.md` file as a native document (autosave, versions, revert, save panels, the unsaved-changes prompts), shown
/// as a tab in a `TabWindowController`. The text lives in `model`, which the editor edits.
final class FerryDocument: NSDocument {
    let id = UUID()
    /// Replaced (not changed) when the file is read again, so the editor notices and reloads.
    private(set) var model = MarkdownDocument()
    weak var tabWindowController: TabWindowController?

    /// New Window (⌘N): the next document gets a window of its own instead of a tab in the front window.
    static var opensInNewWindow = false

    override class var autosavesInPlace: Bool { true }

    convenience init(markdown: String) {
        self.init()
        model = MarkdownDocument(markdown: markdown)
    }

    override func data(ofType typeName: String) throws -> Data { Data(model.markdown.utf8) }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        model = MarkdownDocument(markdown: text)
        tabWindowController?.documentContentChanged(self) // Revert To, or the file changed on disk
    }

    // MARK: Windows

    /// Opening a file (⌘O, Open Recent, Finder, Dock): a new tab in the front window; New Window: a window of its own.
    override func makeWindowControllers() {
        let controller = (Self.opensInNewWindow ? nil : TabWindowController.frontmost) ?? TabWindowController()
        Self.opensInNewWindow = false
        controller.addTab(for: self)
        RecentDocuments.shared.refresh()
    }

    /// Also what NSDocumentController calls for a file that's already open: its tab comes forward.
    override func showWindows() {
        tabWindowController?.show(self)
    }

    override var windowForSheet: NSWindow? { tabWindowController?.window ?? super.windowForSheet }

    /// Before asking about unsaved changes (closing a tab or window, quitting), show this tab.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        tabWindowController?.show(self)
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    /// However a document is closed, its tab goes too.
    override func close() {
        let controller = tabWindowController
        super.close()
        controller?.documentDidClose(self)
    }

    // MARK: Title and edited state

    override var fileURL: URL? {
        didSet {
            guard fileURL != oldValue else { return }
            tabWindowController?.documentStateChanged(self, fileURLChanged: true)
            RecentDocuments.shared.refresh()
        }
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        tabWindowController?.documentStateChanged(self)
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        tabWindowController?.documentStateChanged(self)
    }

    // MARK: New tab, new window

    static func newTab() {
        opensInNewWindow = false
        NSDocumentController.shared.newDocument(nil)
    }

    static func newWindow() {
        opensInNewWindow = true
        NSDocumentController.shared.newDocument(nil)
    }
}

/// File › Open Recent, kept current as documents are opened and saved.
final class RecentDocuments: ObservableObject {
    static let shared = RecentDocuments()
    @Published private(set) var urls: [URL] = NSDocumentController.shared.recentDocumentURLs

    func refresh() {
        DispatchQueue.main.async { self.urls = NSDocumentController.shared.recentDocumentURLs }
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        urls = []
    }
}
