// Draws the app icon and writes an .iconset folder. Usage: swift make-icon.swift <output.iconset>
//
// A small bird perched on a wire under the notch, white on graphite. Every
// shape is drawn here; no system symbols, which may not be used in app icons.
import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

/// Coordinates below are on a 1024 grid with y pointing down, like the SVG they came from.
func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

/// A quadratic curve, as a cubic.
func quad(_ path: NSBezierPath, to end: NSPoint, control: NSPoint) {
    let start = path.currentPoint
    path.curve(to: end,
               controlPoint1: point(start.x + (control.x - start.x) * 2 / 3, start.y + (control.y - start.y) * 2 / 3),
               controlPoint2: point(end.x + (control.x - end.x) * 2 / 3, end.y + (control.y - end.y) * 2 / 3))
}

/// The bird, facing right, in a 200 × 200 box with its feet at y = 174.
func bird(at origin: NSPoint, scale: CGFloat, simple: Bool) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: origin.x, yBy: origin.y)
    transform.scale(by: scale)
    transform.concat()

    let white = NSColor.white
    let dark = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.10, alpha: 1)

    let legs = NSBezierPath()
    legs.move(to: point(104, 154)); legs.line(to: point(100, 174))
    legs.move(to: point(124, 152)); legs.line(to: point(122, 174))
    legs.lineWidth = simple ? 12 : 7
    legs.lineCapStyle = .round
    white.setStroke()
    legs.stroke()

    let body = NSBezierPath()
    body.move(to: point(18, 148))
    body.line(to: point(66, 112))
    body.curve(to: point(134, 44), controlPoint1: point(64, 72), controlPoint2: point(96, 44))
    body.curve(to: point(177, 80), controlPoint1: point(160, 44), controlPoint2: point(176, 60))
    body.line(to: point(200, 87))
    body.line(to: point(176, 95))
    body.curve(to: point(108, 157), controlPoint1: point(175, 128), controlPoint2: point(148, 154))
    body.curve(to: point(76, 150), controlPoint1: point(95, 158), controlPoint2: point(84, 155))
    body.line(to: point(28, 160))
    body.close()
    white.setFill()
    body.fill()

    let eyeSize: CGFloat = simple ? 22 : 15
    dark.setFill()
    NSBezierPath(ovalIn: NSRect(x: 152 - eyeSize / 2, y: 70 - eyeSize / 2, width: eyeSize, height: eyeSize)).fill()

    if !simple {
        let wing = NSBezierPath()
        wing.move(to: point(82, 104))
        wing.curve(to: point(146, 104), controlPoint1: point(100, 86), controlPoint2: point(132, 88))
        wing.curve(to: point(76, 128), controlPoint1: point(128, 118), controlPoint2: point(100, 126))
        wing.close()
        dark.withAlphaComponent(0.18).setFill()
        wing.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

func draw(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = CGFloat(pixels) / 1024
    // Tiny sizes get a bigger bird with fewer details, so it still reads.
    let simple = pixels <= 64

    // Work on the 1024 grid, y down.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: CGFloat(pixels))
    flip.scaleX(by: u, yBy: -u)
    flip.concat()

    let squircle = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * u
    shadow.shadowOffset = NSSize(width: 0, height: -12 * u)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.149, green: 0.149, blue: 0.169, alpha: 1),
                        NSColor(srgbRed: 0.051, green: 0.051, blue: 0.063, alpha: 1)])!
        .draw(in: squircle, angle: 90)

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()

    // The notch, hanging from the top edge.
    let notch = NSBezierPath()
    notch.move(to: point(362, 90))
    notch.line(to: point(662, 90))
    notch.line(to: point(662, 170))
    quad(notch, to: point(618, 214), control: point(662, 214))
    notch.line(to: point(406, 214))
    quad(notch, to: point(362, 170), control: point(362, 214))
    notch.close()
    NSColor.black.setFill()
    notch.fill()

    // The wire, and the bird perched on it.
    let wireWidth: CGFloat = simple ? 22 : 10
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: 200, y: 677 - wireWidth / 2, width: 624, height: wireWidth),
                 xRadius: wireWidth / 2, yRadius: wireWidth / 2).fill()
    if simple {
        bird(at: point(272, 330), scale: 2.1, simple: true)
    } else {
        bird(at: point(338, 370), scale: 1.75, simple: false)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(pixels).write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
}
