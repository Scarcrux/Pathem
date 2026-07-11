// Generates Pathem's app icon: the waypoint-pin P. A bold white P whose
// counter is a map-pin head with a gold location ping, its stem dissolving
// into a dotted gold route that enters from the bottom edge of the plate,
// on an azure macOS squircle with faint topographic cartography.
// Run: swift Packaging/makeicon.swift [out.png]
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Packaging/AppIcon-1024.png"
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ v: UInt32, _ a: CGFloat = 1.0) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
            green: CGFloat((v >> 8) & 0xFF) / 255.0,
            blue: CGFloat(v & 0xFF) / 255.0,
            alpha: a)
}

func makeRep() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    return rep
}

// ---------------------------------------------------------------- pin counter
// The counter (hole) of the P: a map-pin head, tip pointing down.
let pinCenter = NSPoint(x: 558, y: 654)
func pinPath() -> NSBezierPath {
    let pin = NSBezierPath()
    pin.move(to: NSPoint(x: 558, y: 520))
    pin.curve(to: NSPoint(x: 522, y: 592),
              controlPoint1: NSPoint(x: 546, y: 546), controlPoint2: NSPoint(x: 530, y: 572))
    pin.appendArc(withCenter: pinCenter, radius: 72,
                  startAngle: 240, endAngle: -60, clockwise: true)
    pin.curve(to: NSPoint(x: 558, y: 520),
              controlPoint1: NSPoint(x: 586, y: 572), controlPoint2: NSPoint(x: 570, y: 546))
    pin.close()
    return pin
}

// ---------------------------------------------------------------- P layer
// Drawn offscreen so the pin counter can be punched clean through,
// letting the map plate show inside the hole.
let pRep = makeRep()
let pCtx = NSGraphicsContext(bitmapImageRep: pRep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = pCtx
let pcg = pCtx.cgContext

NSColor.white.setFill()

// Bowl: flat top joins the stem, full round right side.
let bowl = NSBezierPath()
bowl.move(to: NSPoint(x: 352, y: 500))
bowl.line(to: NSPoint(x: 352, y: 748))
bowl.appendArc(from: NSPoint(x: 352, y: 780), to: NSPoint(x: 404, y: 780), radius: 32)
bowl.line(to: NSPoint(x: 566, y: 780))
bowl.appendArc(withCenter: NSPoint(x: 566, y: 640), radius: 140,
               startAngle: 90, endAngle: -90, clockwise: true)
bowl.close()
bowl.fill()

// Stem, then a dissolve: the stem breaks into shrinking dashes that hand
// off to the dotted route below.
NSBezierPath(roundedRect: NSRect(x: 352, y: 400, width: 120, height: 320), xRadius: 60, yRadius: 60).fill()
NSBezierPath(roundedRect: NSRect(x: 352, y: 328, width: 120, height: 52), xRadius: 26, yRadius: 26).fill()
NSBezierPath(roundedRect: NSRect(x: 374, y: 270, width: 76, height: 40), xRadius: 20, yRadius: 20).fill()
NSBezierPath(ovalIn: NSRect(x: 397, y: 223, width: 30, height: 30)).fill()

// Subtle material tint on the letter: cool azure-white at the bottom.
pcg.saveGState()
pcg.setBlendMode(.sourceAtop)
let tint = CGGradient(colorsSpace: srgb,
                      colors: [hex(0xCFE1F8).cgColor, NSColor.white.cgColor] as CFArray,
                      locations: [0.0, 1.0])!
pcg.drawLinearGradient(tint, start: CGPoint(x: 512, y: 200), end: CGPoint(x: 512, y: 800),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
pcg.restoreGState()

// Punch the waypoint-pin counter clean through the bowl.
pcg.saveGState()
pcg.setBlendMode(.destinationOut)
pcg.addPath(pinPath().cgPath)
pcg.fillPath()
pcg.restoreGState()

NSGraphicsContext.restoreGraphicsState()

// ---------------------------------------------------------------- main canvas
let rep = makeRep()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

let plateRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let plate = NSBezierPath(roundedRect: plateRect, xRadius: 185, yRadius: 185)

// Plate base with the standard soft macOS drop shadow.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 10,
             color: NSColor.black.withAlphaComponent(0.30).cgColor)
hex(0x0B63C9).setFill()
plate.fill()
cg.restoreGState()

cg.saveGState()
plate.addClip()

// Azure material gradient, lighter at the top.
let grad = NSGradient(colorsAndLocations:
    (hex(0x07458F), 0.0), (hex(0x0B63C9), 0.38), (hex(0x2F86E8), 0.72), (hex(0x66B1FC), 1.0))!
grad.draw(in: plateRect, angle: 90)

// Cartography: faint topographic contour rings.
NSColor.white.withAlphaComponent(0.075).setStroke()
func drawContours(center: NSPoint, radii: [CGFloat], seed: CGFloat) {
    for (i, base) in radii.enumerated() {
        let p1 = seed + CGFloat(i) * 0.9
        let p2 = seed * 1.7 + CGFloat(i) * 1.3
        let path = NSBezierPath()
        var a: CGFloat = 0
        while a <= 360 {
            let t = a * .pi / 180
            let r = base * (1 + 0.07 * sin(3 * t + p1) + 0.045 * sin(7 * t + p2))
            let pt = NSPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
            if a == 0 { path.move(to: pt) } else { path.line(to: pt) }
            a += 4
        }
        path.close()
        path.lineWidth = 3.5
        path.stroke()
    }
}
drawContours(center: NSPoint(x: 772, y: 282), radii: [55, 115, 175, 235, 295], seed: 0.8)
drawContours(center: NSPoint(x: 240, y: 820), radii: [60, 125, 190, 255], seed: 2.3)

// Cartography: scattered surveyor cross ticks.
NSColor.white.withAlphaComponent(0.11).setStroke()
for (x, y) in [(198, 318), (176, 592), (846, 502), (788, 166), (770, 842), (540, 152)] {
    let m = NSBezierPath()
    m.move(to: NSPoint(x: CGFloat(x) - 13, y: CGFloat(y)))
    m.line(to: NSPoint(x: CGFloat(x) + 13, y: CGFloat(y)))
    m.move(to: NSPoint(x: CGFloat(x), y: CGFloat(y) - 13))
    m.line(to: NSPoint(x: CGFloat(x), y: CGFloat(y) + 13))
    m.lineWidth = 4
    m.stroke()
}

// Graphite vignette grounding the bottom of the plate.
let vig = CGGradient(colorsSpace: srgb,
                     colors: [hex(0x0E131C, 0.35).cgColor, hex(0x0E131C, 0.0).cgColor] as CFArray,
                     locations: [0.0, 1.0])!
cg.drawLinearGradient(vig, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 470),
                      options: [.drawsBeforeStartLocation])

// The route: gold dots entering through the bottom edge of the plate,
// curving up into the stem of the P. Dots are spaced evenly by arc length.
func bez(_ t: CGFloat, _ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat) -> CGFloat {
    let u = 1 - t
    return u*u*u*p0 + 3*u*u*t*p1 + 3*u*t*t*p2 + t*t*t*p3
}
func routePoint(_ t: CGFloat) -> NSPoint {
    NSPoint(x: bez(t, 278, 308, 412, 412), y: bez(t, 60, 124, 148, 202))
}
var routeDots: [NSPoint] = []
var prev = routePoint(0)
var acc: CGFloat = 0
var nextAt: CGFloat = 10
for i in 1...500 {
    let pt = routePoint(CGFloat(i) / 500)
    acc += hypot(pt.x - prev.x, pt.y - prev.y)
    if acc >= nextAt {
        routeDots.append(pt)
        nextAt += 46
    }
    prev = pt
}
routeDots.append(routePoint(1))

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: hex(0x052A55, 0.4).cgColor)
var nodeDot: NSPoint? = nil
for pt in routeDots {
    if nodeDot == nil && pt.y > 118 {
        nodeDot = pt  // promote the dot nearest mid-route to a waypoint node
        continue
    }
    hex(0xFFC554).setFill()
    NSBezierPath(ovalIn: NSRect(x: pt.x - 11, y: pt.y - 11, width: 22, height: 22)).fill()
}
if let n = nodeDot {
    hex(0xFFC554).setFill()
    NSBezierPath(ovalIn: NSRect(x: n.x - 17, y: n.y - 17, width: 34, height: 34)).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: n.x - 8, y: n.y - 8, width: 16, height: 16)).fill()
}
cg.restoreGState()

// Composite the P with a lifted shadow.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 22, color: hex(0x04264D, 0.5).cgColor)
cg.draw(pRep.cgImage!, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
cg.restoreGState()

// Inner shadow inside the pin-shaped counter so the hole reads as cut glass.
let pin = pinPath()
cg.saveGState()
pin.addClip()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 16,
             color: NSColor.black.withAlphaComponent(0.5).cgColor)
let inv = NSBezierPath(rect: NSRect(x: -300, y: -300, width: 1700, height: 1700))
inv.append(pin)
inv.windingRule = .evenOdd
NSColor.black.setFill()
inv.fill()
cg.restoreGState()

// Destination: gold marker dot with location-ping pulse rings, inside the counter.
cg.saveGState()
pin.addClip()
hex(0xFFC554, 0.45).setStroke()
let ring1 = NSBezierPath(ovalIn: NSRect(x: pinCenter.x - 44, y: pinCenter.y - 44, width: 88, height: 88))
ring1.lineWidth = 5
ring1.stroke()
hex(0xFFC554, 0.18).setStroke()
let ring2 = NSBezierPath(ovalIn: NSRect(x: pinCenter.x - 58, y: pinCenter.y - 58, width: 116, height: 116))
ring2.lineWidth = 4
ring2.stroke()

let dotRect = NSRect(x: pinCenter.x - 28, y: pinCenter.y - 28, width: 56, height: 56)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -5), blur: 8,
             color: NSColor.black.withAlphaComponent(0.4).cgColor)
hex(0xF5B73F).setFill()
NSBezierPath(ovalIn: dotRect).fill()
cg.restoreGState()
cg.saveGState()
NSBezierPath(ovalIn: dotRect).addClip()
let dotGrad = CGGradient(colorsSpace: srgb,
                         colors: [hex(0xF0A12B).cgColor, hex(0xFFD970).cgColor] as CFArray,
                         locations: [0.0, 1.0])!
cg.drawLinearGradient(dotGrad,
                      start: CGPoint(x: pinCenter.x, y: pinCenter.y - 28),
                      end: CGPoint(x: pinCenter.x, y: pinCenter.y + 28), options: [])
cg.restoreGState()
cg.restoreGState()

// Glass: top sheen plus rim light and a darker bottom rim.
let gloss = CGGradient(colorsSpace: srgb,
                       colors: [NSColor.white.withAlphaComponent(0.0).cgColor,
                                NSColor.white.withAlphaComponent(0.17).cgColor] as CFArray,
                       locations: [0.0, 1.0])!
cg.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 560), end: CGPoint(x: 512, y: 924),
                      options: [.drawsAfterEndLocation])

let rim = NSBezierPath(roundedRect: plateRect.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
rim.lineWidth = 5
cg.saveGState()
cg.clip(to: CGRect(x: 0, y: 620, width: 1024, height: 404))
NSColor.white.withAlphaComponent(0.28).setStroke()
rim.stroke()
cg.restoreGState()
cg.saveGState()
cg.clip(to: CGRect(x: 0, y: 0, width: 1024, height: 280))
NSColor.black.withAlphaComponent(0.20).setStroke()
rim.stroke()
cg.restoreGState()

cg.restoreGState() // plate clip
NSGraphicsContext.restoreGraphicsState()

// ---------------------------------------------------------------- write PNG
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(png.count) bytes)")
