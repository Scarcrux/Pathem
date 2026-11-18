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
    #if DEBUG
    private(set) var debugShowCount = 0
    var debugShownURL: URL? { shownURL }
    #endif

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
        // The fallback icon must never hold the preview open against its neighbors. Its
        // 32pt intrinsic size plus a required 24pt inset used to demand 56pt at priority 750,
        // tying with (and beating) the gallery's name label, which then got 0pt with both
        // drawers open (layout matrix LM2-F4). The icon scales anyway, so it gives way first.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            iconView.setContentCompressionResistancePriority(.defaultLow - 1, for: axis)
        }
        let insets = [
            iconView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            iconView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -24),
        ]
        for inset in insets { inset.priority = .defaultHigh - 1 }
        addSubview(iconView)
        addSubview(quickLook)
        NSLayoutConstraint.activate(
            [
                quickLook.leadingAnchor.constraint(equalTo: leadingAnchor),
                quickLook.trailingAnchor.constraint(equalTo: trailingAnchor),
                quickLook.topAnchor.constraint(equalTo: topAnchor),
                quickLook.bottomAnchor.constraint(equalTo: bottomAnchor),
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ] + insets)
    }

    /// Show `url`. Folders, online-only (dataless) items, and `nil` fall back to `fallbackIcon`
    /// (or the file's Finder icon) rather than driving Quick Look -- previewing a dataless file
    /// would force it to download. Everything else Quick Look renders live; a type with no
    /// generator shows its own big type icon inside the view, which is the graceful outcome.
    func show(
        _ url: URL?, isDirectory: Bool = false, isDataless: Bool = false,
        fallbackIcon: NSImage? = nil
    ) {
        #if DEBUG
        debugShowCount += 1
        #endif
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
