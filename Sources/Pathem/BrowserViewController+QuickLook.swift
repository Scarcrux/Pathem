import AppKit
import Quartz

// Quick Look preview-panel support (Space to preview the selection), split out of
// BrowserViewController.
extension BrowserViewController {
    // MARK: - Quick Look

    @objc func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// File URLs for the active pane's current selection (Quick Look targets).
    private var quickLookURLs: [URL] {
        guard let pane = activePane else { return [] }
        return pane.selectedLocalURLs()  // location-aware: previews the right file in smart views too
    }

    // Quick Look invokes these on the main thread, but the protocol/responder
    // methods are nonisolated, so hop onto the main actor explicitly.
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { quickLookURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        // Return URL (Sendable) out of the actor hop, then bridge to NSURL.
        let url: URL? = MainActor.assumeIsolated {
            let urls = quickLookURLs
            return index < urls.count ? urls[index] : nil
        }
        return url.map { $0 as NSURL }
    }
}
