import AppKit

/// Builds a self-contained, privacy-safe fake workspace for screenshots and demos: realistic
/// folders and files (with believable sizes and dates, plus real thumbnails for images) under a
/// throwaway temp directory. Paired with the sidebar's demo mode, nothing on screen reveals real
/// file names, cloud accounts, hostnames, or the user's home path.
enum DemoWorkspace {
    struct Layout {
        let root: URL
        let leftStart: URL
        let rightStart: URL
        /// (display name, SF Symbol, folder) for the sidebar Favorites.
        let favorites: [(name: String, icon: String, url: URL)]
        /// Fake cloud entries (generic names, no account emails).
        let cloud: [(name: String, url: URL)]
        /// Fake volumes (no machine names).
        let volumes: [(name: String, url: URL)]
    }

    static func build() -> Layout {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Pathem-Demo", isDirectory: true)
        try? fm.removeItem(at: root)  // fresh each launch
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        let documents = folder("Documents", in: root)
        text("Welcome to Pathem.md", in: documents, "# Pathem\n\nA fast, native macOS file manager.")
        file("Quarterly Report.pdf", in: documents, bytes: 2_400_000, daysAgo: 3)
        file("Budget.numbers", in: documents, bytes: 340_000, daysAgo: 12)
        file("Contract.pages", in: documents, bytes: 88_000, daysAgo: 40)
        text("Meeting Notes.txt", in: documents, "Standup: ship v1, polish transfers, write docs.")

        let projects = folder("Projects", in: root)
        let pathem = folder("Pathem", in: projects)
        text("README.md", in: pathem, "# Pathem\nDirectory-Opus-class Finder replacement.")
        text("main.swift", in: pathem, "@main enum App { static func main() { print(\"hi\") } }")
        file("logo.sketch", in: pathem, bytes: 1_800_000, daysAgo: 8)
        let site = folder("portfolio-site", in: projects)
        text("index.html", in: site, "<!doctype html><title>Portfolio</title>")
        text("styles.css", in: site, "body { font-family: -apple-system; }")
        _ = folder("ml-experiments", in: projects)

        let photos = folder("Photos", in: root)
        png("Sunset.png", in: photos, daysAgo: 2)
        png("Mountains.png", in: photos, daysAgo: 5)
        png("Coastline.png", in: photos, daysAgo: 9)
        png("Forest.png", in: photos, daysAgo: 14)
        png("City.png", in: photos, daysAgo: 20)
        png("Desert.png", in: photos, daysAgo: 27)

        let downloads = folder("Downloads", in: root)
        file("Pathem-1.0.dmg", in: downloads, bytes: 18_600_000, daysAgo: 1)
        file("dataset.zip", in: downloads, bytes: 246_000_000, daysAgo: 4)
        file("demo-render.mp4", in: downloads, bytes: 92_000_000, daysAgo: 6)
        file("invoice.pdf", in: downloads, bytes: 120_000, daysAgo: 10)

        let music = folder("Music", in: root)
        let album = folder("Nightscapes", in: music)
        file("01 Aurora.flac", in: album, bytes: 41_000_000, daysAgo: 30)
        file("02 Meridian.flac", in: album, bytes: 38_000_000, daysAgo: 30)

        let desktop = folder("Desktop", in: root)
        png("Screenshot.png", in: desktop, daysAgo: 0)

        // Fake cloud + volumes point at demo folders, so clicking them stays in the sandbox.
        let icloud = folder("iCloud Drive", in: root)
        text("shared-notes.txt", in: icloud, "synced")
        let dropbox = folder("Dropbox", in: root)
        text("team-plan.md", in: dropbox, "# Plan")
        let macHD = folder("Macintosh HD", in: root)
        _ = folder("Applications", in: macHD)
        let backups = folder("Time Machine", in: root)
        _ = folder("Latest", in: backups)

        return Layout(
            root: root, leftStart: projects, rightStart: photos,
            favorites: [
                ("Documents", "doc", documents), ("Desktop", "menubar.dock.rectangle", desktop),
                ("Downloads", "arrow.down.circle", downloads), ("Projects", "hammer", projects),
                ("Photos", "photo", photos), ("Music", "music.note", music),
            ],
            cloud: [("iCloud Drive", icloud), ("Dropbox", dropbox)],
            volumes: [("Macintosh HD", macHD), ("Time Machine", backups)])
    }

    // MARK: Builders

    private static func folder(_ name: String, in parent: URL) -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func text(_ name: String, in folder: URL, _ content: String) {
        let url = folder.appendingPathComponent(name)
        try? content.data(using: .utf8)?.write(to: url)
        touch(url, daysAgo: 1)
    }

    /// A sparse file of the given logical size (cheap on disk) so the size column looks real.
    private static func file(_ name: String, in folder: URL, bytes: Int, daysAgo: Int) {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: UInt64(bytes))
            try? handle.close()
        }
        touch(url, daysAgo: daysAgo)
    }

    private static func png(_ name: String, in folder: URL, daysAgo: Int) {
        let url = folder.appendingPathComponent(name)
        if let data = landscapePNG(named: name, side: 512) { try? data.write(to: url) }
        touch(url, daysAgo: daysAgo)
    }

    // MARK: Filler images

    /// One drawing recipe per scene: a sky gradient (top to horizon), an optional sun glow,
    /// an optional flat water band, and far-to-near silhouette layers (rolling hills, or a
    /// rectangular skyline for city scenes).
    private struct Scene {
        let sky: [NSColor]  // top first
        var sun: NSColor? = nil
        var sunAt: NSPoint = NSPoint(x: 0.5, y: 0.45)  // relative 0...1
        var sea: NSColor? = nil
        var layers: [NSColor] = []  // far -> near
        var skyline = false
        var jagged = false  // triangle-wave ridges (mountains) instead of soft hills
    }

    private static func scene(for name: String) -> Scene {
        let key = name.lowercased()
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
        }
        if key.contains("sunset") {
            return Scene(
                sky: [c(0.18, 0.10, 0.32), c(0.70, 0.29, 0.33), c(0.95, 0.65, 0.35)],
                sun: c(1.0, 0.88, 0.63), sunAt: NSPoint(x: 0.5, y: 0.44),
                layers: [c(0.28, 0.14, 0.30), c(0.15, 0.07, 0.18)])
        }
        if key.contains("coast") || key.contains("beach") || key.contains("sea") {
            return Scene(
                sky: [c(0.36, 0.62, 0.86), c(0.78, 0.90, 0.96)],
                sun: c(1.0, 0.98, 0.90), sunAt: NSPoint(x: 0.72, y: 0.62),
                sea: c(0.10, 0.38, 0.60),
                layers: [c(0.91, 0.84, 0.66)])
        }
        if key.contains("forest") || key.contains("wood") {
            return Scene(
                sky: [c(0.76, 0.86, 0.80), c(0.94, 0.96, 0.90)],
                layers: [c(0.55, 0.70, 0.55), c(0.33, 0.53, 0.38), c(0.14, 0.34, 0.22)])
        }
        if key.contains("mountain") || key.contains("alp") || key.contains("peak") {
            return Scene(
                sky: [c(0.30, 0.50, 0.72), c(0.83, 0.90, 0.95)],
                layers: [c(0.62, 0.70, 0.80), c(0.42, 0.52, 0.66), c(0.19, 0.27, 0.39)],
                jagged: true)
        }
        if key.contains("city") || key.contains("skyline") || key.contains("night") {
            return Scene(
                sky: [c(0.20, 0.16, 0.38), c(0.90, 0.55, 0.42)],
                sun: c(1.0, 0.85, 0.63), sunAt: NSPoint(x: 0.32, y: 0.40),
                layers: [c(0.27, 0.23, 0.40), c(0.10, 0.09, 0.18)],
                skyline: true)
        }
        if key.contains("desert") || key.contains("dune") {
            return Scene(
                sky: [c(0.55, 0.74, 0.90), c(0.98, 0.87, 0.62)],
                sun: c(1.0, 0.95, 0.80), sunAt: NSPoint(x: 0.68, y: 0.55),
                layers: [c(0.89, 0.70, 0.42), c(0.77, 0.54, 0.29)])
        }
        // Neutral misty scene for anything else (screenshots, unknown names).
        return Scene(
            sky: [c(0.62, 0.68, 0.78), c(0.87, 0.90, 0.93)],
            layers: [c(0.46, 0.53, 0.64), c(0.29, 0.35, 0.46)])
    }

    /// Draw a soft gradient landscape that reads like a photo thumbnail. Deterministic per
    /// name (a seeded LCG shapes the ridges), so demo screenshots are stable across runs.
    static func landscapePNG(named name: String, side: Int) -> Data? {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let s = CGFloat(side)
        let sceneSpec = scene(for: name)
        var seed: UInt64 = 5381
        for u in name.unicodeScalars { seed = seed &* 33 &+ UInt64(u.value) }
        func rand() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat((seed >> 33) & 0xFF_FFFF) / CGFloat(0xFF_FFFF)
        }

        NSGradient(colors: sceneSpec.sky)?.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)

        if let sun = sceneSpec.sun {
            let r = s * 0.09
            let center = NSPoint(x: sceneSpec.sunAt.x * s, y: sceneSpec.sunAt.y * s)
            let glowRect = NSRect(x: center.x - r * 3, y: center.y - r * 3, width: r * 6, height: r * 6)
            NSGradient(colors: [sun.withAlphaComponent(0.75), sun.withAlphaComponent(0)])?
                .draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)
            sun.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
        }

        if let sea = sceneSpec.sea {
            let horizon = s * 0.42
            let lighter = sea.blended(withFraction: 0.35, of: .white) ?? sea
            NSGradient(colors: [sea, lighter])?
                .draw(in: NSRect(x: 0, y: 0, width: s, height: horizon), angle: 90)
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSRect(x: 0, y: horizon * 0.82, width: s, height: s * 0.004).fill()
            NSRect(x: 0, y: horizon * 0.62, width: s, height: s * 0.003).fill()
        }

        if sceneSpec.skyline {
            for (depth, color) in sceneSpec.layers.enumerated() {
                color.setFill()
                let top = s * (0.46 - 0.12 * CGFloat(depth))
                var x = -s * 0.02
                while x < s {
                    let w = s * (0.05 + 0.09 * rand())
                    let h = top * (0.45 + 0.55 * rand())
                    NSRect(x: x, y: 0, width: w, height: h).fill()
                    x += w + s * 0.012
                }
            }
        } else {
            let far = CGFloat(max(sceneSpec.layers.count - 1, 1))
            for (depth, color) in sceneSpec.layers.enumerated() {
                let t = CGFloat(depth) / far
                let base = s * (0.42 - 0.24 * t)
                let amp = s * (sceneSpec.jagged ? 0.10 : 0.05) * (1.0 - 0.3 * t)
                color.setFill()
                ridgePath(
                    width: s, base: base, amp: amp, bumps: 2.0 + rand() * 2.5,
                    phase: rand() * .pi * 2, jagged: sceneSpec.jagged
                ).fill()
            }
        }
        return rep.representation(using: .png, properties: [:])
    }

    /// A closed silhouette from the bottom edge up to a rolling (or jagged) ridge line.
    private static func ridgePath(
        width: CGFloat, base: CGFloat, amp: CGFloat, bumps: CGFloat, phase: CGFloat, jagged: Bool
    ) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        let steps = 64
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let angle = phase + t * .pi * bumps
            let wave: CGFloat
            if jagged {
                // Triangle wave: sharp peaks that read as a mountain ridge.
                let cycle = (angle / .pi).truncatingRemainder(dividingBy: 2)
                wave = abs(abs(cycle) - 1) * 2 - 1
            } else {
                wave = sin(angle) + 0.4 * sin(angle * 2.3 + 1.3)
            }
            path.line(to: NSPoint(x: t * width, y: base + amp * wave))
        }
        path.line(to: NSPoint(x: width, y: 0))
        path.close()
        return path
    }

    private static func touch(_ url: URL, daysAgo: Int) {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
