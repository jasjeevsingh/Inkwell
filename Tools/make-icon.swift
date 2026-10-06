// Draws the Inkwell app icon into an .iconset folder. Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Squircle body with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28).cgColor)
    color(0x1B2236).setFill()
    path.fill()
    ctx.restoreGState()

    // Deep ink gradient.
    ctx.saveGState()
    path.addClip()
    NSGradient(colors: [color(0x2C3A63), color(0x151B2E)])!.draw(in: body, angle: -90)
    // Subtle top sheen.
    NSGradient(colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    ctx.restoreGState()

    // Paper card.
    let card = NSRect(x: 232, y: 214, width: 560, height: 596)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 52, yRadius: 52)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.35).cgColor)
    color(0xFAF7F0).setFill()
    cardPath.fill()
    ctx.restoreGState()

    // "M" glyph.
    let font = NSFont.systemFont(ofSize: 300, weight: .heavy)
    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 300) } ?? font
    let attrs: [NSAttributedString.Key: Any] = [.font: rounded, .foregroundColor: color(0x1E2742)]
    let m = NSAttributedString(string: "M", attributes: attrs)
    let mSize = m.size()
    m.draw(at: NSPoint(x: card.minX + 58, y: card.midY - mSize.height / 2 + 6))

    // Down arrow in accent blue (the Markdown mark).
    let arrowX: CGFloat = card.maxX - 132
    let top: CGFloat = card.midY + 108
    let bottom: CGFloat = card.midY - 112
    let stemW: CGFloat = 50
    let headW: CGFloat = 150
    let headH: CGFloat = 96
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: arrowX - stemW / 2, y: top))
    arrow.line(to: NSPoint(x: arrowX + stemW / 2, y: top))
    arrow.line(to: NSPoint(x: arrowX + stemW / 2, y: bottom + headH))
    arrow.line(to: NSPoint(x: arrowX + headW / 2, y: bottom + headH))
    arrow.line(to: NSPoint(x: arrowX, y: bottom))
    arrow.line(to: NSPoint(x: arrowX - headW / 2, y: bottom + headH))
    arrow.line(to: NSPoint(x: arrowX - stemW / 2, y: bottom + headH))
    arrow.close()
    arrow.lineJoinStyle = .round
    ctx.saveGState()
    arrow.addClip()
    NSGradient(colors: [color(0x5B8CFF), color(0x2F5BEA)])!.draw(in: arrow.bounds, angle: -90)
    ctx.restoreGState()

    // Ink line accents at the bottom of the card.
    color(0x1E2742, 0.14).setFill()
    NSBezierPath(roundedRect: NSRect(x: card.minX + 62, y: card.minY + 92, width: 436, height: 22), xRadius: 11, yRadius: 11).fill()
    NSBezierPath(roundedRect: NSRect(x: card.minX + 62, y: card.minY + 52, width: 300, height: 22), xRadius: 11, yRadius: 11).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let data = drawIcon(size: px).representation(using: .png, properties: [:])!
    try! data.write(to: out.appendingPathComponent("\(name).png"))
}
print("Wrote \(out.path)")
