import AppKit
import SwiftUI

/// A window of document tabs under a single 38 pt title bar (`SafariTabBar`). Every tab keeps its own editor
/// alive, so switching keeps scroll position, selection and its document's undo history; only the shown one is
/// visible. The window controller's `document` is always the shown tab's document, so Save, Revert, the editor's
/// `NSDocumentController.document(for:)` and sheets all act on it.
final class TabWindowController: NSWindowController, NSWindowDelegate {
    /// The title bar's height with the compact toolbar (38 pt on most systems); measured, so the window buttons
    /// stay centered in the bar.
    static var barHeight: CGFloat = 38

    final class TabSession {
        let document: FerryDocument
        let host: NSHostingView<ContentView>
        init(document: FerryDocument, host: NSHostingView<ContentView>) {
            self.document = document
            self.host = host
        }
        var editor: EditorTextView? { Self.findEditor(in: host) }
        private static func findEditor(in view: NSView) -> EditorTextView? {
            if let editor = view as? EditorTextView { return editor }
            for subview in view.subviews { if let editor = findEditor(in: subview) { return editor } }
            return nil
        }
    }

    private(set) var strip = TabStripModel()
    private(set) var sessions: [UUID: TabSession] = [:]
    let bar = TabBarStore()
    private let editorContainer = NSView()

    /// Open tab windows. Documents only point weakly at their window, so this keeps each one alive until it closes.
    private(set) static var open: [TabWindowController] = []

    /// The front document window, which new tabs join.
    static var frontmost: TabWindowController? {
        for window in NSApp.orderedWindows where window.isVisible {
            if let controller = open.first(where: { $0.window === window }) { return controller }
        }
        // A window created a moment ago may not be on screen yet (files opening one after another).
        return open.last { $0.window?.isVisible == true } ?? open.last
    }

    var activeSession: TabSession? { strip.activeID.flatMap { sessions[$0] } }

    init() {
        let window = TabWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320 + Self.barHeight)
        // An empty compact toolbar makes the title bar 38 pt with the window buttons centered in it.
        let toolbar = NSToolbar(identifier: "FerryTabBar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        let titleBar = window.frame.height - window.contentLayoutRect.height
        if titleBar >= 28, titleBar <= 60 { Self.barHeight = titleBar }
        super.init(window: window)
        window.windowController = self // also makes this controller (and its document) part of the responder chain
        Self.open.append(self)
        shouldCloseDocument = false
        window.delegate = self
        buildContent(in: window)
        placeWindow(window)
        bar.actions = .init(controller: self)
        updateBarInset()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent(in window: NSWindow) {
        let root = NSView()
        let barHost = NSHostingView(rootView: SafariTabBar(store: bar))
        barHost.safeAreaRegions = [] // it *is* the title bar: no inset for it
        for view in [barHost, editorContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            barHost.topAnchor.constraint(equalTo: root.topAnchor),
            barHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            barHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            barHost.heightAnchor.constraint(equalToConstant: Self.barHeight),
            editorContainer.topAnchor.constraint(equalTo: barHost.bottomAnchor),
            editorContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
    }

    /// Cascades from the front window; the first window is centered.
    private func placeWindow(_ window: NSWindow) {
        if let front = Self.frontmost?.window, front !== window {
            window.setFrame(front.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        } else {
            window.center()
        }
    }

    // MARK: Tabs

    func addTab(for document: FerryDocument) {
        adopt(TabSession(document: document, host: NSHostingView(rootView: contentView(for: document))))
    }

    private func adopt(_ session: TabSession) {
        let document = session.document
        document.tabWindowController = self
        sessions[document.id] = session
        session.host.translatesAutoresizingMaskIntoConstraints = false
        session.host.safeAreaRegions = [] // below the bar already
        session.host.isHidden = true
        editorContainer.addSubview(session.host)
        NSLayoutConstraint.activate([
            session.host.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            session.host.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            session.host.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            session.host.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
        ])
        strip.add(document.id)
        activate()
    }

    private func contentView(for document: FerryDocument) -> ContentView {
        ContentView(document: document.model, fileURL: document.fileURL, owner: document)
    }

    func show(_ document: FerryDocument) {
        select(document.id)
        window?.makeKeyAndOrderFront(nil)
    }

    func select(_ id: UUID) {
        strip.select(id)
        activate()
    }

    /// Shows the active tab and points the window (document, title, proxy icon, edited dot) at it.
    private func activate() {
        guard let session = activeSession, let window else { return updateBar() }
        for other in sessions.values where other !== session { other.host.isHidden = true }
        session.host.isHidden = false
        document = session.document
        syncWindow(with: session.document)
        updateBar()
        if let editor = session.editor { window.makeFirstResponder(editor) }
    }

    private func syncWindow(with document: FerryDocument) {
        window?.title = document.displayName
        window?.representedURL = document.fileURL
        window?.isDocumentEdited = document.isDocumentEdited
    }

    func selectNext() { strip.selectNext(); activate() }
    func selectPrevious() { strip.selectPrevious(); activate() }

    func move(_ id: UUID, to index: Int) {
        strip.move(id, to: index)
        updateBar()
    }

    // MARK: Document changes

    func documentStateChanged(_ document: FerryDocument, fileURLChanged: Bool = false) {
        guard let session = sessions[document.id] else { return }
        if fileURLChanged { session.host.rootView = contentView(for: document) } // the editor's base folder
        if session === activeSession { syncWindow(with: document) }
        updateBar()
    }

    /// The text was read again (Revert To, a reload after a change on disk): the editor shows the new text.
    func documentContentChanged(_ document: FerryDocument) {
        sessions[document.id]?.host.rootView = contentView(for: document)
        updateBar()
    }

    // MARK: Closing

    /// ⌘W: closes the shown tab (asking about unsaved changes); the last tab closes the window.
    @objc func closeActiveTab(_ sender: Any?) {
        guard let session = activeSession else { return window?.performClose(sender) ?? () }
        closeTab(session.document.id)
    }

    func closeTab(_ id: UUID) {
        guard let session = sessions[id] else { return }
        close([session.document]) { _ in }
    }

    func closeOtherTabs(keeping id: UUID) {
        close(strip.otherIDs(keeping: id).compactMap { sessions[$0]?.document }) { _ in }
    }

    /// Asks each document in turn (each shows its tab first); stops at the first Cancel.
    private var pendingClose: (rest: [FerryDocument], done: (Bool) -> Void)?

    private func close(_ documents: [FerryDocument], then done: @escaping (Bool) -> Void) {
        guard pendingClose == nil else { return } // a prompt is already open: ⌘W again must not replace its queue
        guard let document = documents.first else { return done(true) }
        pendingClose = (Array(documents.dropFirst()), done)
        document.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let pending = pendingClose else { return }
        pendingClose = nil
        guard shouldClose else { return pending.done(false) }
        document.close()
        close(pending.rest, then: pending.done)
    }

    /// Called by `FerryDocument.close()`: the tab goes; the window closes with its last tab.
    func documentDidClose(_ document: FerryDocument) {
        guard let session = sessions.removeValue(forKey: document.id) else { return }
        session.host.removeFromSuperview()
        strip.close(document.id)
        if document.tabWindowController === self { document.tabWindowController = nil }
        if sessions.isEmpty {
            self.document = nil
            window?.close()
        } else {
            activate()
        }
    }

    /// The close button or ⇧⌘W: closes every tab (asking about unsaved ones, the shown one first), then the window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !sessions.isEmpty else { return true }
        let activeID = strip.activeID
        let ids = strip.tabs.filter { $0 == activeID } + strip.tabs.filter { $0 != activeID }
        let ordered: [FerryDocument] = ids.compactMap { sessions[$0]?.document }
        close(ordered) { _ in }
        return false // the last tab to close closes the window
    }

    @objc func moveActiveTabToNewWindow(_ sender: Any?) {
        guard let id = strip.activeID else { return }
        moveTabToNewWindow(id)
    }

    /// The tab, with its editor as it is, moves to a window of its own.
    func moveTabToNewWindow(_ id: UUID) {
        guard strip.tabs.count > 1, let session = sessions.removeValue(forKey: id) else { return }
        session.host.removeFromSuperview()
        strip.close(id)
        activate()
        let controller = TabWindowController()
        controller.adopt(session)
        controller.showWindow(nil)
    }

    @objc func showNextTab(_ sender: Any?) { selectNext() }
    @objc func showPreviousTab(_ sender: Any?) { selectPrevious() }

    /// The number row by key position (ANSI key codes), so ⌘1…⌘9 work on any layout (AZERTY's ⌘1 types "&")
    /// and with any input method.
    static let numberKeys: [UInt16: Int] = [0x12: 1, 0x13: 2, 0x14: 3, 0x15: 4, 0x17: 5, 0x16: 6, 0x1A: 7, 0x1C: 8, 0x19: 9]

    /// ⌘1…⌘9 and ⌃Tab / ⌃⇧Tab (no menu items for these, as in Safari).
    func handleTabKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, let number = Self.numberKeys[event.keyCode] {
            guard strip.showsTabBar else { return false }
            strip.selectShortcutIndex(number)
            activate()
            return true
        }
        if event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift] { // Tab
            guard strip.showsTabBar else { return false }
            modifiers.contains(.shift) ? selectPrevious() : selectNext()
            return true
        }
        return false
    }

    // MARK: Bar

    func updateBar() {
        bar.update(strip: strip, items: strip.tabs.compactMap { id in
            sessions[id].map { TabBarStore.Item(id: id, title: $0.document.displayName, edited: $0.document.isDocumentEdited,
                                                 fileURL: $0.document.fileURL) }
        })
    }

    /// Room for the window buttons; none in full screen, where they're hidden.
    private func updateBarInset() {
        guard let window else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        let buttons = window.standardWindowButton(.zoomButton)?.frame.maxX ?? 70
        bar.leadingInset = fullScreen ? 10 : buttons + 14
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { Self.open.removeAll { $0 === self } }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { updateBarInset() }
    func windowDidExitFullScreen(_ notification: Notification) { updateBarInset() }
    func windowDidBecomeKey(_ notification: Notification) { bar.isKeyWindow = true }
    func windowDidResignKey(_ notification: Notification) { bar.isKeyWindow = false }
}

/// Lets ⌘1…⌘9 and ⌃Tab switch tabs before the editor sees them.
final class TabWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let controller = windowController as? TabWindowController, controller.handleTabKey(event) { return }
        super.sendEvent(event)
    }
}
