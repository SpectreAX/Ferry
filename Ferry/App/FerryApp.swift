import SwiftUI

@main
struct FerryApp: App {
    @AppStorage(SettingsKeys.hideMarkdownSyntax) private var hideMarkdownSyntax = false
    @AppStorage(SettingsKeys.stripMarkdownOnCopy) private var stripMarkdownOnCopy = false
    @AppStorage(SettingsKeys.hideMarkdownSyntaxShortcut) private var hideShortcutRaw = AppShortcut.defaultHideMarkdown.storageString
    @AppStorage(SettingsKeys.stripMarkdownOnCopyShortcut) private var stripShortcutRaw = AppShortcut.defaultStripMarkdownOnCopy.storageString

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }) { file in
            ContentView(document: file.document, fileURL: file.fileURL)
        }
        .commands {
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
            }
        }

        Settings {
            SettingsView()
        }
    }
}
