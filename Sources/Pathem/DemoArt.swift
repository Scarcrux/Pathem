import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Procedural landscape "photographs" for the demo workspace: original artwork drawn in code,
/// so marketing screenshots carry no third-party imagery. Each scene is deterministic per name.
enum DemoArt {
    struct Scene {
        var sky: [NSColor]
        var skyStops: [CGFloat]? = nil
        var sun: NSColor? = nil
        var sunAt = NSPoint(x: 0.5, y: 0.45)
        var sunRadius: CGFloat = 0.045
        var stars = false
        var aurora: [NSColor] = []
        var clouds: NSColor? = nil
        var water: NSColor? = nil
        var horizon: CGFloat = 0.40
        var layers: [NSColor] = []  // far -> near
        var roughness: CGFloat = 0.5  // 0 soft dunes ... 1 jagged peaks
        var relief: CGFloat = 0.16
        var trees = false
        var skyline = false
        var snow = false
    }

    struct RNG {
        var state: UInt64
        init(_ name: String) {
            state = 0xcbf2_9ce4_8422_2325
            for u in name.unicodeScalars { state = (state ^ UInt64(u.value)) &* 0x100_0000_01b3 }
        }
        mutating func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat((state >> 33) & 0xFF_FFFF) / CGFloat(0xFF_FFFF)
        }
    }

    static func c(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let scenes: [(name: String, scene: Scene)] = [
        (
            "Lofoten Dawn",
            Scene(
                sky: [c(0x1b2a4a), c(0x51618f), c(0xd98a7a), c(0xf7c98f)], sun: c(0xfff1cf),
                sunAt: NSPoint(x: 0.64, y: 0.43), clouds: c(0xf6b9a0), water: c(0x27405f),
                horizon: 0.36, layers: [c(0x5b6689), c(0x343f5e), c(0x161d30)], roughness: 0.95,
                relief: 0.30, snow: true)
        ),
        (
            "Dolomites",
            Scene(
                sky: [c(0x2f6fb5), c(0x7fb4e3), c(0xdcecf7)], clouds: c(0xffffff), horizon: 0.30,
                layers: [c(0xa9b7cc), c(0x7d8ba6), c(0x4f6a55), c(0x2b4a35)], roughness: 1.0,
                relief: 0.34, trees: true, snow: true)
        ),
        (
            "Big Sur Coast",
            Scene(
                sky: [c(0x3f86c9), c(0x9cc9ea), c(0xf3e3c7)], sun: c(0xfffbe8),
                sunAt: NSPoint(x: 0.78, y: 0.66), clouds: c(0xffffff), water: c(0x14557d),
                horizon: 0.44, layers: [c(0x8fa3a8), c(0x55705f), c(0x2c4638)], roughness: 0.6,
                relief: 0.20)
        ),
        (
            "Tromsø Aurora",
            Scene(
                sky: [c(0x050a1c), c(0x0b1d3a), c(0x12365a)], stars: true,
                aurora: [c(0x3df2a0), c(0x38c8ff), c(0x9a6bff)], water: c(0x081a2e), horizon: 0.30,
                layers: [c(0x16263f), c(0x0a1424), c(0x04080f)], roughness: 0.85, relief: 0.22,
                snow: true)
        ),
        (
            "Sahara Dunes",
            Scene(
                sky: [c(0x3d6fb0), c(0xa9c4e0), c(0xf6d6a0)], sun: c(0xfff3d0),
                sunAt: NSPoint(x: 0.30, y: 0.62), horizon: 0.42,
                layers: [c(0xe9b877), c(0xd99a52), c(0xb9742f), c(0x8a4f1c)], roughness: 0.08,
                relief: 0.20)
        ),
        (
            "Kyoto Night",
            Scene(
                sky: [c(0x0e1030), c(0x2a1f55), c(0x7a3b6b), c(0xe07a5f)], sun: c(0xffd9a8),
                sunAt: NSPoint(x: 0.5, y: 0.34), sunRadius: 0.07, stars: true, horizon: 0.30,
                layers: [c(0x3a2a55), c(0x1d1633), c(0x0c0a18)], skyline: true)
        ),
        (
            "Lake Louise",
            Scene(
                sky: [c(0x4a90c8), c(0xa8d3ee), c(0xe9f4f8)], clouds: c(0xffffff),
                water: c(0x2a8f9b),
                horizon: 0.38, layers: [c(0x9fb2c7), c(0x66809c), c(0x2f5a48), c(0x1b3a2d)],
                roughness: 0.9, relief: 0.32, trees: true, snow: true)
        ),
        (
            "Redwoods Fog",
            Scene(
                sky: [c(0x8fa69a), c(0xc9d6c8), c(0xeef0e4)], horizon: 0.46,
                layers: [c(0xa9bcab), c(0x7c9a83), c(0x4f7459), c(0x274a34), c(0x10261a)],
                roughness: 0.35, relief: 0.14, trees: true)
        ),
        (
            "Santorini Dusk",
            Scene(
                sky: [c(0x2b2f77), c(0x7a4b9a), c(0xe8747c), c(0xffc48a)], sun: c(0xffe2b0),
                sunAt: NSPoint(x: 0.36, y: 0.40), sunRadius: 0.055, clouds: c(0xf79a8f),
                water: c(0x3a3470), horizon: 0.38, layers: [c(0x4d3f7a), c(0x241c44)],
                roughness: 0.45, relief: 0.16)
        ),
        (
            "Patagonia",
            Scene(
                sky: [c(0x35507f), c(0x8fa8cf), c(0xf0d9c2)], clouds: c(0xf7e6da),
                water: c(0x3a6f8f),
                horizon: 0.32, layers: [c(0x8794ad), c(0x5c6884), c(0x3b4a45), c(0x1f2b27)],
                roughness: 1.0, relief: 0.38, snow: true)
        ),
        (
            "Namib Sunrise",
            Scene(
                sky: [c(0x402a5e), c(0xb85a6a), c(0xf59a5a), c(0xffd58c)], sun: c(0xfff0c2),
                sunAt: NSPoint(x: 0.58, y: 0.47), sunRadius: 0.06, horizon: 0.44,
                layers: [c(0xc9683a), c(0x9c4526), c(0x602616), c(0x2e120c)], roughness: 0.1,
                relief: 0.22)
        ),
        (
            "Tokyo Skyline",
            Scene(
                sky: [c(0x17213f), c(0x3b4f8a), c(0xc77b8e), c(0xf6b98a)], sun: c(0xffe3bd),
                sunAt: NSPoint(x: 0.70, y: 0.36), sunRadius: 0.05, clouds: c(0xe79aa0),
                horizon: 0.30,
                layers: [c(0x46507f), c(0x262c4f), c(0x0f1226)], skyline: true)
        ),
    ]

    /// Smooth multi-octave value noise in 0...1 along x, for natural ridge lines.
    static func ridge(_ x: CGFloat, seed: CGFloat, roughness: CGFloat) -> CGFloat {
        func hash(_ i: CGFloat) -> CGFloat {
            let v = sin(i * 127.1 + seed * 311.7) * 43758.5453
            return v - floor(v)
        }
        func noise(_ p: CGFloat) -> CGFloat {
            let i = floor(p)
            let f = p - i
            let u = f * f * (3 - 2 * f)
            return hash(i) * (1 - u) + hash(i + 1) * u
        }
        var total: CGFloat = 0
        var amplitude: CGFloat = 1
        var frequency: CGFloat = 1.6
        var norm: CGFloat = 0
        let octaves = 6
        for _ in 0..<octaves {
            var n = noise(x * frequency)
            if roughness > 0.5 { n = 1 - abs(2 * n - 1) }  // ridged noise: sharp crests
            total += n * amplitude
            norm += amplitude
            amplitude *= 0.25 + 0.3 * roughness
            frequency *= 2.05
        }
        return total / norm
    }

    static func render(
        _ name: String, variant: String = "", width: Int = 2000, height: Int = 1250
    ) -> CGImage? {
        guard let scene = scenes.first(where: { $0.name == name })?.scene else { return nil }
        let w = CGFloat(width)
        let h = CGFloat(height)
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }
        var rng = RNG(name + variant)
        let horizonY = h * scene.horizon

        // Sky.
        let stops =
            scene.skyStops
            ?? scene.sky.indices.map { CGFloat($0) / CGFloat(max(scene.sky.count - 1, 1)) }
        NSGradient(colors: scene.sky, atLocations: stops, colorSpace: .sRGB)?
            .draw(in: NSRect(x: 0, y: horizonY, width: w, height: h - horizonY), angle: -90)

        if scene.stars {
            for _ in 0..<420 {
                let x = rng.next() * w
                let y = horizonY + pow(rng.next(), 0.6) * (h - horizonY)
                let r = 0.6 + rng.next() * rng.next() * 2.6
                NSColor.white.withAlphaComponent(0.25 + 0.75 * rng.next()).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r, height: r)).fill()
            }
        }

        // Aurora: soft vertical curtains along a wandering band.
        if !scene.aurora.isEmpty {
            ctx.saveGState()
            ctx.setBlendMode(.screen)
            for (index, color) in scene.aurora.enumerated() {
                let seed = rng.next() * 10
                let baseY = h * (0.58 + 0.10 * CGFloat(index))
                var x: CGFloat = -40
                while x < w + 40 {
                    let t = x / w
                    let y =
                        baseY + h * 0.09 * sin(t * 5.5 + seed) + h * 0.04 * sin(t * 13 + seed * 2)
                    let length = h * (0.16 + 0.18 * ridge(t * 3, seed: seed, roughness: 0.2))
                    let rect = NSRect(x: x, y: y, width: 30, height: length * 1.5)
                    let strength = 0.03 + 0.07 * ridge(t * 9, seed: seed + 3, roughness: 0.9)
                    NSGradient(colors: [
                        color.withAlphaComponent(strength),
                        color.withAlphaComponent(strength * 0.35),
                        color.withAlphaComponent(0),
                    ])?.draw(in: rect, angle: 90)
                    x += 7
                }
            }
            ctx.restoreGState()
        }

        // Sun or moon with a wide glow.
        if let sun = scene.sun {
            let center = NSPoint(x: scene.sunAt.x * w, y: scene.sunAt.y * h)
            let r = w * scene.sunRadius
            let glow = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                colors: [
                    sun.withAlphaComponent(0.85).cgColor, sun.withAlphaComponent(0.34).cgColor,
                    sun.withAlphaComponent(0.12).cgColor, sun.withAlphaComponent(0).cgColor,
                ] as CFArray, locations: [0, 0.16, 0.45, 1])!
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: horizonY, width: w, height: h - horizonY))
            ctx.drawRadialGradient(
                glow, startCenter: center, startRadius: r * 0.9, endCenter: center,
                endRadius: r * 9, options: [])
            ctx.restoreGState()
            sun.setFill()
            NSBezierPath(
                ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            )
            .fill()
        }

        // Clouds: clusters of soft ellipses (blurred later with the whole sky).
        if let cloud = scene.clouds {
            for _ in 0..<9 {
                let cx = rng.next() * w
                let cy = horizonY + (0.30 + 0.62 * rng.next()) * (h - horizonY)
                let span = w * (0.10 + 0.16 * rng.next())
                for _ in 0..<14 {
                    let ex = cx + (rng.next() - 0.5) * span
                    let ey = cy + (rng.next() - 0.5) * span * 0.10
                    let ew = span * (0.25 + 0.45 * rng.next())
                    let eh = ew * (0.16 + 0.12 * rng.next())
                    let rect = NSRect(x: ex - ew / 2, y: ey - eh / 2, width: ew, height: eh)
                    let puff = CGGradient(
                        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                        colors: [
                            cloud.withAlphaComponent(0.30).cgColor,
                            cloud.withAlphaComponent(0).cgColor,
                        ] as CFArray, locations: [0, 1])!
                    ctx.saveGState()
                    ctx.translateBy(x: rect.midX, y: rect.midY)
                    ctx.scaleBy(x: 1, y: eh / ew)
                    ctx.drawRadialGradient(
                        puff, startCenter: .zero, startRadius: 0, endCenter: .zero,
                        endRadius: ew / 2, options: [])
                    ctx.restoreGState()
                }
            }
        }

        // Terrain or skyline, far to near, each layer hazed toward the horizon colour.
        let haze = scene.sky.last ?? .white
        let count = scene.layers.count
        var silhouettes: [NSBezierPath] = []
        for (depth, color) in scene.layers.enumerated() {
            let t = count > 1 ? CGFloat(depth) / CGFloat(count - 1) : 1
            let base = horizonY - h * 0.02 - (horizonY * 0.72) * t
            let path = NSBezierPath()
            if scene.skyline {
                path.move(to: NSPoint(x: 0, y: 0))
                var x: CGFloat = -w * 0.01
                let top = horizonY + h * (0.20 - 0.11 * t)
                while x < w {
                    let bw = w * (0.012 + 0.035 * rng.next()) * (0.7 + 0.6 * t)
                    let bh = (top - base) * (0.25 + 0.75 * pow(rng.next(), 1.6)) + (base)
                    path.line(to: NSPoint(x: x, y: bh))
                    path.line(to: NSPoint(x: x + bw, y: bh))
                    x += bw + w * 0.002
                    path.line(to: NSPoint(x: x, y: base))
                }
                path.line(to: NSPoint(x: w, y: 0))
                path.close()
            } else {
                let amp = h * scene.relief * (1.0 - 0.45 * t)
                let seed = rng.next() * 50
                path.move(to: NSPoint(x: 0, y: 0))
                let steps = 500
                for i in 0...steps {
                    let u = CGFloat(i) / CGFloat(steps)
                    var n = ridge(u * (1.6 + 1.4 * t), seed: seed, roughness: scene.roughness)
                    if scene.roughness > 0.5 { n = pow(n, 1.7) * 1.5 }
                    path.line(to: NSPoint(x: u * w, y: base + amp * n))
                }
                path.line(to: NSPoint(x: w, y: 0))
                path.close()
            }
            silhouettes.append(path)
            let far = color.blended(withFraction: 0.25 * (1 - t), of: haze) ?? color
            ctx.saveGState()
            path.addClip()
            let bounds = path.bounds
            NSGradient(colors: [
                far.blended(withFraction: 0.18, of: .white) ?? far, far,
                far.blended(withFraction: 0.25, of: .black) ?? far,
            ])?.draw(in: bounds, angle: -90)
            if scene.snow && depth < max(count - 2, 1) && !scene.skyline {
                // Snow on the upper part of far ridges.
                let cap = bounds.maxY - (bounds.maxY - base) * 0.42
                NSGradient(colors: [
                    NSColor.white.withAlphaComponent(0.62), NSColor.white.withAlphaComponent(0),
                ])?.draw(
                    in: NSRect(x: 0, y: cap, width: w, height: bounds.maxY - cap), angle: -90)
            }
            if scene.skyline {
                // Lit windows.
                for _ in 0..<Int(1500 * (0.4 + t)) {
                    let x = rng.next() * w
                    let y = base * 0.55 + rng.next() * (bounds.maxY - base * 0.55)
                    let warm = rng.next() > 0.25
                    (warm ? c(0xffd58a) : c(0xbfe3ff)).withAlphaComponent(0.25 + 0.6 * rng.next())
                        .setFill()
                    NSRect(x: x, y: y, width: 3 + 2 * t, height: 4 + 3 * t).fill()
                }
            }
            ctx.restoreGState()
            if scene.trees && depth >= count - 2 {
                // Conifers along the ridge line.
                let treeColor = far.blended(withFraction: 0.35, of: .black) ?? far
                treeColor.setFill()
                let seed = rng.next() * 50
                let amp = h * scene.relief * (1.0 - 0.45 * t)
                var x: CGFloat = 0
                while x < w {
                    let u = x / w
                    let n = ridge(u * (1.6 + 1.4 * t), seed: seed, roughness: scene.roughness)
                    _ = n
                    let groundY = pathY(path, atX: x, fallback: base + amp * 0.5)
                    let th = h * (0.025 + 0.05 * rng.next()) * (0.5 + 0.9 * t)
                    let tw = th * 0.34
                    let tree = NSBezierPath()
                    tree.move(to: NSPoint(x: x - tw, y: groundY - 2))
                    tree.line(to: NSPoint(x: x, y: groundY + th))
                    tree.line(to: NSPoint(x: x + tw, y: groundY - 2))
                    tree.close()
                    tree.fill()
                    x += tw * (0.9 + 1.6 * rng.next())
                }
            }
        }

        // Water: a darkened mirror of what is above the horizon, plus ripples and sun glitter.
        if let water = scene.water, let snapshot = ctx.makeImage() {
            let waterRect = CGRect(x: 0, y: 0, width: w, height: horizonY)
            // Terrain drawn below the horizon is replaced by water for far layers only.
            ctx.saveGState()
            ctx.clip(to: waterRect)
            let nearest = silhouettes.last
            if let nearest, !scene.skyline {
                // Keep the nearest shore in front of the water.
                let clip = NSBezierPath(rect: waterRect)
                clip.append(nearest.reversed)
                clip.addClip()
            }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: horizonY * 2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(snapshot, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
            NSGradient(colors: [
                water.withAlphaComponent(0.55), water.withAlphaComponent(0.80),
                (water.blended(withFraction: 0.5, of: .black) ?? water).withAlphaComponent(0.95),
            ])?.draw(in: waterRect, angle: -90)
            for _ in 0..<260 {
                let y = pow(rng.next(), 1.4) * horizonY
                let depthScale = 1 - y / horizonY
                let len = w * (0.01 + 0.07 * rng.next()) * (0.4 + depthScale)
                let x = rng.next() * w
                NSColor.white.withAlphaComponent(0.05 + 0.10 * rng.next()).setFill()
                NSRect(x: x, y: y, width: len, height: 1 + 2 * depthScale).fill()
            }
            if let sun = scene.sun {
                let cx = scene.sunAt.x * w
                for _ in 0..<180 {
                    let y = rng.next() * horizonY
                    let spread = w * (0.02 + 0.10 * (1 - y / horizonY))
                    let x = cx + (rng.next() - 0.5) * spread
                    sun.withAlphaComponent(0.20 + 0.35 * rng.next()).setFill()
                    NSRect(x: x, y: y, width: 8 + 26 * rng.next(), height: 2).fill()
                }
            }
            ctx.restoreGState()
        }

        guard let drawn = ctx.makeImage() else { return nil }
        return finish(drawn, seed: rng.next())
    }

    /// Height of a silhouette at x, by scanning its flattened points.
    private static func pathY(_ path: NSBezierPath, atX x: CGFloat, fallback: CGFloat) -> CGFloat {
        var best = fallback
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<path.elementCount {
            _ = path.element(at: i, associatedPoints: &points)
            let p = points[0]
            guard p.y > 1 else { continue }
            let d = abs(p.x - x)
            if d < bestDistance {
                bestDistance = d
                best = p.y
            }
        }
        return best
    }

    /// Photographic finish: a little softness, film grain and a vignette, so the result reads
    /// as a photo thumbnail rather than flat vector art.
    private static func finish(_ image: CGImage, seed: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let soft = input.clampedToExtent().applyingGaussianBlur(sigma: 1.1).cropped(to: extent)
        let noise = CIFilter.randomGenerator().outputImage!
            .transformed(by: CGAffineTransform(translationX: seed * 300, y: seed * 170))
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                    "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                    "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.055),
                ]
            ).cropped(to: extent)
        let grained = noise.applyingFilter(
            "CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: soft])
        let vignette = CIFilter.vignette()
        vignette.inputImage = grained
        vignette.intensity = 0.28
        vignette.radius = Float(extent.width * 0.0016)
        let graded = (vignette.outputImage ?? grained).applyingFilter(
            "CIColorControls", parameters: [kCIInputSaturationKey: 1.08, kCIInputContrastKey: 1.04])
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(graded, from: extent)
    }

    /// The scene as file data: JPEG for photographs, PNG where the file name calls for it.
    static func encoded(
        _ name: String, variant: String = "", width: Int = 2000, height: Int = 1250,
        png: Bool = false
    ) -> Data? {
        guard let image = render(name, variant: variant, width: width, height: height) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: image)
        return png
            ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
    }

    /// A square thumbnail-sized PNG chosen by a keyword in the file name (sample folders).
    static func landscapePNG(named name: String, side: Int) -> Data? {
        let key = name.lowercased()
        let table: [(String, String)] = [
            ("sunset", "Santorini Dusk"), ("coast", "Big Sur Coast"), ("forest", "Redwoods Fog"),
            ("mountain", "Dolomites"), ("city", "Tokyo Skyline"), ("desert", "Sahara Dunes"),
        ]
        let scene = table.first { key.contains($0.0) }?.1 ?? "Lake Louise"
        return encoded(scene, variant: name, width: side, height: side, png: true)
    }
}
