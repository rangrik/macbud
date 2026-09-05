import AppKit

// Draws the MacBud icon: dark squircle, a white notch silhouette at the top, three glowing list rows.
func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let inset = 100 * s
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    let bg = NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.18, alpha: 1),
                                 NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.06, alpha: 1)])!
    bg.draw(in: squircle, angle: -90)
    // notch
    let notchW = 300 * s, notchH = 62 * s
    let notch = CGRect(x: body.midX - notchW / 2, y: body.maxY - notchH, width: notchW, height: notchH)
    let np = NSBezierPath()
    np.move(to: CGPoint(x: notch.minX, y: notch.maxY))
    np.line(to: CGPoint(x: notch.minX, y: notch.minY + 22 * s))
    np.appendArc(withCenter: CGPoint(x: notch.minX + 22 * s, y: notch.minY + 22 * s), radius: 22 * s, startAngle: 180, endAngle: 270, clockwise: false)
    np.line(to: CGPoint(x: notch.maxX - 22 * s, y: notch.minY))
    np.appendArc(withCenter: CGPoint(x: notch.maxX - 22 * s, y: notch.minY + 22 * s), radius: 22 * s, startAngle: 270, endAngle: 360, clockwise: false)
    np.line(to: CGPoint(x: notch.maxX, y: notch.maxY))
    np.close()
    NSColor.white.withAlphaComponent(0.96).setFill(); np.fill()
    // rows
    let accent = NSColor(calibratedRed: 0.55, green: 0.72, blue: 1.0, alpha: 1)
    let rows: [(CGFloat, CGFloat, NSColor)] = [(0.70, 1.0, accent), (0.52, 0.55, .white), (0.36, 0.30, .white)]
    var y = body.maxY - notchH - 150 * s
    for (w, alpha, color) in rows {
        let r = CGRect(x: body.minX + 130 * s, y: y - 56 * s, width: (body.width - 260 * s) * w, height: 56 * s)
        color.withAlphaComponent(alpha * (color == .white ? 0.9 : 1)).setFill()
        NSBezierPath(roundedRect: r, xRadius: 28 * s, yRadius: 28 * s).fill()
        y -= 120 * s
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
var contents: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(pt * scale)
        let name = "icon_\(pt)x\(pt)@\(scale)x.png"
        try! render(size: px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        contents.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
    }
}
let json: [String: Any] = ["images": contents, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
print("icon written")
