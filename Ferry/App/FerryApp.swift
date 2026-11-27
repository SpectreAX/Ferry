import SwiftUI

@main
struct FerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var recents = RecentDocuments.shared
    @AppStorage(SettingsKeys.hideMarkdownSyntax) private var hideMarkdownSyntax = false
    @AppStorage(SettingsKeys.stripMarkdownOnCopy) private var stripMarkdownOnCopy = false
    @AppStorage(SettingsKeys.editorFontSize) private var fontSize = Double(EditorStyle.defaultFontSize)
    @AppStorage(SettingsKeys.hideMarkdownSyntaxShortcut) private var hideShortcutRaw = AppShortcut.defaultHideMarkdown.storageString
    @AppStorage(SettingsKeys.stripMarkdownOnCopyShortcut) private var stripShortcutRaw = AppShortcut.defaultStripMarkdownOnCopy.storageString

    var body: some Scene {
        // Document windows are AppKit (`TabWindowController`, tabs of `FerryDocument`s); SwiftUI provides the
        // menus and Settings.
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") { FerryDocument.newWindow() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Tab") { FerryDocument.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Open…") { NSDocumentController.shared.openDocument(nil) }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(recents.urls, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                        }
                    }
                    if !recents.urls.isEmpty { Divider() }
                    Button("Clear Menu") { recents.clear() }
                        .disabled(recents.urls.isEmpty)
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") {
                    // Only the key window: Settings and other windows have no tabs, ⌘W closes them.
                    if let tabs = NSApp.keyWindow?.windowController as? TabWindowController {
                        tabs.closeActiveTab(nil)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Save") { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Revert to Saved") { NSApp.sendAction(#selector(NSDocument.revertToSaved(_:)), to: nil, from: nil) }
            }
            CommandGroup(before: .windowList) {
                Button("Show Previous Tab") { NSApp.sendAction(#selector(TabWindowController.showPreviousTab(_:)), to: nil, from: nil) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Show Next Tab") { NSApp.sendAction(#selector(TabWindowController.showNextTab(_:)), to: nil, from: nil) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Move Tab to New Window") {
                    NSApp.sendAction(#selector(TabWindowController.moveActiveTabToNewWindow(_:)), to: nil, from: nil)
                }
                Divider()
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy as Plain Markdown") {
                    NSApp.sendAction(#selector(EditorTextView.copyAsPlainMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                Toggle("Ignore Markdown Syntax When Copying", isOn: $stripMarkdownOnCopy)
                    .keyboardShortcut(AppShortcut.decode(stripShortcutRaw, default: .defaultStripMarkdownOnCopy)?.keyboardShortcut)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Hide Markdown Syntax", isOn: $hideMarkdownSyntax)
                    .keyboardShortcut(AppShortcut.decode(hideShortcutRaw, default: .defaultHideMarkdown)?.keyboardShortcut)
                Divider()
                Button("Bigger") { fontSize = Double(EditorStyle.clamped(CGFloat(fontSize) + 1)) }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(CGFloat(fontSize) >= EditorStyle.maxFontSize)
                Button("Smaller") { fontSize = Double(EditorStyle.clamped(CGFloat(fontSize) - 1)) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(CGFloat(fontSize) <= EditorStyle.minFontSize)
                Button("Actual Size") { fontSize = Double(EditorStyle.defaultFontSize) }
                    .keyboardShortcut("0", modifiers: .command)
            }
            // Markdown formatting instead of the rich-text Format menu (fonts, colors, rulers don't apply).
            CommandGroup(replacing: .textFormatting) {
                Button("Bold") { NSApp.sendAction(#selector(EditorTextView.toggleBoldMarkdown(_:)), to: nil, from: nil) }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") { NSApp.sendAction(#selector(EditorTextView.toggleItalicMarkdown(_:)), to: nil, from: nil) }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Insert Link") { NSApp.sendAction(#selector(EditorTextView.insertMarkdownLink(_:)), to: nil, from: nil) }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

/// Starts the document side: no system window tabs (Ferry draws its own), a blank document at launch and when the
/// Dock icon is clicked with no windows, and files from Finder or the Dock opened as tabs.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Unit tests run inside the app: no windows of its own then.
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Files arrived to open (Finder, Dock): no blank document then, even while they are still being read.
    private var openedURLsAtLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTesting else { return }
        DispatchQueue.main.async {
            guard !self.openedURLsAtLaunch, NSDocumentController.shared.documents.isEmpty else { return }
            NSDocumentController.shared.newDocument(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedURLsAtLaunch = true
        // macOS doesn't keep Finder's selection order: open them by name, as Finder lists them.
        Self.openInOrder(urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }[...])
    }

    /// One after another, so several files from Finder land in one window, in a predictable order.
    private static func openInOrder(_ urls: ArraySlice<URL>) {
        guard let url = urls.first else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in
            openInOrder(urls.dropFirst())
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false } // handled above

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !Self.isTesting { FerryDocument.newWindow() }
        return false
    }
}
