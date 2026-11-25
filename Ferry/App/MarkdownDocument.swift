import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown")
}

/// A `.md` file. Holds the Markdown source; the editor keeps it current as you type.
/// Reference type so edits go through the document's undo manager (system undo, dirty state).
final class MarkdownDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.markdownDocument] }

    var markdown: String

    init(markdown: String = "") {
        self.markdown = markdown
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        markdown = text
    }

    func snapshot(contentType: UTType) throws -> String { markdown }

    func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }
}
