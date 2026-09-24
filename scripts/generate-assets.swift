import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func render(_ name: String, drawing: () -> Void) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 96,
        pixelsHigh: 96,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "CoreBarsAssets", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 96, height: 96)).fill()
    drawing()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CoreBarsAssets", code: 2)
    }
    try png.write(to: root.appendingPathComponent("\(name).png"))
}

try render("memory-pressure") {
    NSColor.black.setStroke()
    NSColor.black.setFill()
    let frame = NSBezierPath(roundedRect: NSRect(x: 12, y: 13, width: 72, height: 70), xRadius: 9, yRadius: 9)
    frame.lineWidth = 5
    frame.stroke()
    for y in [27.0, 45.0, 63.0] {
        NSBezierPath(roundedRect: NSRect(x: 23, y: y, width: 50, height: 6), xRadius: 3, yRadius: 3).fill()
    }
}

try render("cpu-activity") {
    NSColor.black.setStroke()
    NSColor.black.setFill()
    let chip = NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 48, height: 48), xRadius: 7, yRadius: 7)
    chip.lineWidth = 5
    chip.stroke()
    NSBezierPath(roundedRect: NSRect(x: 37, y: 37, width: 22, height: 22), xRadius: 4, yRadius: 4).fill()
    let pins = NSBezierPath()
    pins.lineWidth = 5
    pins.lineCapStyle = .round
    for position in [36.0, 48.0, 60.0] {
        pins.move(to: NSPoint(x: position, y: 11))
        pins.line(to: NSPoint(x: position, y: 22))
        pins.move(to: NSPoint(x: position, y: 74))
        pins.line(to: NSPoint(x: position, y: 85))
        pins.move(to: NSPoint(x: 11, y: position))
        pins.line(to: NSPoint(x: 22, y: position))
        pins.move(to: NSPoint(x: 74, y: position))
        pins.line(to: NSPoint(x: 85, y: position))
    }
    pins.stroke()
}
