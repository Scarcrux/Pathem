import AppKit
import PathemEngine

// The floating quick-actions bar (and its Quick Open With / Quick Paste follow-up
// menus), plus the auto-preview-pane sync that rides along with view-mode switches,
// split out of BrowserViewController.
@MainActor
extension BrowserViewController {

    /// Show/hide the QuickLook preview pane docked at the right of the window.
    func togglePreviewPane() {
        previewVisible.toggle()
        if previewVisible {
            // Auto-layout, like the sidebar and panes -- a TAMIC arranged subview in an
            // auto-layout NSSplitView breaks the split's width distribution and collapses
            // the panes to zero (blanking both panes).
            previewView.translatesAutoresizingMaskIntoConstraints = false
            outerSplit.addArrangedSubview(previewView)  // [sidebar | panes | preview]
            outerSplit.setHoldingPriority(NSLayoutConstraint.Priority(255), forSubviewAt: 2)
            // Durably pin the preview to a sane width so the panes always keep the rest. A
            // bare setPosition() is transient in an auto-layout split and lets the preview
            // (and the panes with it) collapse to zero; this constraint stays put and is
            // still draggable (its priority is below the divider-drag priority).
            let width = previewWidthConstraint ?? previewView.widthAnchor.constraint(equalToConstant: 300)
            width.priority = NSLayoutConstraint.Priority(255)
            width.isActive = true
            previewWidthConstraint = width
            // Seed the divider once so the split gives the preview its width now; the
            // constraint then holds it durably across resizes and view swaps.
            outerSplit.layoutSubtreeIfNeeded()
            outerSplit.setPosition(
                outerSplit.bounds.width - 300, ofDividerAt: outerSplit.arrangedSubviews.count - 2)
            updatePreview()
        } else {
            previewView.show(nil)
            previewWidthConstraint?.isActive = false
            outerSplit.removeArrangedSubview(previewView)
            previewView.removeFromSuperview()
            // Hand the freed width back to the panes now: pin the sidebar|panes divider at the
            // sidebar width so the panes fill the rest (removeArrangedSubview leaves a stale
            // divider position otherwise, stranding the freed strip as dead space).
            outerSplit.layoutSubtreeIfNeeded()
            outerSplit.setPosition(sidebarWidthConstraint?.constant ?? 200, ofDividerAt: 0)
            outerSplit.layoutSubtreeIfNeeded()
        }
    }

    /// Point the preview at the active pane's single selected file (when visible).
    func updatePreview() {
        guard previewVisible else { return }
        previewView.show(activePane?.singleSelectedURL)
    }

    /// Show/hide the floating quick-actions bar for the active pane's selection, and place
    /// it next to the selected rows.
    func updateQuickActions() {
        let count = activePane?.selectedEntries.count ?? 0
        let viewable =
            count == 1
            && ((activePane?.singleSelectedURL).map { DocumentPreviewView.isViewable($0) } ?? false)
        quickBar.update(selectionCount: count, isViewable: viewable)
        observeActivePaneScroll()
        positionQuickBar()
    }

    /// Release the window's long-lived resources when it closes: stop every pane's
    /// DirectoryWatcher (each self-retains via its FSEvents stream, so without this a closed
    /// window leaks), invalidate the repeating device-poll timer, hide the torrent detail
    /// timer, and drop the scroll observer.
    func teardown() {
        for side in [leftTabs, rightTabs] { side.teardownAllTabs() }
        downloadSuggestions.stop()  // its Downloads watcher self-retains; stop it or the window leaks
        _automation?.stopWatching()  // likewise the per-rule folder watchers (only if it was created)
        deviceWatcher.stop()
        torrentDetail.hide()
        if let token = quickBarScrollObserver { NotificationCenter.default.removeObserver(token) }
        quickBarScrollObserver = nil
        quickBarObservedClip = nil
    }

    /// Reposition the bar while the active pane scrolls, so it stays next to the selection.
    private func observeActivePaneScroll() {
        guard let clip = activePane?.contentClipView else { return }
        if quickBarObservedClip === clip { return }
        if let token = quickBarScrollObserver { NotificationCenter.default.removeObserver(token) }
        clip.postsBoundsChangedNotifications = true
        quickBarScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionQuickBar() }
        }
        quickBarObservedClip = clip
    }

    /// Float the bar next to the selection (all rects in host coordinates), clamped inside
    /// the pane; falls back to the pane's top-center when the selection is scrolled out.
    private func positionQuickBar() {
        guard !quickBar.isHidden else { return }
        let host = view
        quickBar.layoutSubtreeIfNeeded()
        let size = quickBar.fittingSize
        let pane =
            activePane.map { host.convert($0.contentClipView.bounds, from: $0.contentClipView) }
            ?? host.convert(split.bounds, from: split)
        // Column view drills into columns to the right, so a bar floating next to the
        // selection covers the very columns you're browsing. Pin it to the pane's
        // bottom-center there (out of the browsing area) instead of tracking the selection.
        let selection =
            activePane?.viewMode == .column
            ? nil : activePane?.selectionRectInWindow.map { host.convert($0, from: nil) }
        let origin = Self.quickBarOrigin(
            barSize: size, selection: selection, pane: pane, margin: 8,
            noSelectionAtBottom: activePane?.viewMode == .column)
        quickBar.frame = NSRect(origin: origin, size: size)
    }

    /// Pure geometry (so it is testable without a laid-out window): the bar sits just below
    /// the selection, or above it when there is no room, centered on the selection and
    /// clamped inside the pane. In a non-flipped host, lower on screen is a smaller y.
    static func quickBarOrigin(
        barSize size: NSSize, selection: NSRect?, pane: NSRect, margin: CGFloat,
        noSelectionAtBottom: Bool = false
    ) -> NSPoint {
        var x: CGFloat
        var y: CGFloat
        if let r = selection {
            x = r.midX - size.width / 2
            y = r.minY - margin - size.height  // just below the selection
            if y < pane.minY + margin { y = r.maxY + margin }  // no room below, place above
        } else {
            x = pane.midX - size.width / 2
            // Bottom-center (column view, to clear the drilled columns) or top-center.
            y = noSelectionAtBottom ? (pane.minY + margin) : (pane.maxY - size.height - 16)
        }
        x = min(max(x, pane.minX + margin), pane.maxX - size.width - margin)
        y = min(max(y, pane.minY + margin), pane.maxY - size.height - margin)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    /// Pop up an "Open With" apps menu for the active selection, anchored to the quick-bar button.
    func showQuickOpenWith(from anchor: NSView) {
        guard let urls = activePane?.selectedLocalURLs(), let first = urls.first else { NSSound.beep(); return }
        let menu = NSMenu()
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: first), let index = apps.firstIndex(of: preferred) {
            apps.remove(at: index)
            apps.insert(preferred, at: 0)  // default app first
        }
        if apps.isEmpty {
            let none = NSMenuItem(title: L("list.noApplications", "No applications"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for app in apps {
                let item = NSMenuItem(
                    title: FileManager.default.displayName(atPath: app.path),
                    action: #selector(quickOpenSelection(with:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app
                let icon = (NSWorkspace.shared.icon(forFile: app.path).copy() as? NSImage) ?? NSImage()
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let other = NSMenuItem(title: L("list.other", "Other…"), action: #selector(quickOpenSelectionWithOther), keyEquivalent: "")
            other.target = self
            menu.addItem(other)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func quickOpenSelection(with sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL,
            let urls = activePane?.selectedLocalURLs(), !urls.isEmpty
        else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quickOpenSelectionWithOther() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let app = panel.url,
            let urls = activePane?.selectedLocalURLs(), !urls.isEmpty
        else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Right after a quick-bar Copy/Cut, offer where to drop it: this pane's folder or the
    /// other pane's. Only shown if the clipboard actually holds files, and the other-pane item
    /// only when a valid other pane exists (so a single-pane layout just shows "Paste Here").
    func showQuickPasteFollowUp(from anchor: NSView) {
        let pasteboard = NSPasteboard.general
        let items =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        guard !items.isEmpty else { return }  // copy beeped (remote / nothing selected)
        let menu = NSMenu()
        let here = NSMenuItem(
            title: L("quick.pasteHere", "Paste in This Pane"), action: #selector(quickPasteHere), keyEquivalent: "")
        here.target = self
        here.image = MenuIcons.image("doc.on.clipboard")
        menu.addItem(here)
        if let other = otherPane, !other.isRemote, !other.isShowingSmartResults {
            let there = NSMenuItem(
                title: String(
                    format: L("quick.pasteOther", "Paste in Other Pane (%@)"),
                    other.currentURL.lastPathComponent),
                action: #selector(quickPasteOtherPane), keyEquivalent: "")
            there.target = self
            there.image = MenuIcons.image("rectangle.righthalf.inset.filled")
            menu.addItem(there)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func quickPasteHere() { paste(nil) }
    @objc private func quickPasteOtherPane() { pasteInto(otherPane) }

    /// Set the active pane's view mode, then sync the auto-preview pane.
    func setActiveViewMode(_ mode: ViewFormat.ViewMode) {
        activePane?.setViewMode(mode)
        syncAutoPreview()
    }

    /// With the "preview in gallery" preference on, auto-open the preview pane while the
    /// active pane is in gallery view (and close it again when leaving). Column view used
    /// to auto-open it too, but it draws its own preview column now, so the auto pane just
    /// duplicated the selected file right beside it.
    func syncAutoPreview() {
        guard prefs.previewInGalleryView else { return }
        let mode = activePane?.viewMode
        let wantsPreview = (mode == .gallery)
        if wantsPreview, !previewVisible {
            togglePreviewPane()
            previewAutoShown = true
        } else if !wantsPreview, previewVisible, previewAutoShown {
            togglePreviewPane()
            previewAutoShown = false
        }
        updatePreview()
    }
}
