import AppKit

extension NSWindow {
    /// Center this window over the app's main window (the browser), so a dialog appears where
    /// the user is looking even after the browser has been moved or resized off the screen
    /// center. Falls back to screen-centering when there is no host window (e.g. the main
    /// window itself). The origin is clamped to the host's visible screen so a dialog never
    /// lands partly off-screen when the browser sits near an edge.
    func centerOverMainWindow() {
        // The panel is usually not yet key/main when this runs, so the browser is still the
        // main window; exclude self defensively in case it is already front.
        let host = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 }.first { $0 !== self }
        guard let host else {
            center()
            return
        }
        let hostFrame = host.frame
        let size = frame.size
        var origin = NSPoint(
            x: hostFrame.midX - size.width / 2,
            y: hostFrame.midY - size.height / 2)
        if let visible = (host.screen ?? screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }
        setFrameOrigin(origin)
    }

    /// Grow this window so its content view's Auto Layout fitting size is fully visible, never
    /// shrinking below the current (designed) size. This is the systematic guard against the
    /// "buttons clipped by the window border" problem: a dialog laid out for English at a
    /// hardcoded height can be too short once a longer localized string wraps to more lines or
    /// the user runs a larger system font, pushing the bottom button row past the window edge.
    /// Growing (never shrinking) keeps scroll-view heights intact while ensuring the button row
    /// always fits. Requires the content pinned top+bottom so the fitting height is determinate.
    /// Call it just before centering/showing, once the content is populated.
    func growToFitContent(minWidth: CGFloat = 0, minHeight: CGFloat = 0) {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fit = content.fittingSize
        let current = content.frame.size
        let target = NSSize(
            width: max(current.width, fit.width, minWidth),
            height: max(current.height, fit.height, minHeight))
        if target.width > current.width || target.height > current.height {
            setContentSize(target)
        }
    }
}
