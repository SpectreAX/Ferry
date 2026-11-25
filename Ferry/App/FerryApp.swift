import SwiftUI

@main
struct FerryApp: App {
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
            }
        }

        Settings {
            SettingsView()
        }
    }
}
