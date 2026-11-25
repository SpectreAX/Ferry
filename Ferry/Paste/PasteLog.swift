import Foundation
import os

/// One ⌘V test log: `~/Library/Logs/Ferry/one-paste.log` (kept under 1 MB). Never contains clipboard text.
enum PasteLog {
    static let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Ferry/one-paste.log", isDirectory: false)
    /// Tests turn the file off; the unified log (Console.app, category "one-paste") always gets the line.
    static var writesFile = true

    private static let logger = Logger(subsystem: "dev.spectreax.ferry", category: "one-paste")
    private static let queue = DispatchQueue(label: "dev.spectreax.ferry.paste-log")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
        guard writesFile else { return }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 1_000_000 {
            let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: fileURL, to: old)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            try? Data(line.utf8).write(to: fileURL)
            return
        }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}
