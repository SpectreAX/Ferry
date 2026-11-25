import Foundation

/// Writes the Markdown file that "Copy for AI" attaches next to the image files.
/// Chromium-based apps (Claude, Codex desktop) drop clipboard text whenever files are present,
/// so the text travels as a `.md` file instead. Each copy gets its own folder so a file an app
/// is still uploading is never overwritten; folders older than a day are removed.
enum ClipboardAttachments {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.spectreax.ferry/Clipboard", isDirectory: true)
    }

    static func writeMarkdown(_ markdown: String, named name: String, in directory: URL, now: Date = Date()) throws -> URL {
        removeStaleFolders(in: directory, olderThan: now.addingTimeInterval(-24 * 60 * 60))
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(safeFileName(name) + ".md", isDirectory: false)
        try Data(markdown.utf8).write(to: file, options: .atomic)
        return file
    }

    static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    private static func removeStaleFolders(in directory: URL, olderThan cutoff: Date) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: folder) }
        }
    }
}
