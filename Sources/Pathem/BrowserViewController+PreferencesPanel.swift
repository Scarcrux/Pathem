import AppKit
import PathemEngine
import PathemTerminal

// The embedded Settings panel (Cmd-,): show/close and its header-wrapping chrome, plus every
// toggle/apply* method that pushes a Preferences change out to both panes, the theme, the icon
// set, and the terminal. Split out of BrowserViewController to keep that file focused.
@MainActor
extension BrowserViewController {
    func loadPreferences() {
        if let saved = loadConfig(Preferences.self, from: Self.preferencesURL) { prefs = saved }
    }

    func showPreferences() {
        if settingsPanel != nil {  // Cmd-, toggles the embedded panel
            closeSettingsPanel()
            return
        }
        // Host Settings over the right pane; reveal it if it's collapsed.
        if rightTabs.containerView.frame.width < 120 {
            setRightPaneFraction(0.5)
            view.layoutSubtreeIfNeeded()
        }
        let content = settings.makeEmbedded(
            prefs: prefs,
            commands: commands.all.map { (id: $0.id, title: $0.title) },
            effective: keymap.bindings,
            gestures: gestureMap.bindings,
            updater: updater,
            terminal: .init(
                themes: TerminalTheme.presets.map(\.name),
                current: terminal.theme.name,
                follows: terminalFollows,
                onSelectTheme: { [weak self] name in
                    guard let self, let preset = TerminalTheme.presets.first(where: { $0.name == name })
                    else { return }
                    self.terminal.theme = preset
                    self.saveConfig(preset, to: Self.terminalThemeURL)
                },
                onToggleFollows: { [weak self] on in
                    guard let self else { return }
                    self.terminalFollows = on
                    UserDefaults.standard.set(on, forKey: "pathem.terminalFollows")
                    if on, !self.terminal.view.isHidden, let url = self.activePane?.currentURL {
                        self.terminal.changeDirectory(to: url)
                    }
                }),
            onChange: { [weak self] updated in
                guard let self else { return }
                self.prefs = updated
                self.applyPreferences()
            },
            onKeymapChange: { [weak self] overlay in
                guard let self else { return }
                self.saveConfig(overlay, to: Self.keymapURL)  // persist the user overlay
                self.keymap = Keymap.standard.merging(userBindings: overlay)  // apply live
            },
            onGestureChange: { [weak self] overlay in
                guard let self else { return }
                self.saveConfig(overlay, to: Self.gesturesURL)
                self.gestureMap = GestureMap.standard.merging(userBindings: overlay)  // apply live
            })
        let panel = makeSettingsPanel(content: content)
        rightTabs.containerView.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: rightTabs.containerView.topAnchor),
            panel.bottomAnchor.constraint(equalTo: rightTabs.containerView.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: rightTabs.containerView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: rightTabs.containerView.trailingAnchor),
        ])
        settingsPanel = panel
    }

    /// Wrap the embedded settings content in an opaque panel with a header (title + Done),
    /// since it no longer has a window title bar.
    func makeSettingsPanel(content: NSView) -> NSView {
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: L("settings.title", "Settings"))
        title.font = .boldSystemFont(ofSize: 13)
        title.translatesAutoresizingMaskIntoConstraints = false
        let done = NSButton(
            title: L("common.done", "Done"), target: self, action: #selector(closeSettingsPanel))
        done.bezelStyle = .rounded
        done.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(title)
        panel.addSubview(done)
        panel.addSubview(divider)
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            done.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            done.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            divider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            content.topAnchor.constraint(equalTo: divider.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return panel
    }

    @objc func closeSettingsPanel() {
        settingsPanel?.removeFromSuperview()
        settingsPanel = nil
    }

    func toggleOCR() {
        prefs.searchOCR.toggle()
        applyPreferences()
    }

    func toggleFullPathTitle() {
        prefs.showFullPathInTitle.toggle()
        saveConfig(prefs, to: Self.preferencesURL)
        updateWindowTitle()
    }

    func toggleConnectionsNewTab() {
        prefs.openConnectionsInNewTab.toggle()
        saveConfig(prefs, to: Self.preferencesURL)
    }

    func toggleCompactSidebar() {
        prefs.compactSidebar.toggle()
        applyPreferences()  // applies labels + width and persists
    }

    /// Hide/show sidebar labels and narrow/restore the sidebar per the preference.
    /// Force the app's appearance (System/Light/Dark) per the preference.
    func applyAppearance() {
        switch prefs.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Push the skin's colors into the theme manager (which notifies the themed chrome) and tint
    /// the window/pane background. The accent is honored by Pathem-drawn elements via ThemeManager.
    func applyTheme() {
        ThemeManager.shared.apply(accentHex: prefs.accentColorHex, windowTintHex: prefs.windowTintHex)
        let tint = ThemeManager.shared.windowTint
        view.window?.backgroundColor = tint ?? .windowBackgroundColor
    }

    /// Adopt the selected icon set; reload every listing so the new icons appear.
    func applyIconSet() {
        guard IconSetManager.shared.setCurrent(named: prefs.iconSetName) else { return }
        for side in [leftTabs, rightTabs] { for pane in side.tabs { pane.reloadIfShowingListing() } }
    }

    func applyCompactSidebar() {
        compactSidebar = prefs.compactSidebar
        sidebar.setShowsLabels(!compactSidebar)
        sidebar.setMonochromeIcons(prefs.monochromeSidebarIcons)
        let width: CGFloat = compactSidebar ? Self.compactSidebarWidth : 200
        sidebarWidthConstraint?.constant = width
        if didSetInitialSplit { outerSplit.setPosition(width, ofDividerAt: 0) }  // resize live
        // In icons-only mode the labels are hidden, so tooltips are how you identify an icon --
        // make them instant. Otherwise honor the preference.
        if compactSidebar {
            UserDefaults.standard.set(1, forKey: "NSInitialToolTipDelay")
        } else {
            applyTooltipDelay()
        }
    }

    func togglePathBarPosition() {
        prefs.pathBarAtBottom.toggle()
        applyPreferences()  // moves the path bar in every pane and persists
    }

    func toggleCalculateSizes() {
        prefs.calculateFolderSizes.toggle()
        applyPreferences()  // turns folder-size computation on/off in every pane
    }

    /// Apply preferences to every tab in both sides, persist them, and rebuild the
    /// search index (OCR can change what gets embedded).
    /// Persist a new icon/gallery zoom and keep both panes' base zoom in sync.
    func rememberIconZoom(_ scale: CGFloat) {
        prefs.iconZoom = Double(scale)
        saveConfig(prefs, to: Self.preferencesURL)
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs { pane.iconZoom = scale }
        }
    }

    func applyPreferences() {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs {
                pane.applyStyle(
                    rowHeight: prefs.rowHeight, fontSize: prefs.fontSize,
                    alternatingRows: prefs.alternatingRows)
                pane.setPathBar(atBottom: prefs.pathBarAtBottom)
                pane.setCalculateFolderSizes(prefs.calculateFolderSizes)
                pane.dragMovesByDefault = prefs.dragMovesByDefault
                pane.setClickBehavior(
                    singleClick: prefs.singleClickToOpen, underlineHover: prefs.underlineOnHover)
                let wasHidden = pane.showHiddenByDefault
                pane.showHiddenByDefault = prefs.showHiddenByDefault
                if wasHidden != prefs.showHiddenByDefault { pane.reloadIfShowingListing() }
                pane.iconZoom = CGFloat(prefs.iconZoom)
                pane.iconPointSize = CGFloat(prefs.toolbarIconSize.pointSize)
                pane.setHiddenContextItems(Set(prefs.hiddenContextItems))
                pane.setContextMenuOrder(prefs.contextMenuOrder)
                pane.setColorRules(prefs.colorRules)
                pane.setFormats(size: prefs.sizeFormat, date: prefs.dateDisplay)
                pane.setMiddleClickOpensNewTab(prefs.middleClickOpensNewTab)
                pane.statusOptions = (
                    prefs.statusShowItemCount, prefs.statusShowSize, prefs.statusShowFreeSpace)
            }
        }
        for side in [leftTabs, rightTabs] { side.newTabAtEnd = prefs.newTabAtEnd }
        applyCompactSidebar()
        applyCommanderCommands()
        applyAppearance()
        applyTheme()
        applyIconSet()
        applyTooltipDelay()
        applyToolbarIconSize()
        RemoteLimits.bandwidthKBps = prefs.bandwidthLimitKBps  // honored by the transfer backends
        saveConfig(prefs, to: Self.preferencesURL)
        semanticSearch.includeOCR = prefs.searchOCR
        semanticSearch.invalidate()  // a pref (e.g. OCR) may change how folders index
        if let directory = activePane?.currentURL { preIndex(directory) }
    }

    /// AppKit shows a tooltip after `NSInitialToolTipDelay` milliseconds (a long system
    /// default). Register a near-zero delay for instant tooltips, or clear our override to
    /// restore the default. A live toggle applies to tooltips shown after this point;
    /// AppKit may cache the value, so a relaunch guarantees it.
    func applyTooltipDelay() {
        let key = "NSInitialToolTipDelay"
        if prefs.instantTooltips {
            UserDefaults.standard.set(1, forKey: key)  // 1 ms, effectively instant
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
