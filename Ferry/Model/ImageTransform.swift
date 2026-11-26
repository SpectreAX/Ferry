import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Flips and quarter turns that change the pixels (so other apps, and AI chats, see the image the right way up).
/// The result is a new PNG: the source file is never changed. Keeps transparency and the image's DPI, so a 2x
/// screenshot keeps its size on screen, and applies any EXIF orientation first (a portrait phone photo stays
/// upright before the turn).
enum ImageTransform {
    enum Operation: CaseIterable {
        case flipHorizontal, flipVertical, rotateLeft, rotateRight

        var name: String {
            switch self {
            case .flipHorizontal: return "Flip Horizontal"
            case .flipVertical: return "Flip Vertical"
            case .rotateLeft: return "Rotate Left 90°"
            case .rotateRight: return "Rotate Right 90°"
            }
        }

        var turnsSideways: Bool { self == .rotateLeft || self == .rotateRight }
    }

    static func transform(fileURL: URL, operation: Operation) -> Data? {
        (try? Data(contentsOf: fileURL)).flatMap { transform(data: $0, operation: operation) }
    }

    static func transform(data: Data, operation: Operation) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let image = uprightImage(source, properties: properties) else { return nil }
        let width = image.width, height = image.height
        let (canvasWidth, canvasHeight) = operation.turnsSideways ? (height, width) : (width, height)

        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Core Graphics: origin at the bottom left, y up.
        let w = CGFloat(width), h = CGFloat(height)
        switch operation {
        case .flipHorizontal:
            context.translateBy(x: w, y: 0)
            context.scaleBy(x: -1, y: 1)
        case .flipVertical:
            context.translateBy(x: 0, y: h)
            context.scaleBy(x: 1, y: -1)
        case .rotateLeft: // counterclockwise
            context.translateBy(x: h, y: 0)
            context.rotate(by: .pi / 2)
        case .rotateRight: // clockwise
            context.translateBy(x: 0, y: w)
            context.rotate(by: -.pi / 2)
        }
        context.interpolationQuality = .none // whole-pixel moves only
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = context.makeImage() else { return nil }

        // DPI carries the image's size in points; a quarter turn swaps the axes. No orientation tag: the pixels
        // are already upright.
        var output: [CFString: Any] = [:]
        let dpiX = properties[kCGImagePropertyDPIWidth], dpiY = properties[kCGImagePropertyDPIHeight]
        if let dpiX, let dpiY {
            output[kCGImagePropertyDPIWidth] = operation.turnsSideways ? dpiY : dpiX
            output[kCGImagePropertyDPIHeight] = operation.turnsSideways ? dpiX : dpiY
        }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, result, output as CFDictionary)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
    }

    /// The image with any EXIF orientation applied to its pixels (exact pixels when there is none).
    private static func uprightImage(_ source: CGImageSource, properties: [CFString: Any]) -> CGImage? {
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard orientation != 1 else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
