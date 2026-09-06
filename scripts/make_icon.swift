import AppKit

// Package the user's supplied sunrise artwork into the macOS asset catalog.
let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = project.appendingPathComponent("Resources/Assets.xcassets")
let brand = project.appendingPathComponent("Resources/Brand")
let appOutput = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? catalog.appendingPathComponent("AppIcon.appiconset")
let markOutput = catalog.appendingPathComponent("MacBudMark.imageset")
let statusOutput = catalog.appendingPathComponent("MacBudStatusIcon.imageset")

func load(_ filename: String) throws -> NSImage {
    guard let image = NSImage(contentsOf: brand.appendingPathComponent(filename)),
          image.size.width > 0, image.size.height > 0 else {
        throw NSError(domain: "MacBudArtwork", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot load artwork \(filename)"])
    }
    return image
}

func write(_ image: NSImage, pixels: Int, to destination: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let side = CGFloat(pixels)
    let scale = side / max(image.size.width, image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let rect = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                      width: size.width, height: size.height)
    image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
}

func writeContents(_ images: [[String: String]], to directory: URL, template: Bool? = nil) throws {
    var contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    if let template {
        contents["properties"] = ["template-rendering-intent": template ? "template" : "original"]
    }
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("Contents.json"))
}

let app = try load("MacBud-Sunrise-Cutout.png")
let mark = app
for directory in [appOutput, markOutput, statusOutput] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}
var appContents: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)@\(scale)x.png"
        try write(app, pixels: points * scale, to: appOutput.appendingPathComponent(name))
        appContents.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
try writeContents(appContents, to: appOutput)
var markContents: [[String: String]] = []
for scale in [1, 2] {
    let name = "MacBudMark@\(scale)x.png"
    try write(mark, pixels: 64 * scale, to: markOutput.appendingPathComponent(name))
    markContents.append(["filename": name, "idiom": "mac", "scale": "\(scale)x"])
}
try writeContents(markContents, to: markOutput, template: false)
var statusContents: [[String: String]] = []
for scale in [1, 2] {
    let name = "MacBudStatusIcon@\(scale)x.png"
    try write(mark, pixels: 18 * scale, to: statusOutput.appendingPathComponent(name))
    statusContents.append(["filename": name, "idiom": "mac", "scale": "\(scale)x"])
}
try writeContents(statusContents, to: statusOutput, template: true)
print("Generated transparent app/notch icons and an adaptive monochrome status-bar template.")
