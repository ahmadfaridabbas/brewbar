// Offscreen marketing renders of the BrewBar dashboard, drawn from the app's own
// visual design (colors, layout, SF Symbols). Produces PNGs for the website gallery.
// Run from the project root:  swift Design/RenderSite.swift
// These are native offscreen renders, not screen captures.
import AppKit

// Directory holding the real app icon artwork (AppIconLight.png / AppIconDark.png).
// Pass as argv[2]; defaults to the project's Resources folder.
let resourcesDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources"

// MARK: - Palette

struct Theme {
    let dark: Bool
    var bg: NSColor { dark ? c(0x1E1E20) : c(0xECECE6) }
    var panel: NSColor { dark ? c(0x2A2A2E) : c(0xFFFFFF) }
    var card: NSColor { dark ? c(0x323236) : c(0xF6F6F1) }
    var console: NSColor { dark ? c(0x161618) : c(0xFBFBF7) }
    var ink: NSColor { dark ? c(0xF4F4EE) : c(0x1B1B1B) }
    var muted: NSColor { dark ? c(0xA7AAA9) : c(0x6B6E6C) }
    var line: NSColor { dark ? c(0x3A3A3E) : c(0xDADAD2) }
    var accent: NSColor { c(0xE0952F) } // amber, matching the app icon
    var green: NSColor { c(0x37B24D) }
    var red: NSColor { c(0xD64545) }
}

func c(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255,
            blue: CGFloat(hex & 255)/255, alpha: 1)
}

// MARK: - Drawing helpers

func fill(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 0) {
    let p = radius > 0 ? NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) : NSBezierPath(rect: rect)
    color.setFill(); p.fill()
}
func strokeRect(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 0, width: CGFloat = 1) {
    let p = radius > 0 ? NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) : NSBezierPath(rect: rect)
    color.setStroke(); p.lineWidth = width; p.stroke()
}
func measure(_ s: String, _ size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
}
func text(_ string: String, _ point: NSPoint, size: CGFloat, color: NSColor,
          weight: NSFont.Weight = .regular, mono: Bool = false, rounded: Bool = false) {
    let font: NSFont
    if mono { font = NSFont.monospacedSystemFont(ofSize: size, weight: weight) }
    else if rounded, let d = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        .withDesign(.rounded) { font = NSFont(descriptor: d, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight) }
    else { font = NSFont.systemFont(ofSize: size, weight: weight) }
    (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
}
func symbol(_ name: String, _ rect: NSRect, color: NSColor, weight: NSFont.Weight = .regular) {
    let cfg = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight)
        .applying(.init(paletteColors: [color]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return }
    let s = img.size
    let scale = min(rect.width / s.width, rect.height / s.height)
    let dw = s.width * scale, dh = s.height * scale
    img.draw(in: NSRect(x: rect.midX - dw/2, y: rect.midY - dh/2, width: dw, height: dh))
}

// MARK: - Content model

struct Action { let symbol: String; let title: String; let detail: String; let command: String }
let actions = [
    Action(symbol: "arrow.triangle.2.circlepath", title: "Update", detail: "Refresh Homebrew & package definitions", command: "update"),
    Action(symbol: "magnifyingglass", title: "Outdated", detail: "Find packages with newer versions", command: "outdated"),
    Action(symbol: "arrow.up.circle", title: "Upgrade", detail: "Install available package upgrades", command: "upgrade"),
    Action(symbol: "sparkles", title: "Cleanup", detail: "Remove old versions & stale downloads", command: "cleanup"),
    Action(symbol: "shippingbox", title: "Autoremove", detail: "Uninstall unneeded dependencies", command: "autoremove"),
    Action(symbol: "stethoscope", title: "Doctor", detail: "Check configuration & system health", command: "doctor"),
]

enum Tab { case maintenance, installed, updates, console }

// MARK: - Dashboard render

func renderDashboard(width: CGFloat, height: CGFloat, theme t: Theme, tab: Tab,
                     running: Bool = false, seg: Int) -> NSBitmapImageRep {
    let scale: CGFloat = 2
    let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width*scale), pixelsHigh: Int(height*scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bmp.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)

    fill(NSRect(x: 0, y: 0, width: width, height: height), t.bg)

    let pad: CGFloat = 20
    let panelW = width - pad*2
    var top = height - pad

    // Header: icon + title + version, then options / Close / Quit on the right
    drawAppIcon(NSRect(x: pad, y: top - 54, width: 54, height: 54), t)
    text("BrewBar", NSPoint(x: pad + 66, y: top - 26), size: 22, color: t.ink, weight: .semibold, rounded: true)
    text("A little care for your Homebrew.", NSPoint(x: pad + 66, y: top - 44), size: 13, color: t.muted)
    text("Version 1.10 (11)", NSPoint(x: pad + 66, y: top - 58), size: 10, color: t.muted, weight: .medium)

    // Right-aligned controls: [•••]  [x Close]  [⏻ Quit]
    var cx = width - pad
    // Quit button
    let quitLabel = "Quit", closeLabel = "Close"
    let quitW = measure(quitLabel, 11, weight: .medium) + 34
    let quitR = NSRect(x: cx - quitW, y: top - 30, width: quitW, height: 22)
    fill(quitR, t.card, radius: 6); strokeRect(quitR, t.line, radius: 6)
    symbol("power", NSRect(x: quitR.minX + 8, y: quitR.midY - 6, width: 12, height: 12), color: t.red)
    text(quitLabel, NSPoint(x: quitR.minX + 24, y: quitR.midY - 7), size: 11, color: t.ink, weight: .medium)
    cx = quitR.minX - 8
    // Close button
    let closeW = measure(closeLabel, 11, weight: .medium) + 34
    let closeR = NSRect(x: cx - closeW, y: top - 30, width: closeW, height: 22)
    fill(closeR, t.card, radius: 6); strokeRect(closeR, t.line, radius: 6)
    symbol("xmark.circle", NSRect(x: closeR.minX + 8, y: closeR.midY - 6, width: 12, height: 12), color: t.muted)
    text(closeLabel, NSPoint(x: closeR.minX + 24, y: closeR.midY - 7), size: 11, color: t.ink, weight: .medium)
    cx = closeR.minX - 10
    // Options ellipsis
    symbol("ellipsis.circle", NSRect(x: cx - 20, y: top - 29, width: 20, height: 20), color: t.muted)
    top -= 74

    // Appearance row
    text("APPEARANCE", NSPoint(x: pad, y: top - 12), size: 11, color: t.muted, weight: .medium)
    let segW: CGFloat = 240, segH: CGFloat = 24
    let segRect = NSRect(x: width - pad - segW, y: top - 22, width: segW, height: segH)
    fill(segRect, t.card, radius: 6); strokeRect(segRect, t.line, radius: 6)
    let segLabels = ["System", "Light", "Dark"]
    for i in 0..<3 {
        let r = NSRect(x: segRect.minX + CGFloat(i)*segW/3, y: segRect.minY, width: segW/3, height: segH)
        if i == seg { fill(r.insetBy(dx: 2, dy: 2), t.accent, radius: 5) }
        let tc = i == seg ? NSColor.white : t.ink
        text(segLabels[i], NSPoint(x: r.midX - measure(segLabels[i], 12, weight: .medium)/2, y: r.midY - 8),
             size: 12, color: tc, weight: .medium)
    }
    top -= 34

    // Tab picker
    let tabW = panelW, tabH: CGFloat = 26
    let tabRect = NSRect(x: pad, y: top - tabH, width: tabW, height: tabH)
    fill(tabRect, t.card, radius: 6); strokeRect(tabRect, t.line, radius: 6)
    let tabs = ["Maintenance", "Installed", "Updates (7)"]
    let activeTab = tab == .installed ? 1 : (tab == .updates ? 2 : 0)
    for i in 0..<3 {
        let r = NSRect(x: tabRect.minX + CGFloat(i)*tabW/3, y: tabRect.minY, width: tabW/3, height: tabH)
        let w: NSFont.Weight = i == activeTab ? .semibold : .regular
        if i == activeTab { fill(r.insetBy(dx: 2, dy: 2), t.panel, radius: 5); strokeRect(r.insetBy(dx: 2, dy: 2), t.line, radius: 5) }
        text(tabs[i], NSPoint(x: r.midX - measure(tabs[i], 12, weight: w)/2, y: r.midY - 8), size: 12, color: t.ink, weight: w)
    }
    top -= 38

    switch tab {
    case .maintenance:
        let cols = 2, gap: CGFloat = 10
        let cardW = (panelW - gap) / CGFloat(cols)
        let cardH: CGFloat = 67
        for (idx, a) in actions.enumerated() {
            let col = idx % cols, row = idx / cols
            let x = pad + CGFloat(col) * (cardW + gap)
            let y = top - cardH - CGFloat(row) * (cardH + gap)
            let r = NSRect(x: x, y: y, width: cardW, height: cardH)
            fill(r, t.card, radius: 12); strokeRect(r, t.line, radius: 12)
            symbol(a.symbol, NSRect(x: x + 12, y: r.maxY - 32, width: 20, height: 20), color: t.accent, weight: .semibold)
            text(a.title, NSPoint(x: x + 42, y: r.maxY - 24), size: 14, color: t.ink, weight: .semibold)
            text(a.detail, NSPoint(x: x + 42, y: r.maxY - 42), size: 11, color: t.muted)
            text("brew \(a.command)", NSPoint(x: x + 42, y: r.maxY - 58), size: 10, color: t.muted, mono: true)
        }
        top -= cardH * 3 + gap * 2 + 12
    case .installed:
        let rows = [("wget", "Internet file retriever", "1.25.0", "Formula"),
                    ("ripgrep", "Fast recursive search tool", "14.1.1", "Formula"),
                    ("Visual Studio Code", "Code editor", "1.98.2", "Cask"),
                    ("node", "JavaScript runtime", "22.14.0", "Formula"),
                    ("iterm2", "Terminal emulator", "3.5.11", "Cask")]
        let sf = NSRect(x: pad, y: top - 26, width: panelW, height: 26)
        fill(sf, t.card, radius: 7); strokeRect(sf, t.line, radius: 7)
        symbol("magnifyingglass", NSRect(x: pad + 8, y: sf.midY - 7, width: 13, height: 13), color: t.muted)
        text("Search installed packages", NSPoint(x: pad + 28, y: sf.midY - 7), size: 12, color: t.muted)
        top -= 36
        for r in rows {
            let rr = NSRect(x: pad, y: top - 46, width: panelW, height: 46)
            fill(rr, t.card, radius: 10); strokeRect(rr, t.line, radius: 10)
            text(r.0, NSPoint(x: pad + 14, y: rr.maxY - 20), size: 14, color: t.ink, weight: .semibold)
            text(r.1, NSPoint(x: pad + 14, y: rr.maxY - 38), size: 11, color: t.muted)
            let bw: CGFloat = r.3 == "Cask" ? 44 : 58
            let br = NSRect(x: rr.maxX - 190, y: rr.midY - 9, width: bw, height: 18)
            fill(br, t.accent.withAlphaComponent(0.16), radius: 9)
            text(r.3, NSPoint(x: br.minX + 8, y: br.midY - 7), size: 10, color: t.accent, weight: .semibold)
            text(r.2, NSPoint(x: rr.maxX - 118, y: rr.midY - 7), size: 11, color: t.muted, mono: true)
            let ub = NSRect(x: rr.maxX - 84, y: rr.midY - 11, width: 74, height: 22)
            strokeRect(ub, t.line, radius: 6)
            text("Uninstall", NSPoint(x: ub.minX + 8, y: ub.midY - 7), size: 11, color: t.ink)
            top -= 54
        }
        top -= 6
    case .updates:
        let rows = [("openexr", "3.4.15_1", "3.5.0", false),
                    ("jpeg-xl", "0.12.0", "0.12.0_1", false),
                    ("node", "22.13.1", "22.14.0", false),
                    ("python@3.12", "3.12.7", "3.12.8", true),
                    ("ripgrep", "14.1.0", "14.1.1", false)]
        let hr = NSRect(x: pad, y: top - 30, width: panelW, height: 30)
        text("7 available updates", NSPoint(x: pad, y: hr.midY - 7), size: 12, color: t.muted, weight: .medium)
        let ua = NSRect(x: hr.maxX - 108, y: hr.midY - 12, width: 108, height: 24)
        fill(ua, t.accent, radius: 6)
        text("Upgrade All", NSPoint(x: ua.minX + 14, y: ua.midY - 8), size: 12, color: .white, weight: .semibold)
        top -= 40
        for r in rows {
            let rr = NSRect(x: pad, y: top - 42, width: panelW, height: 42)
            fill(rr, t.card, radius: 10); strokeRect(rr, t.line, radius: 10)
            text(r.0, NSPoint(x: pad + 14, y: rr.maxY - 20), size: 14, color: t.ink, weight: .semibold)
            text("\(r.1)  →  \(r.2)", NSPoint(x: pad + 14, y: rr.maxY - 38), size: 11, color: t.muted, mono: true)
            if r.3 {
                text("Pinned", NSPoint(x: rr.maxX - 78, y: rr.midY - 7), size: 11, color: t.muted)
            } else {
                let ub = NSRect(x: rr.maxX - 84, y: rr.midY - 11, width: 74, height: 22)
                fill(ub, t.accent.withAlphaComponent(0.16), radius: 6)
                text("Upgrade", NSPoint(x: ub.minX + 12, y: ub.midY - 7), size: 11, color: t.accent, weight: .medium)
            }
            top -= 50
        }
        top -= 6
    case .console:
        break
    }

    // Console panel
    let consoleH: CGFloat = tab == .console ? top - pad - 26 : 150
    let consoleRect = NSRect(x: pad, y: pad + 22, width: panelW, height: consoleH)
    fill(consoleRect, t.console, radius: 12); strokeRect(consoleRect, t.line, radius: 12)
    let chY = consoleRect.maxY - 30
    symbol("terminal", NSRect(x: pad + 12, y: chY + 6, width: 14, height: 14), color: t.ink)
    text(running ? "brew upgrade" : "Console", NSPoint(x: pad + 32, y: chY + 6), size: 12, color: t.ink, weight: .medium, mono: true)
    let dotColor = running ? t.accent : t.green
    fill(NSRect(x: consoleRect.maxX - 92, y: chY + 9, width: 7, height: 7), dotColor, radius: 3.5)
    text(running ? "Running" : "Succeeded", NSPoint(x: consoleRect.maxX - 78, y: chY + 5), size: 11, color: t.ink, weight: .medium)
    strokeRect(NSRect(x: consoleRect.minX, y: chY, width: consoleRect.width, height: 1), t.line)
    let lines = running ? [
        "[10:24:07] $ brew upgrade",
        "==> Upgrading 7 outdated packages:",
        "openexr 3.4.15_1 -> 3.5.0",
        "==> Downloading https://ghcr.io/v2/homebrew/core/openexr",
        "######################################  100.0%",
        "==> Pouring openexr--3.5.0.arm64_sonoma.bottle.tar.gz",
    ] : [
        "[10:24:07] $ brew outdated --json=v2",
        "7 available updates in current definitions.",
        "",
        "[10:24:09] Succeeded · Exit 0",
        "Choose an action above.",
    ]
    var ly = chY - 16
    for line in lines {
        text(line, NSPoint(x: pad + 12, y: ly), size: 11, color: line.hasPrefix("==>") ? t.accent : t.muted, mono: true)
        ly -= 16
        if ly < consoleRect.minY + 30 { break }
    }
    strokeRect(NSRect(x: consoleRect.minX, y: consoleRect.minY + 30, width: consoleRect.width, height: 1), t.line)
    symbol("doc.on.doc", NSRect(x: pad + 12, y: consoleRect.minY + 9, width: 12, height: 12), color: t.muted)
    text("Copy", NSPoint(x: pad + 28, y: consoleRect.minY + 9), size: 11, color: t.muted)
    symbol("trash", NSRect(x: pad + 66, y: consoleRect.minY + 9, width: 12, height: 12), color: t.muted)
    text("Clear", NSPoint(x: pad + 82, y: consoleRect.minY + 9), size: 11, color: t.muted)
    text("Follow", NSPoint(x: pad + 122, y: consoleRect.minY + 9), size: 11, color: t.muted)
    let stopR = NSRect(x: consoleRect.maxX - 66, y: consoleRect.minY + 6, width: 56, height: 18)
    if running { fill(stopR, t.red, radius: 5); text("Stop", NSPoint(x: stopR.minX + 16, y: stopR.midY - 7), size: 11, color: .white, weight: .medium) }
    else { strokeRect(stopR, t.line, radius: 5); text("Stop", NSPoint(x: stopR.minX + 16, y: stopR.midY - 7), size: 11, color: t.muted) }

    text("/opt/homebrew/bin/brew", NSPoint(x: pad, y: pad - 2), size: 10, color: t.muted, mono: true)
    let ftr = "One command at a time"
    text(ftr, NSPoint(x: width - pad - measure(ftr, 10), y: pad - 2), size: 10, color: t.muted)

    NSGraphicsContext.restoreGraphicsState()
    return bmp
}

func drawAppIcon(_ rect: NSRect, _ t: Theme) {
    // Use the real bundled app icon artwork (light/dark variants).
    let name = t.dark ? "AppIconDark" : "AppIconLight"
    let path = "\(resourcesDir)/\(name).png"
    if let img = NSImage(contentsOfFile: path) {
        // Clip to a rounded square so it reads like an app icon in the header.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: rect.width*0.22, yRadius: rect.width*0.22).addClip()
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    } else {
        // Fallback: neutral tile if the artwork is unavailable.
        fill(rect, t.card, radius: rect.width*0.22)
    }
}

func save(_ bmp: NSBitmapImageRep, _ path: String) {
    try! bmp.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

// MARK: - Output

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/assets"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let dark = Theme(dark: true)
let light = Theme(dark: false)
let W: CGFloat = 560, H: CGFloat = 680

save(renderDashboard(width: W, height: H, theme: dark, tab: .maintenance, seg: 2), "\(out)/hero.png")
save(renderDashboard(width: W, height: H, theme: dark, tab: .maintenance, seg: 2), "\(out)/view-maintenance.png")
save(renderDashboard(width: W, height: H, theme: dark, tab: .installed, seg: 2), "\(out)/view-installed.png")
save(renderDashboard(width: W, height: H, theme: dark, tab: .updates, seg: 2), "\(out)/view-updates.png")
save(renderDashboard(width: W, height: H, theme: dark, tab: .console, running: true, seg: 2), "\(out)/view-console.png")
save(renderDashboard(width: W, height: H, theme: light, tab: .maintenance, seg: 1), "\(out)/light.png")
save(renderDashboard(width: W, height: H, theme: dark, tab: .maintenance, seg: 2), "\(out)/dark.png")
save(renderDashboard(width: W, height: H, theme: dark, tab: .installed, seg: 2), "\(out)/installed.png")
save(renderDashboard(width: W, height: H, theme: dark, tab: .updates, seg: 2), "\(out)/updates.png")
save(renderDashboard(width: W, height: H, theme: dark, tab: .console, running: true, seg: 2), "\(out)/console.png")
save(renderDashboard(width: W, height: H, theme: light, tab: .updates, seg: 1), "\(out)/updates-light.png")
