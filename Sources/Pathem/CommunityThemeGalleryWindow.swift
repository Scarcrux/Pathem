import AppKit
import ImageIO
import PathemEngine
import UniformTypeIdentifiers

private final class GalleryDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Decodes one small thumbnail per theme, only when a card asks for it, and keeps the result.
@MainActor
private final class GalleryThumbnails {
    /// The longest side of a decoded thumbnail in pixels: enough for a card at 2x.
    nonisolated static let maximumPixels = 400
    private let cache = NSCache<NSString, CGImage>()
    private(set) var decoded = 0
    private(set) var largestSide = 0

    func cached(_ key: String) -> CGImage? { cache.object(forKey: key as NSString) }

    func load(_ data: Data, key: String) async -> CGImage? {
        if let image = cached(key) { return image }
        let image = await Task.detached(priority: .userInitiated) {
            Self.decode(data, maximumPixels: Self.maximumPixels)
        }.value
        guard let image else { return nil }
        if cached(key) == nil {
            decoded += 1
            largestSide = max(largestSide, image.width, image.height)
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// ImageIO scales while decoding, so the full-size screenshot is never held in memory.
    nonisolated static func decode(_ data: Data, maximumPixels: Int) -> CGImage? {
        let lazily = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, lazily) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A screenshot scaled to fill the card, anchored to its top edge.
private final class ThemeThumbnailView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    /// The theme background, shown until the thumbnail is decoded.
    var placeholder: NSColor? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (placeholder ?? .quaternaryLabelColor).setFill()
        frame.fill()
        if let image, let context = NSGraphicsContext.current?.cgContext {
            NSGraphicsContext.saveGraphicsState()
            frame.addClip()
            let scale = max(
                bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
            let size = CGSize(
                width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(
                    x: bounds.midX - size.width / 2, y: bounds.maxY - size.height,
                    width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.separatorColor.setStroke()
        frame.lineWidth = 1
        frame.stroke()
    }
}

private final class ThemeBadgeView: NSView {
    var text = "" {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    private var attributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    }
    private var textSize: NSSize { (text as NSString).size(withAttributes: attributes) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(textSize.width) + 14, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(
            at: NSPoint(x: 7, y: (bounds.height - textSize.height) / 2),
            withAttributes: attributes)
    }
}

private final class ThemeSwatchView: NSView {
    var color: NSColor? {
        didSet {
            isHidden = color == nil
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        color.setFill()
        dot.fill()
        // A dark swatch on a dark card needs a visible edge.
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        dot.lineWidth = 1
        dot.stroke()
    }
}

private final class ThemeCardView: NSView {
    var isChosen = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 9, yRadius: 9)
        NSColor.controlBackgroundColor.setFill()
        outline.fill()
        // The selection ring uses the active Pathem theme's accent.
        (isChosen ? ThemeManager.shared.accent : NSColor.separatorColor).setStroke()
        outline.lineWidth = isChosen ? 3 : 1
        outline.stroke()
    }
}

/// One theme in the grid: screenshot, title, creator, appearance badge, and color swatches.
private final class ThemeCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThemeCard")
    static let size = NSSize(width: 190, height: 194)

    let thumbnail = ThemeThumbnailView()
    /// Identifies the theme this card shows, so a late thumbnail never lands on a reused card.
    var key: String?
    private let titleLabel = NSTextField(labelWithString: "")
    private let creatorLabel = NSTextField(labelWithString: "")
    private let badge = ThemeBadgeView()
    private let background = ThemeSwatchView()
    private let accent = ThemeSwatchView()

    override func loadView() {
        let card = ThemeCardView()
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        creatorLabel.font = .systemFont(ofSize: 11)
        creatorLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, creatorLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // The card speaks for its parts.
            label.setAccessibilityElement(false)
        }
        let footer = NSStackView()
        footer.addView(badge, in: .leading)
        footer.addView(background, in: .trailing)
        footer.addView(accent, in: .trailing)
        footer.spacing = 4
        let stack = NSStackView(views: [thumbnail, titleLabel, creatorLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(8, after: thumbnail)
        stack.setCustomSpacing(7, after: creatorLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -9),
            thumbnail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            thumbnail.heightAnchor.constraint(equalToConstant: 108),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            creatorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        card.setAccessibilityElement(true)
        view = card
    }

    override var isSelected: Bool {
        didSet { (view as? ThemeCardView)?.isChosen = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        key = nil
        thumbnail.image = nil
    }

    func show(_ revision: CommunityThemeRevision, theme: ThemePreset?, key: String) {
        self.key = key
        let mode = CommunityThemeGalleryWindow.appearanceName(theme?.appearance ?? .system)
        titleLabel.stringValue = revision.title
        creatorLabel.stringValue = revision.creator
        badge.text = mode
        background.color = theme.flatMap { ThemeManager.color(fromHex: $0.backgroundHex) }
        accent.color = theme.flatMap { ThemeManager.color(fromHex: $0.accentHex) }
        thumbnail.placeholder = background.color
        view.setAccessibilityLabel(
            String(
                format: L("themes.cardLabel", "%1$@, by %2$@, %3$@"),
                revision.title, revision.creator, mode))
    }
}

/// Browse the shared Themes catalog. Debug builds can also run an isolated local gallery.
@MainActor
final class CommunityThemeGalleryWindow: NSObject, NSWindowDelegate, NSSearchFieldDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate
{
    /// The published catalog. Fetched only when the user opens the gallery, never at launch.
    static let catalogEndpoint = "https://d3v2l0mmdgkblv.cloudfront.net/catalog.json"

    /// Nil only when the configuration directory is unavailable.
    static var storeURL: URL? {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["PATHEM_COMMUNITY_GALLERY"] == "1",
            let path = env["PATHEM_CONFIG_DIR"], !path.isEmpty
        {
            let filename =
                env["PATHEM_SHARED_THEME_CATALOG"] == nil
                ? "community-themes.json" : "shared-community-themes.json"
            return ConfigStore.url(filename)
        }
        #endif
        return ConfigStore.url("shared-community-themes.json")
    }

    /// Nil selects the debug-only local review gallery, which never uses the network.
    static var sharedEndpoint: String? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PATHEM_COMMUNITY_GALLERY"] == "1" {
            return ProcessInfo.processInfo.environment["PATHEM_SHARED_THEME_CATALOG"]
        }
        #endif
        return catalogEndpoint
    }

    static func refreshSharedCatalog(_ endpoint: String, at store: URL) async throws {
        let catalog = try await SharedThemeCatalog.fetch(endpoint)
        _ = try CommunityThemeGallery.update(at: store) { $0.synchronize(catalog) }
    }

    // The release smoke mounts the production gallery without activating the app.
    static func verifyPackagedInstallation(endpoint: String) async throws {
        guard let url = storeURL, let fixture = URL(string: endpoint),
            fixture.scheme == "http", fixture.host == "127.0.0.1", fixture.user == nil,
            fixture.password == nil
        else {
            throw CommunityThemeError.invalidTransition
        }
        try await refreshSharedCatalog(endpoint, at: url)
        var applied: CommunityThemeRevision.Reference?
        let window = try Self(
            url: url, active: nil, preview: { _ in }, apply: { _, reference in applied = reference }
        )
        window.configure()
        window.search.stringValue = "Tidal Marsh"
        window.refresh()
        guard window.scope.segmentCount == 2, let revision = window.selection,
            revision.id == "tidal-marsh", window.screenshot.image != nil
        else { throw CommunityThemeError.invalidListing }
        func click(_ action: Selector) throws {
            guard
                let button = window.actionButtons.first(where: { $0.action == action }),
                NSApp.sendAction(action, to: button.target, from: button)
            else { throw CommunityThemeError.invalidTransition }
        }
        try click(#selector(installSelection))
        try click(#selector(applySelection))
        let stored = try CommunityThemeGallery.load(from: url)
        guard stored.installed[revision.id] == revision, applied == revision.reference else {
            throw CommunityThemeError.invalidTransition
        }
    }

    private let url: URL
    private var gallery: CommunityThemeGallery
    private let preview: (ThemePreset?) -> Void
    private let apply: (ThemePreset, CommunityThemeRevision.Reference?) -> Void
    private var active: CommunityThemeRevision.Reference?
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 1040, height: 690),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private let scope = NSSegmentedControl(
        labels: CommunityThemeGalleryWindow.sharedEndpoint == nil
            ? [
                L("themes.browse", "Browse"), L("integrations.installed", "Installed"),
                L("themes.review", "Review"),
            ] : [L("themes.browse", "Browse"), L("integrations.installed", "Installed")],
        trackingMode: .selectOne,
        target: nil, action: nil)
    private let filter = NSSegmentedControl(
        labels: [
            L("themes.filterAll", "All"), L("prefs.appearanceLight", "Light"),
            L("prefs.appearanceDark", "Dark"),
        ],
        trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let grid = NSCollectionView()
    private let gridScroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private let thumbnails = GalleryThumbnails()
    /// Decoded packages of the cards shown so far, keyed like the thumbnails.
    private var themes: [String: ThemePreset] = [:]
    private let title = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let screenshot = NSImageView()
    private let screenshots = NSPopUpButton()
    private let actions = NSStackView()
    private var actionButtons: [NSButton] = []
    private var rows: [CommunityThemeRevision] = []
    private var selectedReference: CommunityThemeRevision.Reference?
    private var selection: CommunityThemeRevision? {
        rows.first { $0.reference == selectedReference }
    }
    private var selectedCardFrame: NSRect? {
        grid.selectionIndexPaths.first.flatMap { grid.layoutAttributesForItem(at: $0)?.frame }
    }
    private var appearanceFilter: CommunityThemeGallery.AppearanceFilter {
        [.all, .light, .dark][max(0, min(2, filter.selectedSegment))]
    }

    static func appearanceName(_ appearance: Preferences.Appearance) -> String {
        switch appearance {
        case .system: L("prefs.appearanceSystem", "System")
        case .light: L("prefs.appearanceLight", "Light")
        case .dark: L("prefs.appearanceDark", "Dark")
        }
    }

    init(
        url: URL, active: CommunityThemeRevision.Reference?,
        preview: @escaping (ThemePreset?) -> Void,
        apply: @escaping (ThemePreset, CommunityThemeRevision.Reference?) -> Void
    ) throws {
        self.url = url
        self.active = active
        self.preview = preview
        self.apply = apply
        gallery = try CommunityThemeGallery.load(from: url)
        super.init()
    }

    func run() {
        configure()
        panel.center()
        panel.makeFirstResponder(search)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
    }

    private func configure() {
        panel.title = L("prefs.themes", "Themes")
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 840, height: 480)
        scope.selectedSegment = 0
        scope.target = self
        scope.action = #selector(scopeChanged)
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(scopeChanged)
        filter.setAccessibilityLabel(L("prefs.appearanceLabel", "Appearance"))
        search.placeholderString = L("themes.search", "Search titles, creators, and tags")
        search.delegate = self
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = ThemeCardItem.size
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 2, left: 2, bottom: 10, right: 12)
        grid.collectionViewLayout = layout
        grid.register(ThemeCardItem.self, forItemWithIdentifier: ThemeCardItem.identifier)
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsEmptySelection = false
        grid.allowsMultipleSelection = false
        grid.backgroundColors = [.clear]
        grid.setAccessibilityLabel(L("prefs.themes", "Themes"))
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.drawsBackground = false
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 15)
        screenshots.target = self
        screenshots.action = #selector(showScreenshot)
        screenshot.imageScaling = .scaleProportionallyUpOrDown
        screenshot.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        screenshot.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        screenshot.setAccessibilityLabel(L("themes.screenshot", "Theme screenshot"))
        title.font = .boldSystemFont(ofSize: 17)
        status.textColor = .secondaryLabelColor
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 8
        let submit = button(L("themes.submit", "Submit Revision…"), #selector(chooseSubmission))
        let done = button(L("common.done", "Done"), #selector(close))
        done.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: Self.sharedEndpoint == nil ? [submit, done] : [done])
        footer.spacing = 8
        let header = NSStackView(views: [scope, filter, search])
        header.spacing = 12
        let stack = NSStackView(views: [
            title, details, status, actions, screenshots, screenshot,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        guard let content = panel.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = GalleryDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        for view in [header, gridScroll, empty, scroll, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            gridScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            gridScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            gridScroll.trailingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: -8),
            gridScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            empty.centerXAnchor.constraint(equalTo: gridScroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: gridScroll.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: gridScroll.topAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: gridScroll.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 360),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            screenshot.widthAnchor.constraint(equalTo: stack.widthAnchor),
            screenshot.heightAnchor.constraint(equalTo: screenshot.widthAnchor, multiplier: 0.64),
        ])
        refresh()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.stopModal()
        return false
    }

    @objc private func close() { NSApp.stopModal() }

    @objc private func scopeChanged() { refresh() }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
        -> Int
    { rows.count }

    /// Called only for cards near the visible area, so this is where a thumbnail is decoded.
    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: ThemeCardItem.identifier, for: indexPath)
        guard let card = item as? ThemeCardItem, rows.indices.contains(indexPath.item) else {
            return item
        }
        let revision = rows[indexPath.item]
        let key = "\(revision.id)@\(revision.version)"
        let theme = themes[key] ?? (try? revision.theme())
        themes[key] = theme
        card.show(revision, theme: theme, key: key)
        if let image = thumbnails.cached(key) {
            card.thumbnail.image = image
        } else if let data = revision.screenshots.first {
            Task { [weak card, thumbnails] in
                let image = await thumbnails.load(data, key: key)
                if card?.key == key { card?.thumbnail.image = image }
            }
        }
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let index = indexPaths.first?.item, rows.indices.contains(index) else { return }
        selectedReference = rows[index].reference
        refreshDetail()
    }

    private func refresh(preferred: CommunityThemeRevision.Reference? = nil) {
        let previous = preferred ?? selectedReference
        search.isHidden = scope.selectedSegment == 2
        filter.isHidden = scope.selectedSegment == 2
        switch scope.selectedSegment {
        case 1:
            rows = gallery.installedThemes(search.stringValue, appearance: appearanceFilter)
        case 2: rows = gallery.entries.reversed().map(\.revision)
        default: rows = gallery.discover(search.stringValue, appearance: appearanceFilter)
        }
        let index = rows.firstIndex { $0.reference == previous } ?? 0
        selectedReference = rows.indices.contains(index) ? rows[index].reference : nil
        grid.reloadData()
        if selectedReference != nil {
            let chosen: Set<IndexPath> = [IndexPath(item: index, section: 0)]
            grid.selectionIndexPaths = chosen
            // Lay the grid out first, or there is no card frame to scroll to.
            grid.layoutSubtreeIfNeeded()
            if let frame = selectedCardFrame { grid.scrollToVisible(frame.insetBy(dx: 0, dy: -8)) }
        }
        refreshDetail()
    }

    private func refreshDetail() {
        for view in actions.arrangedSubviews { actions.removeView(view) }
        actionButtons = []
        screenshots.removeAllItems()
        screenshot.image = nil
        screenshot.isHidden = selection == nil
        screenshots.isHidden = selection == nil
        empty.isHidden = selection != nil
        guard let revision = selection else {
            // A search or filter that hides every installed theme is "no match", not "none".
            let narrowed =
                scope.selectedSegment == 1 && !gallery.installed.isEmpty
            empty.stringValue =
                narrowed
                ? L("themes.emptyBrowse", "No matching themes")
                : [
                    L("themes.emptyBrowse", "No matching themes"),
                    L("themes.emptyInstalled", "No installed themes"),
                    L("themes.emptyReview", "No submissions"),
                ][
                    scope.selectedSegment]
            title.stringValue = ""
            details.stringValue = ""
            status.stringValue = ""
            return
        }
        title.stringValue = revision.title
        var lines = [
            revision.summary,
            L("themeSubmission.creator", "Creator credit") + ": " + revision.creator + " · "
                + L("themeSubmission.license", "License") + ": " + revision.license,
        ]
        if let source = revision.source {
            lines.append(L("torrents.detail.source", "Source") + ": " + source)
        }
        if !revision.tags.isEmpty { lines.append(revision.tags.joined(separator: " · ")) }
        details.stringValue = lines.joined(separator: "\n")
        screenshots.addItems(
            withTitles: revision.screenshots.indices.map {
                L("themes.screenshot", "Theme screenshot") + " \($0 + 1)"
            })
        showScreenshot()
        let installed = gallery.installed[revision.id]
        let withdrawn = gallery.withdrawn.contains(revision.id)
        var states = [L("info.versionLabel", "Version") + " \(revision.version)"]
        if let installed {
            states.append(L("integrations.installed", "Installed") + " v\(installed.version)")
        }
        if active?.id == revision.id, let active {
            states.append(L("themes.active", "Active") + " v\(active.version)")
        }
        if withdrawn { states.append(L("themes.withdrawn", "Withdrawn")) }
        addAction(
            button(L("menu.group.preview", "Preview"), #selector(previewSelection)))
        switch scope.selectedSegment {
        case 2:
            let record = gallery.entries.first { $0.revision.reference == revision.reference }
            if let review = record?.review {
                states.append(
                    reviewLabel(review.outcome) + " · " + review.reviewer + " · " + review.note)
            } else {
                states.append(L("themes.pending", "Pending review"))
                if !withdrawn {
                    addAction(
                        button(
                            L("themes.approve", L("themes.approve", "Approve")) + "…",
                            #selector(approve)))
                    addAction(
                        button(
                            L("themes.reject", L("themes.reject", "Reject")) + "…",
                            #selector(reject)))
                }
            }
            if !withdrawn {
                addAction(
                    button(
                        L("themes.withdraw", L("themes.withdraw", "Withdraw")) + "…",
                        #selector(confirmWithdrawal)))
            }
        case 1:
            addAction(
                button(L("common.apply", "Apply"), #selector(applySelection)))
            addAction(
                button(
                    L("themes.uninstall", L("themes.uninstall", "Uninstall")) + "…",
                    #selector(confirmUninstall)))
        default:
            if let installed, installed.version < revision.version {
                addAction(
                    button(L("themes.update", "Update"), #selector(installSelection)))
            } else if installed == nil {
                addAction(
                    button(L("integrations.cliInstall", "Install"), #selector(installSelection)))
            }
            if installed != nil {
                addAction(
                    button(L("themes.applyInstalled", "Apply Installed"), #selector(applySelection))
                )
            }
        }
        status.stringValue = states.joined(separator: " · ")
    }

    @objc private func showScreenshot() {
        let index = screenshots.indexOfSelectedItem
        guard let revision = selection, revision.screenshots.indices.contains(index) else { return }
        screenshot.image = NSImage(data: revision.screenshots[index])
    }

    /// Actions sit in rows of two, so long localized titles still fit the detail column.
    private func addAction(_ control: NSButton) {
        actionButtons.append(control)
        if let row = actions.arrangedSubviews.last as? NSStackView,
            row.arrangedSubviews.count < 2
        {
            row.addArrangedSubview(control)
        } else {
            let row = NSStackView(views: [control])
            row.spacing = 8
            actions.addArrangedSubview(row)
        }
    }

    private func button(_ label: String, _ action: Selector) -> NSButton {
        NSButton(title: label, target: self, action: action)
    }

    private func mutate(_ change: (inout CommunityThemeGallery) throws -> Void) throws {
        gallery = try CommunityThemeGallery.update(at: url, change)
    }

    @objc private func previewSelection() {
        guard let revision = selection else { return }
        do {
            try withPreview(revision) {
                let alert = NSAlert()
                alert.messageText = L("menu.group.preview", "Preview") + " · " + revision.title
                alert.informativeText = L(
                    "themes.restore", "Close the preview to restore your appearance.")
                let close = alert.addButton(withTitle: L("themes.closePreview", "Close Preview"))
                close.keyEquivalent = "\u{1b}"
                alert.runModal()
            }
        } catch { showThemeError(error) }
    }

    private func withPreview(_ revision: CommunityThemeRevision, show: () -> Void) throws {
        preview(try revision.theme())
        defer { preview(nil) }
        show()
    }

    @objc private func installSelection() {
        guard let revision = selection else { return }
        do {
            try install(revision.reference)
        } catch { showThemeError(error) }
    }

    private func install(_ reference: CommunityThemeRevision.Reference) throws {
        try mutate { try $0.install(reference) }
        refresh()
    }

    @objc private func applySelection() {
        guard let id = selection?.id else { return }
        do {
            try applyInstalled(id)
        } catch { showThemeError(error) }
    }

    private func applyInstalled(_ id: String) throws {
        gallery = try CommunityThemeGallery.load(from: url)
        guard let revision = gallery.installed[id] else {
            throw CommunityThemeError.invalidTransition
        }
        apply(try revision.theme(), revision.reference)
        active = revision.reference
        refresh()
    }

    @objc private func chooseSubmission() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.json]
        picker.message = L("themes.chooseFile", "Choose a theme submission JSON file.")
        guard picker.runModal() == .OK, let file = picker.url else { return }
        do {
            try submitRevision(at: file)
        } catch { showThemeError(error) }
    }

    private func submitRevision(at file: URL) throws {
        let revision = try CommunityThemeGallery.submission(at: file)
        try mutate { try $0.submit(revision) }
        scope.selectedSegment = 2
        refresh(preferred: revision.reference)
    }

    private func reviewLabel(_ outcome: CommunityThemeGallery.Review.Outcome) -> String {
        switch outcome {
        case .approved: L("themes.approved", "Approved")
        case .rejected: L("themes.rejected", "Rejected")
        case .changesRequested: L("themes.changes", "Changes requested")
        }
    }

    @objc private func approve() { review(.approved) }

    @objc private func reject() { review(.rejected) }

    private func review(_ outcome: CommunityThemeGallery.Review.Outcome) {
        guard let revision = selection else { return }
        let approving = outcome == .approved
        let alert = NSAlert()
        let action = approving ? L("themes.approve", "Approve") : L("themes.reject", "Reject")
        alert.messageText = action + " · " + revision.title + " v\(revision.version)?"
        let reviewer = NSTextField(string: "")
        reviewer.placeholderString = L("themes.reviewer", "Reviewer name")
        reviewer.setAccessibilityLabel(L("themes.reviewer", "Reviewer name"))
        let note = NSTextField(string: "")
        note.placeholderString = L("themes.note", "Decision note")
        note.setAccessibilityLabel(L("themes.note", "Decision note"))
        let fields = NSStackView(views: [reviewer, note])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.frame.size = NSSize(width: 320, height: 56)
        reviewer.widthAnchor.constraint(equalToConstant: 320).isActive = true
        note.widthAnchor.constraint(equalTo: reviewer.widthAnchor).isActive = true
        alert.accessoryView = fields
        alert.window.initialFirstResponder = reviewer
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try recordReview(
                revision.reference, outcome: outcome, reviewer: reviewer.stringValue,
                note: note.stringValue)
        } catch { showThemeError(error) }
    }

    private func recordReview(
        _ reference: CommunityThemeRevision.Reference,
        outcome: CommunityThemeGallery.Review.Outcome,
        reviewer: String, note: String
    ) throws {
        try mutate { try $0.review(reference, outcome: outcome, reviewer: reviewer, note: note) }
        refresh()
    }

    @objc private func confirmWithdrawal() {
        guard let revision = selection,
            confirm(
                L("themes.withdraw", "Withdraw") + " · " + revision.title + "?",
                action: L("themes.withdraw", "Withdraw"),
                detail:
                    L("themes.withdrawDetail", "Installed copies remain available."))
        else { return }
        do {
            try withdraw(revision.id)
        } catch { showThemeError(error) }
    }

    private func withdraw(_ id: String) throws {
        try mutate { try $0.withdraw(id) }
        refresh()
    }

    @objc private func confirmUninstall() {
        guard let revision = selection,
            confirm(
                L("themes.uninstall", "Uninstall") + " · " + revision.title + "?",
                action: L("themes.uninstall", "Uninstall"),
                detail: L(
                    "themes.uninstallDetail",
                    "If this theme is applied, Pathem will return to System appearance."))
        else { return }
        do {
            try uninstall(revision.id)
        } catch { showThemeError(error) }
    }

    private func uninstall(_ id: String) throws {
        try mutate { try $0.uninstall(id) }
        if active?.id == id {
            apply(.system, nil)
            active = nil
        }
        refresh()
    }

    private func confirm(_ title: String, action: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }
}

@MainActor
func showThemeError(_ error: Error) {
    let message: String
    switch error as? CommunityThemeError {
    case .invalidListing:
        message = L("themes.invalidListing", "The listing or attribution fields are invalid.")
    case .invalidScreenshot:
        message = L(
            "themes.invalidScreenshot",
            "Use one to three PNG or JPEG screenshots, each up to 2 MiB and 2400 pixels per side. Exported previews must fit within 300 KiB."
        )
    case .invalidTransition:
        message = L(
            "themes.invalidTransition", "The requested action is unavailable for this revision.")
    case .oversizedFile:
        message = L("themes.oversized", "The gallery file exceeds the size limit.")
    case nil:
        message = error.localizedDescription
    }
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: L("common.ok", "OK"))
    alert.runModal()
}

#if DEBUG
private struct GallerySmokeFailure: LocalizedError {
    var errorDescription: String? { message }
    let message: String
}

private func galleryCheck(_ condition: Bool, _ description: String) throws {
    guard condition else { throw GallerySmokeFailure(message: description) }
    print("PASS \(description)")
}

extension CommunityThemeGalleryWindow {
    func smoke(
        phase: String, fixture: URL, browser: BrowserViewController, toolbar: NSToolbar
    ) throws {
        configure()
        let v1URL = fixture.appendingPathComponent("v1.submission.json")
        let v2URL = fixture.appendingPathComponent("v2.submission.json")
        let v1 = try CommunityThemeGallery.submission(at: v1URL)
        let v2 = try CommunityThemeGallery.submission(at: v2URL)
        let reviews = try JSONDecoder().decode(
            [CommunityThemeGallery.Review].self,
            from: Data(contentsOf: fixture.appendingPathComponent("reviews.json")))
        guard reviews.count == 2 else { throw GallerySmokeFailure(message: "Fixture reviews") }
        let toolbarOrder = toolbar.itemIdentifiers
        func checkChrome(_ expected: ThemePreset) throws {
            try galleryCheck(
                toolbar.items.map(\.itemIdentifier) == toolbarOrder
                    && ThemeManager.shared.windowTint
                        == ThemeManager.color(fromHex: expected.backgroundHex)
                    && IconSetManager.shared.folderStyle == .plum
                    && IconSetManager.shared.current.name == ThemeStyles.FileIcons.vivid.rawValue
                    && browser.toolbarGlyphStyle == .squared,
                "Appearance, toolbar order, and all three style overrides")
        }
        func approve(_ revision: CommunityThemeRevision, decision: CommunityThemeGallery.Review)
            throws
        {
            try recordReview(
                revision.reference, outcome: decision.outcome, reviewer: decision.reviewer,
                note: decision.note)
        }
        func browse(_ query: String = "") {
            scope.selectedSegment = 0
            search.stringValue = query
            refresh()
        }
        func hasAction(_ title: String) -> Bool {
            actionButtons.contains { $0.title == title }
        }

        switch phase {
        case "desktop":
            try submitRevision(at: v1URL)
            try approve(v1, decision: reviews[0])
            browse()
            NSApp.activate(ignoringOtherApps: true)
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            defer { panel.orderOut(nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            try galleryCheck(
                panel.isVisible && panel.makeFirstResponder(search),
                "Native gallery is visible and accepts search focus")
            func click(_ title: String) throws {
                guard
                    let control = actionButtons.first(where: { $0.title == title }),
                    control.isEnabled
                else { throw GallerySmokeFailure(message: "Missing action \(title)") }
                control.performClick(nil)
            }
            search.stringValue = "marsh"
            controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: search))
            try galleryCheck(
                selection == v1 && screenshot.image != nil, "Native search and screenshot")
            try click("Install")
            try galleryCheck(
                gallery.installed[v1.id] == v1 && active == nil,
                "Install button saves without applying")
            try click("Apply Installed")
            try galleryCheck(active == v1.reference, "Apply button applies the installed revision")
        case "submit", "stage":
            try galleryCheck(rows.isEmpty, "Fresh gallery")
            try submitRevision(at: v1URL)
            try galleryCheck(
                status.stringValue.contains("Pending review"), "Submission awaits review")
            try galleryCheck(gallery.discover().isEmpty, "Pending submission is absent from Browse")
            try approve(v1, decision: reviews[0])
            browse("marsh contributors MINT")
            try galleryCheck(
                selection == v1 && hasAction("Install") && !hasAction("Apply Installed")
                    && details.stringValue.contains(v1.creator)
                    && details.stringValue.contains(v1.license)
                    && details.stringValue.contains(v1.source ?? ""),
                "Search, details, and explicit install action")
            try galleryCheck(screenshot.image != nil, "First screenshot displays")
            screenshots.selectItem(at: 1)
            showScreenshot()
            try galleryCheck(screenshot.image != nil, "Second screenshot displays")
            if let content = panel.contentView {
                content.layoutSubtreeIfNeeded()
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(
                        to: url.deletingLastPathComponent().appendingPathComponent(
                            "gallery-detail.png"))
                }
            }
            browse("no such theme")
            try galleryCheck(rows.isEmpty, "Nonmatching search")
            browse()
            if phase == "stage" { return }
            var previewed = false
            let candidate = try v1.theme()
            try withPreview(v1) {
                previewed =
                    browser.prefs.communityTheme == nil
                    && ThemeManager.shared.windowTint
                        == ThemeManager.color(fromHex: candidate.backgroundHex)
                    && toolbar.items.map(\.itemIdentifier) == toolbarOrder
            }
            try galleryCheck(
                previewed && gallery.installed.isEmpty, "Preview does not install or apply")
            try checkChrome(.system)
            try install(v1.reference)
            try galleryCheck(
                browser.prefs.communityTheme == nil && gallery.installed[v1.id] == v1
                    && hasAction("Apply Installed"), "Install leaves current appearance intact")
            try applyInstalled(v1.id)
            try galleryCheck(browser.prefs.communityTheme == v1.reference, "Apply v1")
            try checkChrome(candidate)

        case "update":
            try galleryCheck(
                browser.prefs.communityTheme == v1.reference && gallery.installed[v1.id] == v1,
                "v1 installation and applied appearance survived process restart")
            try checkChrome(v1.theme())
            try submitRevision(at: v2URL)
            browse()
            try galleryCheck(
                selection == v1 && !hasAction("Update"), "Pending update leaves v1 discoverable")
            try approve(v2, decision: reviews[1])
            browse()
            try galleryCheck(
                selection == v2 && hasAction("Update") && gallery.installed[v1.id] == v1,
                "Approved update is offered and v1 remains installed")
            try install(v2.reference)
            try galleryCheck(
                gallery.installed[v2.id] == v2 && browser.prefs.communityTheme == v1.reference,
                "Explicit update installs v2 while v1 stays applied")
            try checkChrome(v1.theme())
            try applyInstalled(v2.id)
            try galleryCheck(
                browser.prefs.communityTheme == v2.reference, "Explicit apply switches to v2")
            try checkChrome(v2.theme())
            try withdraw(v2.id)
            try galleryCheck(
                rows.isEmpty && gallery.installed[v2.id] == v2, "Withdrawal retains installed v2")
            scope.selectedSegment = 1
            refresh()
            try galleryCheck(
                selection == v2 && hasAction("Uninstall…"), "Withdrawn copy remains manageable")
            try uninstall(v2.id)
            try galleryCheck(
                browser.prefs.communityTheme == nil && gallery.installed.isEmpty
                    && ThemePreset(preferences: browser.prefs) == .system,
                "Uninstall active theme restores System")
            try checkChrome(.system)

        case "relaunch":
            try galleryCheck(
                active == nil && rows.isEmpty && gallery.installed.isEmpty
                    && gallery.withdrawn.contains(v2.id),
                "Uninstall and withdrawal survived a second process restart")
            try checkChrome(.system)
        default:
            throw GallerySmokeFailure(message: "Unknown fixture phase")
        }
    }
}

extension CommunityThemeGalleryWindow {
    /// Draws the window's content offscreen. `state` is `key=value` pairs joined by `;`:
    /// `appearance` (light or dark), `scope` (segment index), `search`, and `select` (theme id).
    func renderShot(to output: URL, state: String) async throws {
        var options: [String: String] = [:]
        for pair in state.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { options[parts[0]] = parts[1] }
        }
        let appearance = NSAppearance(named: options["appearance"] == "dark" ? .darkAqua : .aqua)
        panel.appearance = appearance
        configure()
        guard let content = panel.contentView else {
            throw GallerySmokeFailure(message: "Missing content view")
        }
        content.layoutSubtreeIfNeeded()
        try applyShotState(options)
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw GallerySmokeFailure(message: "No bitmap") }
        // The content view does not draw the window background, so paint it first.
        appearance?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: bitmap.size).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        // Evidence for the lazy thumbnails: how many were decoded, of how many cards, and how
        // large the largest one is.
        print(
            "community-gallery-shot: cards=\(rows.count) selected=\(selection?.id ?? "none") "
                + "selectedVisible=\(selectedCardFrame.map(grid.visibleRect.contains) ?? false) "
                + "thumbnails=\(thumbnails.decoded) largestSide=\(thumbnails.largestSide)")
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw GallerySmokeFailure(message: "No PNG")
        }
        try png.write(to: output)
    }

    private func applyShotState(_ options: [String: String]) throws {
        for id in (options["install"] ?? "").split(separator: ",") {
            guard let revision = gallery.discover().first(where: { $0.id == id }) else {
                throw GallerySmokeFailure(message: "No theme \(id)")
            }
            try mutate { try $0.install(revision.reference) }
        }
        if let segment = options["scope"].flatMap(Int.init), segment < scope.segmentCount {
            scope.selectedSegment = segment
        }
        filter.selectedSegment = ["light": 1, "dark": 2][options["filter"] ?? ""] ?? 0
        search.stringValue = options["search"] ?? ""
        refresh()
        if let id = options["select"] {
            guard let revision = rows.first(where: { $0.id == id }) else {
                throw GallerySmokeFailure(message: "No theme \(id)")
            }
            refresh(preferred: revision.reference)
        }
    }
}

extension BrowserViewController {
    func smokeCommunityGallery(phase: String, fixture: URL, store: URL) throws {
        guard let toolbar = view.window?.toolbar, toolbar.itemIdentifiers.count > 1 else {
            throw GallerySmokeFailure(message: "Missing toolbar")
        }
        toolbar.autosavesConfiguration = false
        var order = toolbar.itemIdentifiers
        order.swapAt(0, 1)
        toolbar.itemIdentifiers = order
        try galleryCheck(toolbar.itemIdentifiers == order, "Customized toolbar order set")
        if phase == "submit" {
            var updated = prefs
            ThemePreset.system.apply(to: &updated)
            updated.folderStyleOverride = .plum
            updated.iconSetName = ThemeStyles.FileIcons.vivid.rawValue
            updated.toolbarStyleOverride = .squared
            receiveSettingsPreferences(updated)
        }
        showPreferences()
        settings.debugShowAppearancePane()
        try settings.makeCommunityGallery(at: store).smoke(
            phase: phase, fixture: fixture, browser: self, toolbar: toolbar)
    }
}
#endif
