import SwiftUI

struct ContentView: View {
    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?
    @AppStorage(SettingsKeys.hideMarkdownSyntax) private var hideMarkdownSyntax = false
    @AppStorage(SettingsKeys.editorFontSize) private var fontSize = Double(EditorStyle.defaultFontSize)
    @AppStorage(SettingsKeys.stripMarkdownOnCopy) private var stripMarkdownOnCopy = false
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        MarkdownEditor(document: document, fileURL: fileURL, hideMarkdownSyntax: hideMarkdownSyntax, fontSize: fontSize, onCopyToast: showCopyToast)
            .frame(minWidth: 480, minHeight: 320)
            .overlay(alignment: .bottom) {
                if let toast {
                    ToastView(text: toast)
                        .padding(.bottom, 18)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: toast)
            .onChange(of: stripMarkdownOnCopy) { _, enabled in
                showCopyToast(enabled ? "Copy ignores Markdown syntax" : "Copy keeps Markdown syntax")
            }
    }

    private func showCopyToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
