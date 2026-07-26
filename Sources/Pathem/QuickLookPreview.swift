import AppKit
import Quartz

/// A live Quick Look preview of a single file, with a graceful icon fallback for folders,
/// online-only (dataless) items, and anything Quick Look can't render. Shared by the gallery
/// view's large preview and the column view's preview column, so both show real file content
/// (scrollable PDFs, playable audio/video, selectable text, rendered images) instead of a
/// static thumbnail -- which is what made those views read as an enlarged icon grid.
@MainActor
final class QuickLookPreview: NSView {
    private let quickLook = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    private let iconView = NSImageView()
    private var shownURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        quickLook.translatesAutoresizingMaskIntoConstraints = false
        // Don't auto-play audio/video the instant it's selected; the user clicks to start it,
        // matching Finder's gallery. Otherwise arrow-keying past a movie blasts sound.
        quickLook.autostarts = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        addSubview(iconView)
        addSubview(quickLook)
        NSLayoutConstraint.activate([
            quickLook.leadingAnchor.constraint(equalTo: leadingAnchor),
            quickLook.trailingAnchor.constraint(equalTo: trailingAnchor),
            quickLook.topAnchor.constraint(equalTo: topAnchor),
            quickLook.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            iconView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -24),
        ])
    }

    /// Show `url`. Folders, online-only (dataless) items, and `nil` fall back to `fallbackIcon`
    /// (or the file's Finder icon) rather than driving Quick Look -- previewing a dataless file
    /// would force it to download. Everything else Quick Look renders live; a type with no
    /// generator shows its own big type icon inside the view, which is the graceful outcome.
    func show(_ url: URL?, isDirectory: Bool = false, isDataless: Bool = false, fallbackIcon: NSImage? = nil) {
        guard let url, !isDirectory, !isDataless else {
            quickLook.previewItem = nil
            quickLook.isHidden = true
            iconView.isHidden = false
            iconView.image = fallbackIcon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            shownURL = nil
            return
        }
        iconView.isHidden = true
        quickLook.isHidden = false
        if shownURL == url {
            quickLook.refreshPreviewItem()  // same file changed on disk: repaint it
        } else {
            quickLook.previewItem = url as NSURL
        }
        shownURL = url
    }
}
