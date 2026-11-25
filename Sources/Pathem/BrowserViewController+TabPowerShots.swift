#if DEBUG
import AppKit
import PathemEngine

// PATHEM_TABPOWER_SHOT=<dir> (with PATHEM_DEMO=1): in-process renders of the tab lock glyph and
// the Ctrl-Tab switcher overlay over the demo workspace. Needs no screen-recording permission.
@MainActor
extension BrowserViewController {
    func debugRenderTabPower(toDir dir: String, done: @escaping (Bool) -> Void) {
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        guard let demo = demoLayout else {
            print("TABPOWER SHOT: needs PATHEM_DEMO=1")
            done(false)
            return
        }
        let root = demo.root
        leftTabs.openTab(at: root.appendingPathComponent("Photos"))
        leftTabs.openTab(at: root.appendingPathComponent("Projects"))
        rightTabs.openTab(at: root.appendingPathComponent("Downloads"))
        // Lock the Photos tab, then prove a locked tab diverts navigation into a new tab.
        leftTabs.setLocked(true, at: 1)
        let before = leftTabs.tabCount
        leftTabs.selectTab(1)
        let locked = leftTabs.activePane
        locked?.navigateFromUser(to: root.appendingPathComponent("Music"))
        let diverted =
            leftTabs.tabCount == before + 1 && locked?.currentURL.lastPathComponent == "Photos"
            && leftTabs.activePane?.currentURL.lastPathComponent == "Music"
            && leftTabs.activeTabIndex == 2
        print("TABPOWER CHECK divert-new-tab-next-to-locked: \(diverted ? "PASS" : "FAIL")")
        leftTabs.selectTab(1)
        let closeCount = leftTabs.tabCount
        leftTabs.closeActiveTab()  // beeps: locked
        let refused = leftTabs.tabCount == closeCount
        print("TABPOWER CHECK locked-close-refused: \(refused ? "PASS" : "FAIL")")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            debugRender(to: dir + "/tabs-locked.png")
            openTabSwitcher(reverse: false, immediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                tabSwitcher.debugSelectNext()
                if let panel = tabSwitcher.debugPanel, let content = panel.contentView,
                    let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
                {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    let host = view
                    // Composite the panel over the window render so the PNG shows it in place.
                    if let base = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: base)
                        let image = NSImage(size: host.bounds.size)
                        image.addRepresentation(base)
                        let out = NSImage(size: host.bounds.size)
                        out.lockFocus()
                        image.draw(in: NSRect(origin: .zero, size: host.bounds.size))
                        let frame = view.window?.convertFromScreen(panel.frame) ?? .zero
                        let local = host.convert(frame, from: nil)
                        NSColor.black.withAlphaComponent(0.78).setFill()
                        NSBezierPath(roundedRect: local, xRadius: 12, yRadius: 12).fill()
                        let panelImage = NSImage(size: content.bounds.size)
                        panelImage.addRepresentation(rep)
                        panelImage.draw(in: local)
                        out.unlockFocus()
                        if let tiff = out.tiffRepresentation,
                            let png = NSBitmapImageRep(data: tiff)?.representation(
                                using: .png, properties: [:])
                        {
                            try? png.write(to: URL(fileURLWithPath: dir + "/tab-switcher.png"))
                        }
                    }
                }
                let chosen = tabSwitcher.selection?.chosen
                let valid = chosen != nil
                tabSwitcher.cancel()
                print("TABPOWER CHECK switcher-open: \(valid ? "PASS" : "FAIL")")
                let paired = debugCheckPairedFolders()
                done(diverted && refused && valid && paired)
            }
        }
    }

    /// Real folders in a temp tree: following a pair into a subfolder moves the other pane, a
    /// folder with no counterpart leaves it put, and following off does nothing.
    func debugCheckPairedFolders() -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-pairs-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for sub in ["src/a", "src/b", "dst/a"] {
            try? fm.createDirectory(
                at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let src = root.appendingPathComponent("src").standardizedFileURL
        let dst = root.appendingPathComponent("dst").standardizedFileURL
        guard let left = leftTabs.activePane, let right = rightTabs.activePane else { return false }
        let savedPairs = prefs.pairedFolders
        defer { prefs.pairedFolders = savedPairs }
        prefs.pairedFolders = [FolderPair(left: src.path, right: dst.path)]
        left.navigate(to: src)
        right.navigate(to: dst)
        setActiveSide(leftTabs, pane: left)
        followPairedFolders = false
        left.navigate(to: src.appendingPathComponent("a"))
        let offStayed = right.rootURL.path == dst.path
        left.navigate(to: src)
        toggleFollowPairedFolders()  // on
        left.navigate(to: src.appendingPathComponent("a"))
        let followed = right.rootURL.path == dst.appendingPathComponent("a").path
        left.navigate(to: src.appendingPathComponent("b"))
        let heldStill = right.rootURL.path == dst.appendingPathComponent("a").path
        left.navigate(to: src)
        let wentUp = right.rootURL.path == dst.path
        toggleFollowPairedFolders()  // off again
        let ok = offStayed && followed && heldStill && wentUp
        print(
            "TABPOWER CHECK paired-folders: \(ok ? "PASS" : "FAIL") off=\(offStayed) "
                + "follow=\(followed) noMatchHold=\(heldStill) up=\(wentUp)")
        return ok
    }
}
#endif
