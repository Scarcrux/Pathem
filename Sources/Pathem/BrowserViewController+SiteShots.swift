#if DEBUG
import AppKit
import PathemEngine

/// Stages the marketing compositions used on the website and in the README
/// (PATHEM_SITE_SHOT). Every shot is a real window over the demo workspace: no mock-ups.
/// The driver is scripts/site-shots.sh.
@MainActor
extension BrowserViewController {
    static let siteShotNames = [
        "hero", "list", "icons", "gallery", "columns", "tree", "terminal", "torrent", "remote",
        "markup", "views",
    ]

    /// Lay out one composition. Runs in three beats (navigate, switch view, select) because
    /// listings load off the main thread and a selection needs its rows to exist.
    func debugStageSiteShot(
        _ name: String, demo: DemoWorkspace.Layout, then done: @escaping () -> Void
    ) {
        guard let left = leftTabs.activePane, let right = rightTabs.activePane else {
            return done()
        }
        let root = demo.root
        func at(_ relative: String) -> URL { root.appendingPathComponent(relative) }
        struct Side {
            var folder: URL
            var mode: ViewFormat.ViewMode
            var select: String?
        }
        var leftSide = Side(folder: at("Projects"), mode: .list, select: nil)
        var rightSide = Side(folder: at("Photos"), mode: .gallery, select: "Lofoten Dawn.jpg")
        var activeLeft = true
        switch name {
        case "list":  // distinct from the hero: two list views, a file selected
            leftSide = Side(folder: at("Projects"), mode: .list, select: "Roadmap.key")
            rightSide = Side(folder: at("Documents"), mode: .list, select: nil)
        case "icons":
            leftSide = Side(folder: at("Photos"), mode: .icon, select: "Tromsø Aurora.jpg")
            rightSide = Side(folder: at("Documents"), mode: .list, select: nil)
        case "views":  // README: icon and gallery views side by side
            leftSide = Side(folder: at("Photos"), mode: .icon, select: nil)
            rightSide = Side(folder: at("Photos"), mode: .gallery, select: "Dolomites Ridge.jpg")
            activeLeft = false
        case "gallery":
            leftSide = Side(folder: at("Photos"), mode: .gallery, select: "Tromsø Aurora.jpg")
            rightSide = Side(folder: at("Projects/aurora-ios"), mode: .list, select: nil)
        case "columns":
            leftSide = Side(
                folder: at("Projects/aurora-ios/Assets"), mode: .column, select: "Launch Screen.png"
            )
            rightSide = Side(folder: at("Downloads"), mode: .list, select: nil)
        case "tree":
            leftSide = Side(folder: at("Projects"), mode: .tree, select: nil)
            rightSide = Side(folder: at("Photos"), mode: .icon, select: nil)
        case "terminal":
            leftSide = Side(folder: at("Projects/aurora-ios"), mode: .list, select: "Package.swift")
            rightSide = Side(
                folder: at("Projects/aurora-ios/Sources/Aurora"), mode: .list, select: nil)
        case "torrent":
            leftSide = Side(folder: at("Downloads"), mode: .list, select: nil)
            rightSide = Side(folder: at("Photos"), mode: .icon, select: nil)
        case "remote":
            leftSide = Side(folder: at("Documents"), mode: .list, select: nil)
            rightSide = Side(folder: at("Projects"), mode: .list, select: nil)
            activeLeft = false
        case "markup":
            leftSide = Side(folder: at("Documents"), mode: .list, select: "Quarterly Report.pdf")
            rightSide = Side(folder: at("Documents/Contracts"), mode: .list, select: nil)
            activeLeft = false
        default: break
        }
        left.navigate(to: leftSide.folder)
        right.navigate(to: rightSide.folder)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            left.setViewMode(leftSide.mode)
            right.setViewMode(rightSide.mode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [self] in
                if let name = rightSide.select { right.select(name: name) }
                if let name = leftSide.select { left.select(name: name) }
                setActiveSide(activeLeft ? leftTabs : rightTabs, pane: activeLeft ? left : right)
                switch name {
                case "terminal":
                    debugStageTerminal()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                        debugStageTerminal()  // the first pass can run before the split has a height
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [self] in
                        terminal.runInline(
                            "clear && git status --short && echo && swift --version",
                            in: leftSide.folder)
                    }
                case "tree":
                    left.debugTreeExpand(names: ["aurora-ios", "ml-experiments"])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        left.debugTreeExpand(names: ["Sources", "checkpoints"])
                    }
                case "torrent": showTorrentsDrawer()
                case "remote": debugStageNetworkView()
                case "markup": debugStageMarkup()
                default: break
                }
                view.layoutSubtreeIfNeeded()
                done()
            }
        }
    }

    /// Render the whole window (title bar, toolbar, content) at twice its point size without
    /// Screen Recording. Useful for layout review on a 1x display, but not for publication:
    /// the gallery's large preview and window materials do not draw through cacheDisplay, so
    /// published images come from the composited capture (PATHEM_SITE_CAPTURE=screen). The
    /// window's own background is painted first: cacheDisplay draws on a transparent backing.
    func debugRenderWindowAt2x(to path: String) {
        guard let window = view.window, let frame = window.contentView?.superview else { return }
        frame.layoutSubtreeIfNeeded()
        let bounds = frame.bounds
        let scale: CGFloat = 2
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
                pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        frame.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SITE SHOT (2x render): \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
    }
}
#endif
