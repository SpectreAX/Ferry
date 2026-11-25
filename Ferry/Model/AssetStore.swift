import AppKit
import UniformTypeIdentifiers

/// File operations for images stored in the `assets/` folder next to a document.
enum AssetStore {
    enum Failure: Error { case unreadableImage }

    static func assetsDirectory(for documentURL: URL) -> URL {
        documentURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
    }

    /// `yyyyMMdd-HHmmss-<shortUUID>.png`
    static func newImageName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let short = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "\(formatter.string(from: date))-\(short).png"
    }

    static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Writes image data (any format NSImage reads) as a new PNG in `assets/`.
    static func saveImage(data: Data, documentURL: URL) throws -> URL {
        let png: Data
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { // already PNG: keep bytes as-is
            png = data
        } else {
            guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
                  let converted = rep.representation(using: .png, properties: [:])
            else { throw Failure.unreadableImage }
            png = converted
        }
        let directory = assetsDirectory(for: documentURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(newImageName(), isDirectory: false)
        try png.write(to: url, options: .atomic)
        return url
    }

    /// A pasted/dropped image file: referenced in place if it already lives in the document's folder,
    /// otherwise saved into `assets/` as a new PNG.
    static func importImageFile(_ url: URL, documentURL: URL) throws -> URL {
        if isInsideDocumentFolder(url, documentURL: documentURL) { return url }
        return try saveImage(data: Data(contentsOf: url), documentURL: documentURL)
    }

    /// An image from a Ferry fragment: kept if it's inside the target document's folder, otherwise copied
    /// into the target's `assets/` (reusing an identical file with the same name).
    static func adoptImage(_ url: URL, documentURL: URL) throws -> URL {
        if isInsideDocumentFolder(url, documentURL: documentURL) { return url }
        let directory = assetsDirectory(for: documentURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: url)
        var destination = directory.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? Data(contentsOf: destination)) == data { return destination }
            let short = UUID().uuidString.prefix(8).lowercased()
            let stem = url.deletingPathExtension().lastPathComponent
            destination = directory.appendingPathComponent("\(stem)-\(short).\(url.pathExtension)", isDirectory: false)
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func isInsideDocumentFolder(_ url: URL, documentURL: URL) -> Bool {
        MarkdownCodec.relativePath(of: url, to: documentURL.deletingLastPathComponent()) != nil
    }
}
