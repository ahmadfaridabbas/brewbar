// Terminal Mug: native vector template, rendered at 1x and 2x.
// Run from the project root: swift Design/RenderMenuBar.swift
import AppKit

for scale in [1, 2] {
    let size = 18 * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(scale)); transform.concat()
    NSColor.black.setFill()
    let handle = NSBezierPath(roundedRect: NSRect(x: 11, y: 5, width: 6, height: 8), xRadius: 2.7, yRadius: 2.7)
    handle.append(NSBezierPath(roundedRect: NSRect(x: 12, y: 6.7, width: 3.3, height: 4.6), xRadius: 1.2, yRadius: 1.2))
    handle.windingRule = .evenOdd; handle.fill()
    let body = NSBezierPath()
    body.move(to: NSPoint(x: 2, y: 15))
    body.line(to: NSPoint(x: 12, y: 15))
    body.curve(to: NSPoint(x: 13, y: 14), controlPoint1: NSPoint(x: 12.6, y: 15), controlPoint2: NSPoint(x: 13, y: 14.6))
    body.line(to: NSPoint(x: 13, y: 6))
    body.curve(to: NSPoint(x: 9, y: 2), controlPoint1: NSPoint(x: 13, y: 3.5), controlPoint2: NSPoint(x: 11.5, y: 2))
    body.line(to: NSPoint(x: 5, y: 2))
    body.curve(to: NSPoint(x: 1, y: 6), controlPoint1: NSPoint(x: 2.5, y: 2), controlPoint2: NSPoint(x: 1, y: 3.5))
    body.line(to: NSPoint(x: 1, y: 14))
    body.curve(to: NSPoint(x: 2, y: 15), controlPoint1: NSPoint(x: 1, y: 14.6), controlPoint2: NSPoint(x: 1.4, y: 15))
    body.close(); body.fill()
    // Cut through the alpha channel so macOS can tint the entire icon correctly.
    NSGraphicsContext.current!.cgContext.setBlendMode(.clear)
    let prompt = NSBezierPath()
    prompt.move(to: NSPoint(x: 5.4, y: 11.5)); prompt.line(to: NSPoint(x: 8.2, y: 8.8)); prompt.line(to: NSPoint(x: 5.4, y: 6.1))
    prompt.lineWidth = 1.7; prompt.lineCapStyle = .round; prompt.lineJoinStyle = .round; prompt.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/MenuBarTemplate\(suffix).png"))
}
