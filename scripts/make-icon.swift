// Draws Agent Buddy's app icon: three gauges in Claude's, ChatGPT's and Copilot's colours.
// Usage: swift scripts/make-icon.swift Support/AppIcon.icns
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: swift make-icon.swift <output.icns>")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AgentBuddy-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple's icon grid: an 824-point rounded square centred in 1024.
    let inset = size * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let corner = tile.width * 0.2237
    let shape = NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0, 0, 0.35)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
    shadow.set()
    color(0.10, 0.11, 0.16).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0.19, 0.21, 0.29), color(0.07, 0.08, 0.12)])!.draw(in: shape, angle: -90)

    let center = NSPoint(x: size / 2, y: size * 0.44)
    let gauges: [(NSColor, CGFloat, CGFloat)] = [
        (color(0.85, 0.47, 0.34), 0.300, 0.78),
        (color(0.06, 0.64, 0.50), 0.222, 0.55),
        (color(0.55, 0.40, 0.95), 0.144, 0.33),
    ]
    let start: CGFloat = 205
    let sweep: CGFloat = 230
    for (tint, radius, fraction) in gauges {
        for (stroke, share) in [(color(1, 1, 1, 0.10), 1.0), (tint, fraction)] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: size * radius, startAngle: start, endAngle: start - sweep * share, clockwise: true)
            arc.lineWidth = size * 0.056
            arc.lineCapStyle = .round
            stroke.setStroke()
            arc.stroke()
        }
    }
    let hub = size * 0.036
    color(1, 1, 1, 0.92).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try render(pixels).write(to: iconset.appendingPathComponent("\(name).png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
