// Draws the app icon: a handwritten page and a pen nib on a burgundy cover.
// Usage: swiftc -o make-icon make-icon.swift && ./make-icon AppIcon-1024.png
import AppKit

let canvas: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// The standard macOS icon body: an 824-point rounded square with room for its shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0x000000, 0.28)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
shadow.set()
color(0x7A2C26).setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
NSGradient(starting: color(0xA8463B), ending: color(0x6A241F))!.draw(in: body, angle: -90)
// A soft highlight across the top, like light on a leather cover.
NSGradient(starting: color(0xFFFFFF, 0.14), ending: color(0xFFFFFF, 0))!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// The page, tilted slightly.
context.saveGState()
context.translateBy(x: 500, y: 520)
context.rotate(by: -6 * .pi / 180)
let page = NSRect(x: -230, y: -300, width: 460, height: 600)
NSGraphicsContext.saveGraphicsState()
let pageShadow = NSShadow()
pageShadow.shadowColor = color(0x000000, 0.32)
pageShadow.shadowOffset = NSSize(width: 0, height: -12)
pageShadow.shadowBlurRadius = 26
pageShadow.set()
color(0xFBF4E4).setFill()
NSBezierPath(roundedRect: page, xRadius: 26, yRadius: 26).fill()
NSGraphicsContext.restoreGraphicsState()

let ruledY = stride(from: page.maxY - 120, through: page.minY + 80, by: -74).map { $0 }
color(0xC5CFDA).setStroke()
for y in ruledY {
    let rule = NSBezierPath()
    rule.move(to: NSPoint(x: page.minX + 36, y: y))
    rule.line(to: NSPoint(x: page.maxX - 36, y: y))
    rule.lineWidth = 5
    rule.stroke()
}

// Handwriting: looping strokes resting on the rules.
let ink = color(0x1E2340)
let lengths: [CGFloat] = [0.92, 0.78, 0.88, 0.55, 0.7]
for (index, fraction) in lengths.enumerated() where index < ruledY.count {
    let base = ruledY[index] + 8
    let startX = page.minX + 52
    let endX = startX + (page.width - 104) * fraction
    let stroke = NSBezierPath()
    stroke.lineWidth = 13
    stroke.lineCapStyle = .round
    stroke.lineJoinStyle = .round
    stroke.move(to: NSPoint(x: startX, y: base + 6))
    var x = startX
    var up = true
    let step: CGFloat = 30
    while x + step <= endX {
        let height: CGFloat = up ? (index % 2 == 0 ? 40 : 30) : 4
        stroke.curve(to: NSPoint(x: x + step, y: base + (up ? 4 : 10)),
                     controlPoint1: NSPoint(x: x + step * 0.2, y: base + height),
                     controlPoint2: NSPoint(x: x + step * 0.9, y: base + height * 0.6))
        x += step
        up.toggle()
    }
    ink.setStroke()
    stroke.stroke()
}
context.restoreGState()

// A gold fountain-pen nib resting at the end of the writing.
context.saveGState()
// The tip sits at the end of the fourth line, with the pen reaching toward the lower right.
context.translateBy(x: 622, y: 352)
context.rotate(by: 220 * .pi / 180)
let nib = NSBezierPath()
nib.move(to: NSPoint(x: 0, y: -170))
nib.curve(to: NSPoint(x: 92, y: 90), controlPoint1: NSPoint(x: 40, y: -110), controlPoint2: NSPoint(x: 92, y: 10))
nib.line(to: NSPoint(x: 92, y: 150))
nib.line(to: NSPoint(x: -92, y: 150))
nib.line(to: NSPoint(x: -92, y: 90))
nib.curve(to: NSPoint(x: 0, y: -170), controlPoint1: NSPoint(x: -92, y: 10), controlPoint2: NSPoint(x: -40, y: -110))
nib.close()
NSGraphicsContext.saveGraphicsState()
let nibShadow = NSShadow()
nibShadow.shadowColor = color(0x000000, 0.35)
nibShadow.shadowOffset = NSSize(width: -10, height: 6)
nibShadow.shadowBlurRadius = 18
nibShadow.set()
color(0xC9963F).setFill()
nib.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
nib.addClip()
NSGradient(starting: color(0xF2D27A), ending: color(0xA97A2C))!
    .draw(in: NSRect(x: -92, y: -170, width: 184, height: 320), angle: 0)
NSGraphicsContext.restoreGraphicsState()

let slit = NSBezierPath()
slit.move(to: NSPoint(x: 0, y: -160))
slit.line(to: NSPoint(x: 0, y: 30))
slit.lineWidth = 8
color(0x4A3412).setStroke()
slit.stroke()
color(0x4A3412).setFill()
NSBezierPath(ovalIn: NSRect(x: -17, y: 26, width: 34, height: 34)).fill()
// The grip section above the nib.
color(0x23263F).setFill()
NSBezierPath(roundedRect: NSRect(x: -104, y: 146, width: 208, height: 90), xRadius: 18, yRadius: 18).fill()
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
