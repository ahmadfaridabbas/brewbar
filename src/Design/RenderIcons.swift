// Editable vector artwork. Run from the project root: swift Design/RenderIcons.swift
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
}
func stroke(_ points: [NSPoint], width: CGFloat, color: NSColor) {
    let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
    path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
    color.setStroke(); path.stroke()
}
func render(size: Int, template: Bool = false, to path: String) {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(size)/1024); transform.concat()
    if !template {
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 198, yRadius: 198)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 25; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.set()
        color(0x132733).setFill(); tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: color(0x10232E), ending: color(0x315465))!.draw(in: tile, angle: 75)
        NSColor.white.withAlphaComponent(0.13).setStroke(); tile.lineWidth = 3; tile.stroke()
    }
    let ink = template ? NSColor.black : color(0xFFD38B)
    let handle = NSBezierPath(roundedRect: NSRect(x: 644, y: 333, width: 182, height: 235), xRadius: 84, yRadius: 84)
    handle.lineWidth = 59; ink.setStroke(); handle.stroke()
    let mug = NSBezierPath()
    mug.move(to: NSPoint(x: 239, y: 611)); mug.line(to: NSPoint(x: 697, y: 611))
    mug.line(to: NSPoint(x: 683, y: 338))
    mug.curve(to: NSPoint(x: 579, y: 239), controlPoint1: NSPoint(x: 680, y: 270), controlPoint2: NSPoint(x: 640, y: 239))
    mug.line(to: NSPoint(x: 359, y: 239))
    mug.curve(to: NSPoint(x: 253, y: 338), controlPoint1: NSPoint(x: 292, y: 239), controlPoint2: NSPoint(x: 256, y: 272))
    mug.close()
    if template { ink.setFill(); mug.fill() }
    else { NSGradient(starting: color(0xE99A3C), ending: color(0xFFE0A6))!.draw(in: mug, angle: 90) }
    if !template {
        let dark = color(0x293E45)
        stroke([NSPoint(x: 345, y: 496), NSPoint(x: 408, y: 440), NSPoint(x: 345, y: 384)], width: 29, color: dark)
        stroke([NSPoint(x: 458, y: 383), NSPoint(x: 550, y: 383)], width: 29, color: dark)
    }
    for x: CGFloat in [367, 548] {
        let steam = NSBezierPath(); steam.move(to: NSPoint(x: x, y: 685))
        steam.curve(to: NSPoint(x: x+20, y: 805), controlPoint1: NSPoint(x: x-52, y: 739), controlPoint2: NSPoint(x: x+58, y: 758))
        steam.lineWidth = template ? 48 : 35; steam.lineCapStyle = .round
        (template ? ink : color(0xFFE5B9)).setStroke(); steam.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
try! FileManager.default.createDirectory(atPath: "Resources/AppIcon.iconset", withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    render(size: size, to: "Resources/AppIcon.iconset/icon_\(size)x\(size).png")
    render(size: size*2, to: "Resources/AppIcon.iconset/icon_\(size)x\(size)@2x.png")
}
render(size: 1024, to: "Resources/AppIcon.png")
render(size: 36, template: true, to: "Resources/MenuBarTemplate.png")
