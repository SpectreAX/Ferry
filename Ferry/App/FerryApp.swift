import SwiftUI

@main
struct FerryApp: App {
    @AppStorage(SettingsKeys.hideMarkdownSyntax) private var hideMarkdownSyntax = false
    @AppStorage(SettingsKeys.stripMarkdownOnCopy) private var stripMarkdownOnCopy = false
    @AppStorage(SettingsKeys.editorFontSize) private var fontSize = Double(EditorStyle.defaultFontSize)
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

        Settings {
            SettingsView()
        }
    }
}
