// Generates Pathem's app icon: the letter P drawn as a route (thick rounded
// stroke + dashed centerline "path markings" + waypoint nodes) on a rounded
// gradient tile. Run: swift Packaging/makeicon.swift [out.png]
import AppKit

let pixels = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
let size = CGFloat(pixels)

// Style: "route" (path with dashed markings + waypoints) or "river" (a smooth
// flowing stroke in water blues, no markings).
// "river" = smooth flowing stroke, no markings. "aqua" = water palette but keep
// the path markings (the hybrid). Default = path/route in indigo.
let river = CommandLine.arguments.contains("river")
let water = river || CommandLine.arguments.contains("aqua")

let deep = water
    ? CGColor(srgbRed: 0.05, green: 0.32, blue: 0.45, alpha: 1)
    : CGColor(srgbRed: 0.18, green: 0.21, blue: 0.55, alpha: 1)
let topColor = water
    ? CGColor(srgbRed: 0.20, green: 0.66, blue: 0.78, alpha: 1)
    : CGColor(srgbRed: 0.36, green: 0.49, blue: 0.99, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

// Rounded gradient tile.
let margin: CGFloat = 86
let tile = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let radius = tile.width * 0.2237
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [topColor, deep] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// The "P" as a path: vertical spine + upper bowl arc.
let spineX: CGFloat = 440
let yBottom: CGFloat = 250
let yTop: CGFloat = 792
let yMid: CGFloat = 470
let bowlCenter = CGPoint(x: spineX, y: (yTop + yMid) / 2)
let bowlRadius = (yTop - yMid) / 2

let path = CGMutablePath()
path.move(to: CGPoint(x: spineX, y: yBottom))
path.addLine(to: CGPoint(x: spineX, y: yTop))
path.move(to: CGPoint(x: spineX, y: yTop))
path.addArc(center: bowlCenter, radius: bowlRadius, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)

// Thick white route.
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(white)
ctx.setLineWidth(168)
ctx.addPath(path)
ctx.strokePath()

if !river {
    // Dashed centerline (path markings).
    ctx.setStrokeColor(deep)
    ctx.setLineWidth(26)
    ctx.setLineCap(.butt)
    ctx.setLineDash(phase: 0, lengths: [46, 44])
    ctx.addPath(path)
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // Waypoint nodes (white pin with a deep center).
    func node(_ center: CGPoint) {
        ctx.setFillColor(white)
        ctx.fillEllipse(in: CGRect(x: center.x - 60, y: center.y - 60, width: 120, height: 120))
        ctx.setFillColor(deep)
        ctx.fillEllipse(in: CGRect(x: center.x - 27, y: center.y - 27, width: 54, height: 54))
    }
    node(CGPoint(x: spineX, y: yBottom))
    node(CGPoint(x: spineX + bowlRadius, y: bowlCenter.y))
}

NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Packaging/AppIcon-1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
