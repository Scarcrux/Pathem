import AppKit
import PathemEngine
import UniformTypeIdentifiers

private final class GalleryDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Browse the shared Themes catalog in a beta package or use an isolated debug gallery.
@MainActor
final class CommunityThemeGalleryWindow: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    static var betaEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "PathemThemesBeta") as? Bool == true
    }

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
        return betaEnabled ? ConfigStore.url("shared-community-themes.json") : nil
    }

    static var sharedEndpoint: String? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PATHEM_COMMUNITY_GALLERY"] == "1" {
            return ProcessInfo.processInfo.environment["PATHEM_SHARED_THEME_CATALOG"]
        }
        #endif
        return betaEnabled ? "https://d3v2l0mmdgkblv.cloudfront.net/catalog.json" : nil
    }

    static func refreshSharedCatalog(_ endpoint: String, at store: URL) async throws {
        let catalog = try await SharedThemeCatalog.fetch(endpoint)
        _ = try CommunityThemeGallery.update(at: store) { $0.synchronize(catalog) }
    }

    // The release smoke mounts the production gallery without activating the app.
    static func verifyPackagedInstallation(endpoint: String) async throws {
        guard betaEnabled, let url = storeURL, let fixture = URL(string: endpoint),
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
                let button = window.actions.arrangedSubviews.compactMap({ $0 as? NSButton })
                    .first(where: { $0.action == action }),
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
        contentRect: NSRect(x: 0, y: 0, width: 680, height: 625),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let scope = NSSegmentedControl(
        labels: CommunityThemeGalleryWindow.sharedEndpoint == nil
            ? [
                L("themes.browse", "Browse"), L("integrations.installed", "Installed"),
                L("themes.review", "Review"),
            ] : [L("themes.browse", "Browse"), L("integrations.installed", "Installed")],
        trackingMode: .selectOne,
        target: nil, action: nil)
    private let search = NSSearchField()
    private let listings = NSPopUpButton()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let screenshot = NSImageView()
    private let screenshots = NSPopUpButton()
    private let actions = NSStackView()
    private var rows: [CommunityThemeRevision] = []
    private var selection: CommunityThemeRevision? {
        let index = listings.indexOfSelectedItem
        return rows.indices.contains(index) ? rows[index] : nil
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
        scope.selectedSegment = 0
        scope.target = self
        scope.action = #selector(scopeChanged)
        search.placeholderString = L("themes.search", "Search titles, creators, and tags")
        search.delegate = self
        listings.target = self
        listings.action = #selector(refreshDetail)
        screenshots.target = self
        screenshots.action = #selector(showScreenshot)
        screenshot.imageScaling = .scaleProportionallyUpOrDown
        screenshot.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        screenshot.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        screenshot.setAccessibilityLabel(L("themes.screenshot", "Theme screenshot"))
        title.font = .boldSystemFont(ofSize: 17)
        status.textColor = .secondaryLabelColor
        actions.spacing = 8
        let submit = button(L("themes.submit", "Submit Revision…"), #selector(chooseSubmission))
        let done = button(L("common.done", "Done"), #selector(close))
        done.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: Self.sharedEndpoint == nil ? [submit, done] : [done])
        footer.spacing = 8
        let stack = NSStackView(views: [
            scope, search, listings, title, details, status, screenshots, screenshot, actions,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = panel.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = GalleryDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(stack)
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listings.widthAnchor.constraint(equalTo: stack.widthAnchor),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            screenshot.widthAnchor.constraint(equalTo: stack.widthAnchor),
            screenshot.heightAnchor.constraint(equalToConstant: 250),
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

    private func refresh(preferred: CommunityThemeRevision.Reference? = nil) {
        let previous = preferred ?? selection?.reference
        search.isHidden = scope.selectedSegment != 0
        switch scope.selectedSegment {
        case 1: rows = gallery.installed.values.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        case 2: rows = gallery.entries.reversed().map(\.revision)
        default: rows = gallery.discover(search.stringValue)
        }
        listings.removeAllItems()
        for row in rows {
            listings.addItem(
                withTitle: "\(row.title) · \(row.creator) · \(row.id) · v\(row.version)")
        }
        if !rows.isEmpty {
            listings.selectItem(at: rows.firstIndex { $0.reference == previous } ?? 0)
        }
        listings.isHidden = rows.isEmpty
        refreshDetail()
    }

    @objc private func refreshDetail() {
        for view in actions.arrangedSubviews { actions.removeView(view) }
        screenshots.removeAllItems()
        screenshot.image = nil
        screenshot.isHidden = selection == nil
        screenshots.isHidden = selection == nil
        guard let revision = selection else {
            title.stringValue =
                [
                    L("themes.emptyBrowse", "No matching themes"),
                    L("themes.emptyInstalled", "No installed themes"),
                    L("themes.emptyReview", "No submissions"),
                ][
                    scope.selectedSegment]
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
        actions.addArrangedSubview(
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
                    actions.addArrangedSubview(
                        button(
                            L("themes.approve", L("themes.approve", "Approve")) + "…",
                            #selector(approve)))
                    actions.addArrangedSubview(
                        button(
                            L("themes.reject", L("themes.reject", "Reject")) + "…",
                            #selector(reject)))
                }
            }
            if !withdrawn {
                actions.addArrangedSubview(
                    button(
                        L("themes.withdraw", L("themes.withdraw", "Withdraw")) + "…",
                        #selector(confirmWithdrawal)))
            }
        case 1:
            actions.addArrangedSubview(
                button(L("common.apply", "Apply"), #selector(applySelection)))
            actions.addArrangedSubview(
                button(
                    L("themes.uninstall", L("themes.uninstall", "Uninstall")) + "…",
                    #selector(confirmUninstall)))
        default:
            if let installed, installed.version < revision.version {
                actions.addArrangedSubview(
                    button(L("themes.update", "Update"), #selector(installSelection)))
            } else if installed == nil {
                actions.addArrangedSubview(
                    button(L("integrations.cliInstall", "Install"), #selector(installSelection)))
            }
            if installed != nil {
                actions.addArrangedSubview(
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
            actions.arrangedSubviews.contains { ($0 as? NSButton)?.title == title }
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
                    let control = actions.arrangedSubviews.compactMap({ $0 as? NSButton })
                        .first(where: { $0.title == title }), control.isEnabled
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
