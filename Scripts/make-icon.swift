// Draws the app icon and writes an .iconset folder. Usage: swift make-icon.swift <output.iconset>
import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186 * u, yRadius: 186 * u)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * u
    shadow.shadowOffset = NSSize(width: 0, height: -12 * u)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.30, blue: 0.86, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.09, blue: 0.24, alpha: 1)])!
        .draw(in: squircle, angle: -90)

    // The island hanging from the top edge.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let island = NSRect(x: 322 * u, y: 790 * u, width: 380 * u, height: 220 * u)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: island, xRadius: 52 * u, yRadius: 52 * u).fill()
    NSGraphicsContext.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: 400 * u, weight: .semibold)
    if let bird = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: bird.size, flipped: false) { rect in
            bird.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        tinted.draw(in: NSRect(x: (CGFloat(pixels) - size.width) / 2, y: 250 * u, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 0.96)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(pixels).write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
}
