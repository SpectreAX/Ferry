import AppKit

extension NSAttributedString.Key {
    /// Marks the Markdown link of a web image that is still downloading. Never saved or copied.
    static let ferryPendingImage = NSAttributedString.Key("dev.spectreax.ferry.pendingImage")
}

/// A web image pasted as `![alt](https://…)` until its download replaces it with a local asset.
final class PendingRemoteImage: NSObject {
    let url: URL
    let alt: String
    let markdown: String

    init(url: URL, alt: String) {
        self.url = url
        self.alt = alt
        markdown = MarkdownCodec.imageMarkdown(alt: alt, path: url.absoluteString)
    }
}

/// Downloads pasted web images. Failures return nil, and the Markdown link simply stays.
enum RemoteImageLoader {
    static let maxBytes = 25 * 1024 * 1024
    static var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    static func data(from url: URL) async -> Data? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard data.count <= maxBytes, NSImage(data: data) != nil else { return nil }
        return data
    }
}
