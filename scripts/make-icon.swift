// Draws the FlacToAiff app icon (a vinyl record under a FLAC → AIFF arrow) and
// writes a complete .iconset folder. Usage: make-icon <out.iconset>
// Then: iconutil -c icns <out.iconset>
import AppKit

/// All geometry is in a 1024×1024 design space, following Apple's macOS icon grid
/// (824-pt rounded square centred on the canvas).
func drawIcon(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    }
    let center = CGPoint(x: 512, y: 470)   // record + arrow share this centre; sits low to leave room above

    // Background tile with drop shadow.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(tile); ctx.setFillColor(color(0x1A1433)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x3A2A70), color(0x120E26)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Record body.
    let recordR: CGFloat = 215
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.55))
    ctx.addEllipse(in: CGRect(x: center.x - recordR, y: center.y - recordR, width: recordR * 2, height: recordR * 2))
    ctx.setFillColor(color(0x0B0B0F)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - recordR, y: center.y - recordR, width: recordR * 2, height: recordR * 2))
    ctx.clip()
    ctx.drawRadialGradient(gradient([color(0x26262E), color(0x0B0B0F)]),
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: recordR, options: [])
    // Grooves.
    ctx.setLineWidth(2)
    var r: CGFloat = 96
    while r < recordR - 8 {
        ctx.setStrokeColor(color(0xFFFFFF, r.truncatingRemainder(dividingBy: 36) < 12 ? 0.09 : 0.04))
        ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        r += 12
    }
    // Light sheen: two opposing wedges.
    for start in [CGFloat.pi * 0.15, CGFloat.pi * 1.15] {
        ctx.move(to: center)
        ctx.addArc(center: center, radius: recordR, startAngle: start, endAngle: start + .pi * 0.22, clockwise: false)
        ctx.closePath()
        ctx.setFillColor(color(0xFFFFFF, 0.07)); ctx.fillPath()
    }
    ctx.restoreGState()

    // Centre label.
    let labelR: CGFloat = 78
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - labelR, y: center.y - labelR, width: labelR * 2, height: labelR * 2))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFF9A3D), color(0xFF3D7F)]),
                           start: CGPoint(x: center.x - labelR, y: center.y + labelR),
                           end: CGPoint(x: center.x + labelR, y: center.y - labelR), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(color(0x000000, 0.25)); ctx.setLineWidth(3)
    ctx.strokeEllipse(in: CGRect(x: center.x - 52, y: center.y - 52, width: 104, height: 104))
    ctx.setFillColor(color(0x120E26))
    ctx.fillEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))

    // Conversion arrow: a half-circle over the record, left end → right end, head pointing down.
    let arcR: CGFloat = 300
    let arcStart = CGFloat.pi, arcEnd: CGFloat = 0   // clockwise over the top
    let arrowColor = color(0xFFB347)
    ctx.setStrokeColor(arrowColor); ctx.setLineWidth(30); ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: arcR, startAngle: arcStart, endAngle: arcEnd + 0.12, clockwise: true)
    ctx.strokePath()
    // Arrowhead pointing along the clockwise tangent at arcEnd.
    let tip = CGPoint(x: center.x + arcR * cos(arcEnd), y: center.y + arcR * sin(arcEnd))
    let tangent = CGPoint(x: sin(arcEnd), y: -cos(arcEnd))      // clockwise direction
    let normal = CGPoint(x: cos(arcEnd), y: sin(arcEnd))
    let len: CGFloat = 66, half: CGFloat = 40
    let base = CGPoint(x: tip.x - tangent.x * len, y: tip.y - tangent.y * len)
    ctx.move(to: CGPoint(x: tip.x + tangent.x * 6, y: tip.y + tangent.y * 6))
    ctx.addLine(to: CGPoint(x: base.x + normal.x * half, y: base.y + normal.y * half))
    ctx.addLine(to: CGPoint(x: base.x - normal.x * half, y: base.y - normal.y * half))
    ctx.closePath()
    ctx.setFillColor(arrowColor); ctx.fillPath()

    // Format labels under each end of the arrow: source on the left, result on the right.
    drawLabel("FLAC", at: CGPoint(x: center.x - arcR, y: center.y - 122), color: arrowColor, in: ctx)
    drawLabel("AIFF", at: CGPoint(x: center.x + arcR, y: center.y - 122), color: arrowColor, in: ctx)

    ctx.restoreGState()
}

/// Draw `text` horizontally centred on `point` (its baseline), in heavy SF Rounded.
func drawLabel(_ text: String, at point: CGPoint, color: CGColor, in ctx: CGContext) {
    let base = NSFont.systemFont(ofSize: 54, weight: .heavy)
    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 54) } ?? base
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: color, .kern: 1.5,
    ]))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: point.x - width / 2, y: point.y)
    CTLineDraw(line, ctx)
}

func renderPNG(pixels: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try renderPNG(pixels: pt, to: out.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try renderPNG(pixels: pt * 2, to: out.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
