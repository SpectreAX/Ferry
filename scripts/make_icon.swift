#!/usr/bin/env swift
// Builds Ferry's AppIcon.appiconset from the SVG master `design/ferry-icon.svg`.
// The master is 1024×1024 on the macOS icon grid (824×824 body, transparent margins, shadow included),
// so it is rasterized as-is, then downscaled with sips for every size.
// Requires rsvg-convert (`brew install librsvg`).
// Usage: swift scripts/make_icon.swift   (run from the repository root)

import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("design/ferry-icon.svg")
let iconset = root.appendingPathComponent("Ferry/Resources/Assets.xcassets/AppIcon.appiconset")
let rsvgCandidates = ["/opt/homebrew/bin/rsvg-convert", "/usr/local/bin/rsvg-convert"]

func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("\(tool) failed: \(arguments.joined(separator: " "))") }
}

guard FileManager.default.fileExists(atPath: source.path) else { fatalError("Missing \(source.path)") }
guard let rsvg = rsvgCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
    fatalError("rsvg-convert not found. Install it with: brew install librsvg")
}
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// 1024 master from the SVG
let master = iconset.appendingPathComponent("icon_512x512@2x.png")
try run(rsvg, ["--width", "1024", "--height", "1024", "--format", "png", "--output", master.path, source.path])

// Every other size from the 1024 master
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let pixels = points * scale
        if pixels != 1024 {
            try run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", master.path, "--out", iconset.appendingPathComponent(name).path])
        }
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconset.appendingPathComponent("Contents.json"))

let catalogContents = iconset.deletingLastPathComponent().appendingPathComponent("Contents.json")
try Data(#"{ "info" : { "author" : "xcode", "version" : 1 } }"#.utf8).write(to: catalogContents)
print("Wrote \(images.count) icons to \(iconset.path)")
