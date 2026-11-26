import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Ferry

/// Pixel-exact flips and quarter turns, with transparency, DPI and EXIF orientation.
final class ImageTransformTests: XCTestCase {
    typealias RGBA = [UInt8]
    private let red: RGBA = [255, 0, 0, 255], green: RGBA = [0, 255, 0, 255], blue: RGBA = [0, 0, 255, 255]
    private let clear: RGBA = [0, 0, 0, 0], yellow: RGBA = [255, 255, 0, 255]
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 2 wide × 3 tall: red, green / yellow, yellow / blue, transparent (rows from the top).
    private func sample(dpi: Int = 144, type: UTType = .png, orientation: Int? = nil) -> Data {
        let rows: [[RGBA]] = [[red, green], [yellow, yellow], [blue, clear]]
        var bytes = rows.flatMap { $0.flatMap { $0 } }
        let context = CGContext(data: &bytes, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 8, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The pixels, rows from the top, in sRGB.
    private func pixels(_ data: Data) -> (width: Int, height: Int, at: (Int, Int) -> RGBA) {
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, { x, y in Array(bytes[(y * width + x) * 4 ..< (y * width + x) * 4 + 4]) })
    }

    private func corners(_ data: Data) -> [RGBA] {
        let p = pixels(data)
        return [p.at(0, 0), p.at(p.width - 1, 0), p.at(0, p.height - 1), p.at(p.width - 1, p.height - 1)] // TL, TR, BL, BR
    }

    func testFlipsKeepTheSizeAndMirrorThePixels() throws {
        let flippedH = try XCTUnwrap(ImageTransform.transform(data: sample(), operation: .flipHorizontal))
        XCTAssertEqual(pixels(flippedH).width, 2)
        XCTAssertEqual(pixels(flippedH).height, 3)
        XCTAssertEqual(corners(flippedH), [green, red, clear, blue])
        let flippedV = try XCTUnwrap(ImageTransform.transform(data: sample(), operation: .flipVertical))
        XCTAssertEqual(corners(flippedV), [blue, clear, red, green])
    }

    func testQuarterTurnsSwapTheSides() throws {
        let right = try XCTUnwrap(ImageTransform.transform(data: sample(), operation: .rotateRight))
        XCTAssertEqual(pixels(right).width, 3)
        XCTAssertEqual(pixels(right).height, 2)
        XCTAssertEqual(corners(right), [blue, red, clear, green], "clockwise: the bottom-left comes to the top-left")
        let left = try XCTUnwrap(ImageTransform.transform(data: sample(), operation: .rotateLeft))
        XCTAssertEqual(corners(left), [green, clear, red, blue], "counterclockwise: the top-right comes to the top-left")
        // Four quarter turns are the original.
        var data = sample()
        for _ in 0..<4 { data = try XCTUnwrap(ImageTransform.transform(data: data, operation: .rotateRight)) }
        XCTAssertEqual(corners(data), corners(sample()))
    }

    func testOutputIsPNGWithTheSameDPI() throws {
        let output = try XCTUnwrap(ImageTransform.transform(data: sample(dpi: 144), operation: .rotateLeft))
        XCTAssertTrue(output.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let size = try XCTUnwrap(NSImage(data: output)).size
        XCTAssertEqual(size, NSSize(width: 1.5, height: 1), "3×2 px at 144 DPI: half the pixels in points, like a 2x screenshot")
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(output as CFData, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertNil(properties?[kCGImagePropertyOrientation])
    }

    func testEXIFOrientationIsAppliedFirst() throws {
        // Stored 2×3, tagged "rotate 90° clockwise to view" (6): it shows as 3×2.
        let tagged = sample(type: .tiff, orientation: 6)
        let flipped = try XCTUnwrap(ImageTransform.transform(data: tagged, operation: .flipHorizontal))
        XCTAssertEqual(pixels(flipped).width, 3)
        XCTAssertEqual(pixels(flipped).height, 2)
        XCTAssertEqual(corners(flipped), [red, blue, green, clear], "upright first (blue, red / clear, green), then mirrored")
    }

    func testUnreadableDataGivesNil() {
        XCTAssertNil(ImageTransform.transform(data: Data("not an image".utf8), operation: .flipHorizontal))
    }
}
