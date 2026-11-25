import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// The app's Settings window: a System-Settings-style window whose toolbar switches
/// between panes. Exposes every Preferences field, a full keyboard-shortcut editor
/// (built on the engine Keymap + the command registry), and update options. Prefs
/// changes are reported live via `onChange`; shortcut changes via `onKeymapChange`
/// (a user overlay for keymap.json).
@MainActor
final class SettingsWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Pane: String, CaseIterable {
        case general, appearance, layout, menus, labels, search, terminal, transfers, shortcuts,
            gestures, integrations, updates
        var title: String {
            switch self {
            case .general: return L("settings.general", "General")
            case .appearance: return L("settings.appearance", "Appearance")
            case .layout: return L("settings.layout", "Layout")
            case .menus: return L("settings.menus", "Menus")
            case .labels: return L("settings.labels", "Labels")
            case .search: return L("settings.search", "Search")
            case .terminal: return L("settings.terminal", "Terminal")
            case .transfers: return L("settings.transfers", "Transfers")
            case .shortcuts: return L("settings.shortcuts", "Shortcuts")
            case .gestures: return L("settings.gestures", "Gestures")
            case .integrations: return L("settings.integrations", "Integrations")
            case .updates: return L("settings.updates", "Updates")
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .layout: return "sidebar.squares.left"
            case .menus: return "contextualmenu.and.cursorarrow"
            case .labels: return "tag"
            case .search: return "magnifyingglass"
            case .terminal: return "terminal"
            case .transfers: return "arrow.up.arrow.down"
            case .shortcuts: return "keyboard"
            case .gestures: return "hand.draw"
            case .integrations: return "app.connected.to.app.below.fill"
            case .updates: return "arrow.down.circle"
            }
        }
        var itemID: NSToolbarItem.Identifier { .init("settings.\(rawValue)") }
    }

    private let window: NSWindow
    /// The settings content (sidebar + panes), embeddable in a pane instead of the window.
    let rootView = NSView()
    private var prefs = Preferences.default
    private var onChange: ((Preferences) -> Void)?
    var onThemePreview: ((ThemePreset?) -> Void)?
    var onImportedTerminalPalette: ((ExternalThemeImport.TerminalPalette) -> Void)?
    var onTrashRetentionChange: ((Bool) -> Void)?
    private var contextMenuEditor: ContextMenuEditorController?  // retains the Menus pane editor
    private var colorRulesEditor: ColorRulesEditorController?  // retains the Labels pane editor

    // Shortcut editor state.
    private var commandList: [(id: String, title: String)] = []
    private var effective: [String: String] = [:]  // chord canonical -> command id
    private var onKeymapChange: (([String: String]) -> Void)?
    private let table = NSTableView()
    private let recorder = KeyRecorderView()
    private let conflictLabel = NSTextField(labelWithString: "")

    // Gesture editor state (mirrors the shortcut editor).
    private var gestureEffective: [String: String] = [:]
    private var onGestureChange: (([String: String]) -> Void)?
    private let gestureTable = NSTableView()
    private let gestureRecorder = GestureRecorderView()
    private let gestureConflictLabel = NSTextField(labelWithString: "")
    private weak var updater: UpdaterController?
    private let updatesStatus = NSTextField(labelWithString: "")
    private let autoInstall = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // Terminal pane state (stored outside Preferences, so callbacks drive it).
    private var terminalThemes: [String] = []
    private var currentTerminalTheme = ""
    private var onSelectTerminalTheme: ((String) -> Void)?
    private var terminalFollows = false
    private var onToggleTerminalFollows: ((Bool) -> Void)?

    private var paneViews: [Pane: NSView] = [:]

    private let sidebar = SettingsSidebarController()
    private let contentContainer = NSView()
    private var chromeBuilt = false
    private var paneSearchText: [Pane: String] = [:]

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.title = L("settings.title", "Settings")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 360)
    }

    /// Build the persistent sidebar + content split once.
    private func buildChrome() {
        guard !chromeBuilt else { return }
        chromeBuilt = true
        sidebar.onSelect = { [weak self] key in
            if let pane = Pane(rawValue: key) { self?.select(pane) }
        }
        sidebar.searchText = { [weak self] item in
            self?.paneSearchText[Pane(rawValue: item.key) ?? .general] ?? ""
        }

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        // The sidebar gets the source-list backing material.
        let sidebarBacking = NSVisualEffectView()
        sidebarBacking.material = .sidebar
        sidebarBacking.blendingMode = .withinWindow
        sidebarBacking.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view.addSubview(sidebarBacking, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            sidebarBacking.topAnchor.constraint(equalTo: sidebar.view.topAnchor),
            sidebarBacking.bottomAnchor.constraint(equalTo: sidebar.view.bottomAnchor),
            sidebarBacking.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
            sidebarBacking.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
        ])

        // Explicit split: fixed-width sidebar on the left, content filling the rest.
        let root = rootView
        root.wantsLayer = true
        root.addSubview(sidebar.view)
        root.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            sidebar.view.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window.contentView = root
        sidebar.setItems(
            Pane.allCases.map { .init(key: $0.rawValue, title: $0.title, symbol: $0.symbol) })
    }

    /// Show the window, populated with current state.
    struct TerminalOptions {
        var themes: [String]
        var current: String
        var follows: Bool
        var onSelectTheme: (String) -> Void
        var onToggleFollows: (Bool) -> Void
    }

    /// Set the controller's state and build the UI (shared by the window and embedded paths).
    private func configure(
        prefs: Preferences, commands: [(id: String, title: String)], effective: [String: String],
        gestures: [String: String], updater: UpdaterController?, terminal: TerminalOptions,
        onChange: @escaping (Preferences) -> Void,
        onKeymapChange: @escaping ([String: String]) -> Void,
        onGestureChange: @escaping ([String: String]) -> Void
    ) {
        self.prefs = prefs
        self.commandList = commands
        self.effective = effective
        self.gestureEffective = gestures
        self.onGestureChange = onGestureChange
        self.updater = updater
        self.terminalThemes = terminal.themes
        self.currentTerminalTheme = terminal.current
        self.onSelectTerminalTheme = terminal.onSelectTheme
        self.terminalFollows = terminal.follows
        self.onToggleTerminalFollows = terminal.onToggleFollows
        self.onChange = onChange
        self.onKeymapChange = onKeymapChange
        buildChrome()
        buildAllPanesAndIndex()  // build every pane up front so search can index them
        sidebar.select(key: Pane.general.rawValue)
        select(.general)
    }

    func present(
        prefs: Preferences, commands: [(id: String, title: String)], effective: [String: String],
        gestures: [String: String], updater: UpdaterController?, terminal: TerminalOptions,
        over parent: NSWindow?,
        onChange: @escaping (Preferences) -> Void,
        onKeymapChange: @escaping ([String: String]) -> Void,
        onGestureChange: @escaping ([String: String]) -> Void
    ) {
        configure(
            prefs: prefs, commands: commands, effective: effective, gestures: gestures,
            updater: updater, terminal: terminal, onChange: onChange,
            onKeymapChange: onKeymapChange, onGestureChange: onGestureChange)
        window.contentView = rootView  // the window owns the content (not embedded)
        if !window.isVisible, let parent {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - 370, y: parent.frame.midY - 240))
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Build the settings UI for embedding directly in a pane (no separate window), so the
    /// user can keep browsing in the other pane. Returns the content view to host.
    func makeEmbedded(
        prefs: Preferences, commands: [(id: String, title: String)], effective: [String: String],
        gestures: [String: String], updater: UpdaterController?, terminal: TerminalOptions,
        onChange: @escaping (Preferences) -> Void,
        onKeymapChange: @escaping ([String: String]) -> Void,
        onGestureChange: @escaping ([String: String]) -> Void
    ) -> NSView {
        configure(
            prefs: prefs, commands: commands, effective: effective, gestures: gestures,
            updater: updater, terminal: terminal, onChange: onChange,
            onKeymapChange: onKeymapChange, onGestureChange: onGestureChange)
        rootView.removeFromSuperview()  // detach from the window if it was ever attached
        rootView.translatesAutoresizingMaskIntoConstraints = false
        return rootView
    }

    // MARK: Pane switching

    /// Build every pane once and index its settings' labels for the sidebar search.
    private func buildAllPanesAndIndex() {
        paneViews = [:]
        paneSearchText = [:]
        for pane in Pane.allCases {
            let view = build(pane)
            paneViews[pane] = view
            paneSearchText[pane] = (pane.title + " " + Self.searchableText(in: view)).lowercased()
        }
    }

    /// Collect button titles and text-field strings from a pane's view tree (for search).
    private static func searchableText(in view: NSView) -> String {
        var parts: [String] = []
        func walk(_ v: NSView) {
            if let button = v as? NSButton, !button.title.isEmpty { parts.append(button.title) }
            if let field = v as? NSTextField {
                if !field.stringValue.isEmpty { parts.append(field.stringValue) }
                if let placeholder = field.placeholderString, !placeholder.isEmpty {
                    parts.append(placeholder)
                }
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return parts.joined(separator: " ")
    }

    private func select(_ pane: Pane) {
        let view =
            paneViews[pane]
            ?? {
                let built = build(pane)
                paneViews[pane] = built
                return built
            }()
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func build(_ pane: Pane) -> NSView {
        switch pane {
        case .general:
            return form([
                check(
                    L("prefs.showHiddenByDefault", "Show hidden files in every folder"),
                    \.showHiddenByDefault),
                check(
                    L("prefs.openConnectionsNewTab", "Open connections in a new tab"),
                    \.openConnectionsInNewTab),
                check(
                    L("prefs.calculateFolderSizes", "Calculate folder sizes"),
                    \.calculateFolderSizes),
                check(
                    L(
                        "prefs.skipCacheFolderSizes",
                        "Skip caches, temporary and build folders when calculating sizes"),
                    \.skipCacheFolderSizes),
                labeled(
                    L("prefs.folderSizeExclusions", "Also skip"),
                    textField(\.folderSizeExclusions, width: 260)),
                hint(
                    L(
                        "prefs.folderSizeExclusionsHint",
                        "Folder names or paths, separated by commas, for example node_modules, ~/Movies/Raw. Skipped folders show a dash; right-click one and choose Calculate Size to measure it."
                    )),
                check(
                    L("prefs.confirmBeforeDelete", "Confirm before moving items to the Trash"),
                    \.confirmBeforeDelete),
                check(
                    L(
                        "prefs.autosaveMarkup",
                        "Save markup automatically when leaving a document (no prompt)"),
                    \.autosaveMarkup),
                check(
                    L("prefs.downloadSuggestions", "Offer filing suggestions for new downloads"),
                    \.downloadSuggestionsEnabled),
                labeled(
                    L("prefs.conflictDefault", "When files already exist"), conflictDefaultControl()
                ),
                check(
                    L("prefs.verifyCopies", "Verify copies with a checksum (slower)"),
                    \.verifyCopies),
                check(
                    L(
                        "prefs.dragMovesByDefault",
                        "Dragging items moves them (hold Command to copy)"), \.dragMovesByDefault),
                check(
                    L("prefs.useFinderGetInfo", "Use Finder’s Get Info window instead of Pathem’s"),
                    \.useFinderGetInfo),
                // (Removed "preview pane in Gallery/Column" toggle: both views draw their own inline
                //  preview now, so the separate pane only duplicated the selection over the other pane.)
                check(
                    L(
                        "prefs.dragFlickActions",
                        "Super-drag: right-drag an item to flick it (with a swipe trail)"),
                    \.dragFlickActions),
                labeled(L("prefs.dragTrailLabel", "Swipe trail"), dragTrailControl()),
                folderHandlerControl(),
                magnetHandlerControl(),
            ])
        case .appearance:
            return form([
                labeled(L("prefs.themeLabel", "Skin"), themeControl()),
                themePackageControls(),
                labeled(L("prefs.accentLabel", "Accent color"), accentColorControl()),
                labeled(L("prefs.windowTintLabel", "Window tint"), windowTintControl()),
                labeled(
                    L("prefs.folderStyleLabel", "Folder style"),
                    styleControl(
                        folderStylePopup, choices: ThemeStyles.Folder.allCases.map(\.rawValue))),
                labeled(
                    L("prefs.iconSetLabel", "File icons"),
                    styleControl(
                        fileIconPopup, choices: ThemeStyles.FileIcons.allCases.map(\.rawValue))),
                labeled(
                    L("prefs.toolbarStyleLabel", "Toolbar glyphs"),
                    styleControl(
                        toolbarStylePopup, choices: ThemeStyles.Toolbar.allCases.map(\.rawValue))),
                hint(
                    L(
                        "prefs.themeHint",
                        "The skin tints Pathem’s own selection, panes, tabs, and breadcrumb. Standard buttons still use the system accent."
                    )),
                labeled(L("prefs.appearanceLabel", "Appearance"), appearanceControl()),
                labeled(L("prefs.densityLabel", "Density"), densityControl()),
                labeled(L("prefs.fontSizeLabel", "Font size"), fontControl()),
                labeled(L("prefs.iconSizeLabel", "Toolbar icon size"), iconSizeControl()),
                check(L("prefs.alternatingRows", "Alternating row colors"), \.alternatingRows),
            ])
        case .layout:
            return form([
                check(
                    L("prefs.showFullPath", "Show full path in the title bar"),
                    \.showFullPathInTitle),
                check(
                    L("prefs.pathBarBottom", "Show the path bar at the bottom"), \.pathBarAtBottom),
                check(L("prefs.compactSidebar", "Compact sidebar (icons only)"), \.compactSidebar),
                check(
                    L("prefs.stackPanes", "Stack the two panes top and bottom"),
                    \.stackPanesVertically),
                check(
                    L("prefs.monochromeSidebar", "Monochrome sidebar icons (Liquid Glass)"),
                    \.monochromeSidebarIcons),
                check(
                    L("prefs.singleClickToOpen", "Open items with a single click"),
                    \.singleClickToOpen),
                check(
                    L("prefs.underlineOnHover", "Underline the item under the pointer"),
                    \.underlineOnHover),
                check(L("prefs.instantTooltips", "Show tooltips instantly"), \.instantTooltips),
                labeled(L("prefs.sizeFormatLabel", "File sizes"), sizeFormatControl()),
                labeled(L("prefs.dateFormatLabel", "Dates"), dateFormatControl()),
                check(
                    L("prefs.suggestFilenames", "Suggest filenames when renaming (on-device AI)"),
                    \.suggestFilenames),
                check(
                    L("prefs.warnExtension", "Warn before changing a filename extension"),
                    \.warnBeforeChangingExtension),
                check(
                    L(
                        "prefs.trash30days",
                        "Permanently remove items from Home Trash after 30 days"),
                    \.trashAfter30Days),
                hint(
                    L(
                        "prefs.trash30daysHint",
                        "Only while Pathem is running. External-volume Trash and items with unknown entry dates are left alone."
                    )),
                labeled(L("prefs.defaultViewLabel", "New folders open as"), defaultViewControl()),
                labeled(L("prefs.defaultSortLabel", "Default sort"), defaultSortControl()),
                labeled(L("prefs.recentsLabel", "Recents shows"), recentsBasisControl()),
                labeled(L("prefs.newTabLabel", "New tabs open to"), newTabLocationControl()),
                labeled(L("prefs.newTabPosLabel", "New tab position"), newTabPositionControl()),
                labeled(L("prefs.fixedFolderLabel", "Fixed folder"), fixedFolderControl()),
                labeled(
                    L("prefs.newFolderNameLabel", "New Folder name"),
                    textField(\.newFolderName, width: 180)),
                labeled(
                    L("prefs.newFileNameLabel", "New File name"),
                    textField(\.newFileName, width: 180)),
                check(
                    L("prefs.middleClickNewTab", "Middle-click opens folders in a new tab"),
                    \.middleClickOpensNewTab),
                labeled(L("prefs.commanderLabel", "Commander F-keys"), commanderEditButton()),
                hint(L("prefs.statusBarHint", "Status bar shows:")),
                check(L("prefs.statusItemCount", "Item count"), \.statusShowItemCount),
                check(
                    L("prefs.statusSize", "Size (of the folder, or the selection)"),
                    \.statusShowSize),
                check(L("prefs.statusFreeSpace", "Free disk space"), \.statusShowFreeSpace),
            ])
        case .menus: return menusPane()
        case .labels: return labelsPane()
        case .search:
            return form([
                check(L("prefs.searchOCR", "Search image contents (OCR, slower)"), \.searchOCR),
                hint(
                    L(
                        "prefs.searchOCRHint",
                        "Text and PDF contents are always indexed; image OCR is extra.")),
            ])
        case .terminal: return terminalPane()
        case .transfers: return transfersPane()
        case .shortcuts: return shortcutsPane()
        case .gestures: return gesturesPane()
        case .integrations: return integrationsPane()
        case .updates: return updatesPane()
        }
    }

    // MARK: - Integrations pane (Finder handoff: the pathem CLI + Services)

    private let cliStatusLabel = NSTextField(labelWithString: "")
    private let cliButton = NSButton(title: "", target: nil, action: nil)

    private func integrationsPane() -> NSView {
        cliButton.target = self
        cliButton.action = #selector(toggleCLIInstall)
        cliButton.bezelStyle = .rounded
        cliStatusLabel.font = .systemFont(ofSize: 11)
        cliStatusLabel.textColor = .secondaryLabelColor
        refreshCLIStatus()

        let cliRow = NSStackView(views: [cliButton, cliStatusLabel])
        cliRow.orientation = .horizontal
        cliRow.spacing = 10

        let editors = ExternalEditors.installed().map(\.name)
        let editorsText =
            editors.isEmpty
            ? L("integrations.noEditors", "No supported editors detected.")
            : String(
                format: L("integrations.detected", "Detected editors: %@"),
                editors.joined(separator: ", "))

        var rows: [NSView] = [
            hint(
                L(
                    "integrations.servicesHint",
                    "Other apps can hand a file or folder to Pathem: use “Open in Pathem” or “Reveal in Pathem” from their Services menu, or the pathem command below."
                )),
            labeled(L("integrations.cliLabel", "Terminal command"), cliRow),
            hint(
                L(
                    "integrations.cliHint",
                    "Installs a “pathem” command on your PATH so “pathem reveal <path>” and “pathem open <dir>” work from any terminal. It’s a symlink to the bundled tool; removing it deletes only that link."
                )),
            hint(editorsText),
        ]
        // Per-editor integrations (each fully reversible -- a Pathem-owned folder, never merging
        // into the user's own config). One row per installed, supported editor.
        builtEditors = EditorIntegration.all.filter { $0.isEditorInstalled() }
        editorButtons = []
        editorStatusLabels = []
        for (index, editor) in builtEditors.enumerated() {
            rows.append(editorRow(editor, index: index))
        }
        if !builtEditors.isEmpty {
            rows.append(
                hint(
                    L(
                        "integrations.editorHint",
                        "Adds “Reveal in Pathem” to the editor’s menus. Everything goes in a Pathem-owned folder, so Remove deletes only that. Preview shows the exact files."
                    )))
        }
        rows.append(
            hint(
                L(
                    "integrations.editorsSoon",
                    "VS Code and Cursor lock their reveal, so Pathem ships a bundled “Reveal in Pathem” extension and installs it through the editor’s own command line; they appear above when detected. For any other editor, use the Services menu or the pathem command above."
                )))
        return form(rows)
    }

    private var builtEditors: [EditorIntegration] = []
    private var editorButtons: [NSButton] = []
    private var editorStatusLabels: [NSTextField] = []

    private func editorRow(_ editor: EditorIntegration, index: Int) -> NSView {
        let button = NSButton(title: "", target: self, action: #selector(toggleEditor(_:)))
        button.bezelStyle = .rounded
        button.tag = index
        let preview = NSButton(
            title: L("integrations.preview", "Preview…"), target: self,
            action: #selector(previewEditor(_:)))
        preview.bezelStyle = .rounded
        preview.tag = index
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        editorButtons.append(button)
        editorStatusLabels.append(status)
        refreshEditorRow(index)
        let row = NSStackView(views: [button, preview, status])
        row.orientation = .horizontal
        row.spacing = 10
        return labeled(editor.name, row)
    }

    private func refreshEditorRow(_ index: Int) {
        guard index < builtEditors.count, index < editorButtons.count else { return }
        let editor = builtEditors[index]
        editorButtons[index].title =
            editor.isInstalled()
            ? L("integrations.cliRemove", "Remove")
            : L("integrations.integrate", "Integrate")
        if editor.isInstalled() {
            editorStatusLabels[index].stringValue = L("integrations.installed", "Installed")
        } else if editor.isEditorRunning() {
            editorStatusLabels[index].stringValue = String(
                format: L(
                    "integrations.editorRunning", "%@ is running; restart it after integrating"),
                editor.name)
        } else {
            editorStatusLabels[index].stringValue = L(
                "integrations.cliNotInstalled", "Not installed")
        }
    }

    @objc private func toggleEditor(_ sender: NSButton) {
        let index = sender.tag
        guard index < builtEditors.count else { return }
        let editor = builtEditors[index]
        do {
            if editor.isInstalled() {
                try editor.remove()
            } else {
                try editor.install()
                if editor.isEditorRunning() {
                    presentInfoAlert(
                        String(format: L("integrations.restartTitle", "Restart %@"), editor.name),
                        String(
                            format: L(
                                "integrations.restartBody",
                                "The “Reveal in Pathem” items appear after you quit and reopen %@."),
                            editor.name))
                }
            }
        } catch {
            presentInfoAlert(
                String(
                    format: L("integrations.editorFailed", "Couldn’t update the %@ integration"),
                    editor.name),
                error.localizedDescription)
        }
        refreshEditorRow(index)
    }

    @objc private func previewEditor(_ sender: NSButton) {
        let index = sender.tag
        guard index < builtEditors.count else { return }
        let text = builtEditors[index].previewFiles()
            .map { "\u{2022} \($0.path)\n\n\($0.contents)" }
            .joined(separator: "\n\n----------\n\n")
        presentInfoAlert(L("integrations.previewTitle", "Files Pathem will write"), text)
    }

    private func presentInfoAlert(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: L("common.ok", "OK"))
        if let window = rootView.window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    private func refreshCLIStatus() {
        cliButton.isEnabled = PathemCLIInstall.bundledCLI != nil
        cliButton.title =
            PathemCLIInstall.isInstalled()
            ? L("integrations.cliRemove", "Remove")
            : L("integrations.cliInstall", "Install")
        if PathemCLIInstall.bundledCLI == nil {
            cliStatusLabel.stringValue = L(
                "integrations.cliUnavailable", "Not available in this build")
        } else if let link = PathemCLIInstall.installedLink() {
            cliStatusLabel.stringValue = String(
                format: L("integrations.cliInstalledAt", "Installed at %@"), link.path)
        } else {
            cliStatusLabel.stringValue = L("integrations.cliNotInstalled", "Not installed")
        }
    }

    @objc private func toggleCLIInstall() {
        do {
            if PathemCLIInstall.isInstalled() {
                try PathemCLIInstall.remove()
            } else {
                try PathemCLIInstall.install()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("integrations.cliFailed", "Couldn’t update the pathem command")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("common.ok", "OK"))
            if let window = rootView.window {
                alert.beginSheetModal(for: window) { _ in }
            } else {
                alert.runModal()
            }
        }
        refreshCLIStatus()
    }

    private func transfersPane() -> NSView {
        let field = NSTextField()
        field.stringValue = prefs.bandwidthLimitKBps > 0 ? "\(prefs.bandwidthLimitKBps)" : ""
        let placeholder = L("prefs.bandwidthPlaceholder", "0 = unlimited")
        field.placeholderString = placeholder
        let font = field.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let width = ceil((placeholder as NSString).size(withAttributes: [.font: font]).width) + 16
        field.widthAnchor.constraint(equalToConstant: max(90, width)).isActive = true
        field.target = self
        field.action = #selector(bandwidthChanged(_:))
        field.cell?.sendsActionOnEndEditing = true  // commit on Tab/click-away too
        return form([
            labeled(L("prefs.bandwidthLabel", "Limit transfer speed (KB/s)"), field),
            hint(
                L(
                    "prefs.bandwidthHint",
                    "Caps remote download and upload speed. 0 means unlimited.")),
            labeled(
                L("prefs.torrentFolderLabel", "Torrent download folder"), torrentFolderControl()),
            check(
                L(
                    "prefs.confirmInboundTorrents",
                    "Ask before adding magnet/torrent links from other apps"),
                \.confirmInboundTorrents),
            hint(
                L(
                    "prefs.confirmInboundTorrentsHint",
                    "On by default: an inbound magnet also seeds what it downloads, so Pathem confirms any link another app or a webpage hands it. Turn off to add them without asking."
                )),
        ])
    }
    @objc private func bandwidthChanged(_ sender: NSTextField) {
        prefs.bandwidthLimitKBps = max(0, Int(sender.stringValue) ?? 0)
        onChange?(prefs)
    }

    private let torrentFolderButton = NSButton()

    private func torrentFolderControl() -> NSView {
        torrentFolderButton.title =
            prefs.torrentDownloadPath.isEmpty
            ? L("prefs.torrentFolderDefault", "Downloads (default)")
            : (prefs.torrentDownloadPath as NSString).lastPathComponent
        torrentFolderButton.bezelStyle = .rounded
        torrentFolderButton.target = self
        torrentFolderButton.action = #selector(chooseTorrentFolder)
        let reset = NSButton(
            title: L("prefs.torrentFolderReset", "Use Downloads"), target: self,
            action: #selector(resetTorrentFolder))
        reset.bezelStyle = .rounded
        let row = NSStackView(views: [torrentFolderButton, reset])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
    @objc private func chooseTorrentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("prefs.chooseFolder", "Choose…")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.prefs.torrentDownloadPath = url.path
            self.torrentFolderButton.title = url.lastPathComponent
            self.onChange?(self.prefs)
        }
    }
    @objc private func resetTorrentFolder() {
        prefs.torrentDownloadPath = ""
        torrentFolderButton.title = L("prefs.torrentFolderDefault", "Downloads (default)")
        onChange?(prefs)
    }

    private func terminalPane() -> NSView {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: terminalThemes)
        popup.selectItem(withTitle: currentTerminalTheme)
        popup.target = self
        popup.action = #selector(terminalThemeChanged(_:))
        let follows = NSButton(
            checkboxWithTitle: L("terminal.followsFolder", "Terminal follows the active folder"),
            target: self, action: #selector(terminalFollowsToggled(_:)))
        follows.state = terminalFollows ? .on : .off
        return form([labeled(L("terminal.theme", "Theme"), popup), follows])
    }

    @objc private func terminalThemeChanged(_ sender: NSPopUpButton) {
        if let title = sender.titleOfSelectedItem { onSelectTerminalTheme?(title) }
    }
    @objc private func terminalFollowsToggled(_ sender: NSButton) {
        onToggleTerminalFollows?(sender.state == .on)
    }

    // MARK: Form helpers

    private func form(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
        ])
        return container
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func hint(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 380
        return label
    }

    /// A checkbox bound to a Bool keypath of Preferences; toggling reports onChange.
    private func check(_ title: String, _ keyPath: WritableKeyPath<Preferences, Bool>) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = prefs[keyPath: keyPath] ? .on : .off
        button.target = self
        button.action = #selector(checkToggled(_:))
        boolPaths[ObjectIdentifier(button)] = keyPath
        return button
    }
    private var boolPaths: [ObjectIdentifier: WritableKeyPath<Preferences, Bool>] = [:]

    #if DEBUG
    var debugPreferences: Preferences { prefs }
    var debugFontDefault: Int { fontStepper.integerValue }
    func debugTogglePreference(_ keyPath: WritableKeyPath<Preferences, Bool>) -> Bool {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, boolPaths[ObjectIdentifier(button)] == keyPath {
                return button
            }
            return view.subviews.compactMap(find).first
        }
        guard let button = paneViews.values.compactMap(find).first else { return false }
        button.performClick(nil)
        return true
    }
    /// Type into the real text field bound to a String preference and commit it.
    func debugCommitStringPreference(
        _ keyPath: WritableKeyPath<Preferences, String>, _ text: String
    ) -> Bool {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, stringPaths[ObjectIdentifier(field)] == keyPath {
                return field
            }
            return view.subviews.compactMap(find).first
        }
        guard let field = paneViews.values.compactMap(find).first else { return false }
        field.stringValue = text
        return field.sendAction(field.action, to: field.target)
    }
    func debugShowGeneralPane() { select(.general) }
    func debugShowAppearancePane() { select(.appearance) }
    #endif

    /// A text field bound to a String preference; commits on edit.
    private func textField(_ keyPath: WritableKeyPath<Preferences, String>, width: CGFloat)
        -> NSView
    {
        let field = NSTextField(string: prefs[keyPath: keyPath])
        if keyPath == \.newFolderName, field.stringValue == Preferences.default.newFolderName {
            field.stringValue = prefs.effectiveNewFolderName
        } else if keyPath == \.newFileName, field.stringValue == Preferences.default.newFileName {
            field.stringValue = prefs.effectiveNewFileName
        }
        field.target = self
        field.action = #selector(stringFieldCommitted(_:))
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        stringPaths[ObjectIdentifier(field)] = keyPath
        return field
    }
    private var stringPaths: [ObjectIdentifier: WritableKeyPath<Preferences, String>] = [:]
    @objc private func stringFieldCommitted(_ sender: NSTextField) {
        guard let keyPath = stringPaths[ObjectIdentifier(sender)] else { return }
        prefs[keyPath: keyPath] = sender.stringValue
        onChange?(prefs)
    }

    private func newTabPositionControl() -> NSView {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: [
            L("prefs.newTabAfter", "After current tab"), L("prefs.newTabEnd", "At the end"),
        ])
        popup.selectItem(at: prefs.newTabAtEnd ? 1 : 0)
        popup.target = self
        popup.action = #selector(newTabPositionChanged(_:))
        return popup
    }
    @objc private func newTabPositionChanged(_ sender: NSPopUpButton) {
        prefs.newTabAtEnd = sender.indexOfSelectedItem == 1
        onChange?(prefs)
    }

    /// Order of the Recents-basis popup, matching the RecentsBasis cases.
    private let recentsBasisOrder: [Preferences.RecentsBasis] = [.modified, .opened]
    private func recentsBasisControl() -> NSView {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: [
            L("prefs.recentsModified", "Recently Modified"),
            L("prefs.recentsOpened", "Recently Opened"),
        ])
        popup.selectItem(at: recentsBasisOrder.firstIndex(of: prefs.recentsBasis) ?? 0)
        popup.target = self
        popup.action = #selector(recentsBasisChanged(_:))
        return popup
    }
    @objc private func recentsBasisChanged(_ sender: NSPopUpButton) {
        prefs.recentsBasis = recentsBasisOrder[sender.indexOfSelectedItem]
        onChange?(prefs)
    }

    @objc private func checkToggled(_ sender: NSButton) {
        guard let keyPath = boolPaths[ObjectIdentifier(sender)] else { return }
        prefs[keyPath: keyPath] = (sender.state == .on)
        if keyPath == \Preferences.trashAfter30Days {
            onTrashRetentionChange?(prefs.trashAfter30Days)
        }
        onChange?(prefs)
    }

    func synchronizeTrashRetention(_ enabled: Bool) {
        prefs.trashAfter30Days = enabled
        synchronizeCheck(\Preferences.trashAfter30Days)
    }

    private func synchronizeCheck(_ keyPath: WritableKeyPath<Preferences, Bool>) {
        func update(_ view: NSView) {
            if let button = view as? NSButton, boolPaths[ObjectIdentifier(button)] == keyPath {
                button.state = prefs[keyPath: keyPath] ? .on : .off
            }
            view.subviews.forEach(update)
        }
        paneViews.values.forEach(update)
    }

    /// Order of the conflict-default popup, matching the ConflictDefault cases.
    private let conflictOrder: [ConflictDefault] = [.ask, .replace, .keepBoth, .skip]
    private func conflictDefaultControl() -> NSView {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: [
            L("prefs.conflictAsk", "Ask each time"), L("prefs.conflictReplace", "Replace"),
            L("prefs.conflictKeepBoth", "Keep both"), L("prefs.conflictSkip", "Skip"),
        ])
        popup.selectItem(at: conflictOrder.firstIndex(of: prefs.conflictDefault) ?? 0)
        popup.target = self
        popup.action = #selector(conflictDefaultChanged(_:))
        return popup
    }
    @objc private func conflictDefaultChanged(_ sender: NSPopUpButton) {
        prefs.conflictDefault = conflictOrder[sender.indexOfSelectedItem]
        onChange?(prefs)
    }

    private let appearancePopup = NSPopUpButton()
    private func appearanceControl() -> NSView {
        let popup = appearancePopup
        popup.removeAllItems()
        popup.addItems(withTitles: [
            L("prefs.appearanceSystem", "System"), L("prefs.appearanceLight", "Light"),
            L("prefs.appearanceDark", "Dark"),
        ])
        popup.selectItem(at: Preferences.Appearance.allCases.firstIndex(of: prefs.appearance) ?? 0)
        popup.target = self
        popup.action = #selector(appearanceChanged(_:))
        return popup
    }
    @objc private func appearanceChanged(_ sender: NSPopUpButton) {
        let modes = Preferences.Appearance.allCases
        guard modes.indices.contains(sender.indexOfSelectedItem) else { return }
        prefs.appearance = modes[sender.indexOfSelectedItem]
        themeOverridesChanged()
    }

    // MARK: Skins (theming)

    private let themePopup = NSPopUpButton()
    private func themeControl() -> NSView {
        themePopup.removeAllItems()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for group in ThemePreset.groups where !group.members.isEmpty {
            menu.addItem(.sectionHeader(title: ThemeManager.groupTitle(group.appearance)))
            for (_, preset) in group.members {
                menu.addItem(ThemeManager.menuItem(for: preset, action: nil, target: nil))
            }
        }
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: L("prefs.themeCustom", "Custom"), action: nil, keyEquivalent: ""))
        themePopup.menu = menu
        updateThemeSelection()
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        return themePopup
    }
    @objc private func themeChanged(_ sender: NSPopUpButton) {
        guard
            let name = sender.selectedItem?.representedObject as? String,
            let preset = ThemePreset.presets.first(where: { $0.name == name })
        else { return }
        previewTheme(preset)
    }

    private func updateThemeSelection() {
        let preset = ThemePreset.matching(
            accentHex: prefs.accentColorHex, backgroundHex: prefs.windowTintHex,
            appearance: prefs.appearance, styles: prefs.themeStyles)
        guard let custom = themePopup.itemArray.last else { return }
        let name = prefs.themeName
        let isBuiltIn = ThemePreset.presets.contains { $0.name == name }
        custom.title = isBuiltIn || name.isEmpty ? L("prefs.themeCustom", "Custom") : name
        let selected = themePopup.itemArray.first {
            ($0.representedObject as? String) == preset?.name
        }
        themePopup.select(preset == nil || prefs.communityTheme != nil ? custom : selected)
    }

    func synchronizeTheme(
        _ theme: ThemePreset, communityTheme: CommunityThemeRevision.Reference? = nil
    ) {
        theme.apply(to: &prefs)
        prefs.communityTheme = communityTheme
        updateThemeSelection()
        let modes = Preferences.Appearance.allCases
        appearancePopup.selectItem(at: modes.firstIndex(of: theme.appearance) ?? 0)
        accentWell.color = ThemeManager.color(fromHex: theme.accentHex) ?? .controlAccentColor
        tintWell.color = ThemeManager.color(fromHex: theme.backgroundHex) ?? .windowBackgroundColor
    }

    private func commitTheme(_ theme: ThemePreset) {
        synchronizeTheme(theme)
        onChange?(prefs)
    }

    private func themePackageControls() -> NSView {
        let stack = NSStackView(views: [
            NSButton(
                title: L("prefs.themeImport", "Import…"), target: self,
                action: #selector(importTheme)),
            NSButton(
                title: L("prefs.themeExport", "Export…"), target: self,
                action: #selector(exportTheme)),
            NSButton(
                title: L("prefs.themeReset", "Reset Theme"), target: self,
                action: #selector(resetTheme)),
        ])
        stack.spacing = 8
        let browse = NSButton(
            title: L("prefs.themes", "Themes") + "…", target: self,
            action: #selector(openCommunityThemes))
        let submit = NSButton(
            title: L("prefs.themePrepareSubmission", "Submit a Theme…"), target: self,
            action: #selector(prepareThemeSubmission))
        let gallery = NSStackView(views: [browse, submit])
        gallery.spacing = 8
        let controls = NSStackView(views: [stack, gallery])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        return controls
    }

    @objc private func openCommunityThemes() {
        guard let url = CommunityThemeGalleryWindow.storeURL else {
            NSSound.beep()
            return
        }
        // The only catalog request in the app: it follows this explicit click.
        Task { @MainActor in
            do {
                if let endpoint = CommunityThemeGalleryWindow.sharedEndpoint {
                    try await CommunityThemeGalleryWindow.refreshSharedCatalog(endpoint, at: url)
                }
                try makeCommunityGallery(at: url).run()
            } catch { NSAlert(error: error).runModal() }
        }
    }

    func makeCommunityGallery(at url: URL) throws -> CommunityThemeGalleryWindow {
        try CommunityThemeGalleryWindow(
            url: url, active: prefs.communityTheme,
            preview: { [weak self] in self?.onThemePreview?($0) },
            apply: { [weak self] theme, reference in
                guard let self else { return }
                self.synchronizeTheme(theme, communityTheme: reference)
                self.onChange?(self.prefs)
            })
    }

    @objc private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ExternalThemeImport.fileExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let (theme, palette) = try await Task.detached(priority: .userInitiated) {
                    try Self.readImportedTheme(at: url)
                }.value
                previewTheme(theme, terminalPalette: palette)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private nonisolated static func readImportedTheme(at url: URL) throws
        -> (ThemePreset, ExternalThemeImport.TerminalPalette?)
    {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ThemePackage.ValidationError.invalidDocument
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: ExternalThemeImport.maximumBytes + 1) ?? Data()
        guard data.count <= ExternalThemeImport.maximumBytes else {
            throw ThemePackage.ValidationError.tooLarge
        }
        let name = String(url.deletingPathExtension().lastPathComponent.prefix(80))
        if url.pathExtension.lowercased() == "itermcolors" {
            let palette = try ExternalThemeImport.iterm(data, name: "\(name) (.itermcolors)")
            let swatch = ThemePreset(
                name: name, appearance: .system,
                accentHex: palette.cursor ?? palette.foreground ?? "",
                backgroundHex: palette.background ?? "")
            return (swatch, palette)
        }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            object["schemaVersion"] != nil
        {
            return (try ThemePackage.decode(data), nil)
        }
        return (try ExternalThemeImport.vscode(data, name: name), nil)
    }

    private func previewTheme(
        _ theme: ThemePreset, terminalPalette: ExternalThemeImport.TerminalPalette? = nil
    ) {
        let alert = NSAlert()
        alert.messageText = L("prefs.themePreview", "Theme Preview")
        alert.informativeText =
            terminalPalette.map { "\(Pane.terminal.title) · \($0.name)" } ?? theme.name
        alert.icon = ThemeManager.swatch(for: theme)
        alert.addButton(withTitle: L("common.apply", "Apply"))
        let cancel = alert.addButton(withTitle: L("common.cancel", "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        if terminalPalette == nil { onThemePreview?(theme) }
        if alert.runModal() == .alertFirstButtonReturn {
            if let terminalPalette {
                onImportedTerminalPalette?(terminalPalette)
                currentTerminalTheme = terminalPalette.name
                if !terminalThemes.contains(terminalPalette.name) {
                    terminalThemes.append(terminalPalette.name)
                }
            } else {
                commitTheme(theme)
            }
        } else if terminalPalette == nil {
            onThemePreview?(nil)
            updateThemeSelection()
        }
    }

    @objc private func exportTheme() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Pathem Theme.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ThemePackage.encode(themeForExport())
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func themeForExport() -> ThemePreset {
        var theme = ThemePreset(preferences: prefs)
        if theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            theme.name = L("prefs.themeCustom", "Custom")
        }
        theme.styles = prefs.effectiveThemeStyles
        return theme
    }

    @objc private func prepareThemeSubmission() {
        ThemeSubmissionDialog.run(theme: themeForExport())
    }

    @objc private func resetTheme() {
        commitTheme(.system)
    }

    private let folderStylePopup = NSPopUpButton()
    private let fileIconPopup = NSPopUpButton()
    private let toolbarStylePopup = NSPopUpButton()

    private func styleControl(_ popup: NSPopUpButton, choices: [String]) -> NSView {
        popup.removeAllItems()
        popup.addItem(withTitle: L("prefs.useThemeStyle", "Use Theme"))
        for name in choices {
            popup.addItem(
                withTitle: name == "System" ? L("prefs.appearanceSystem", "System") : name)
            popup.lastItem?.representedObject = name
        }
        synchronizeStyleControls()
        popup.target = self
        popup.action = #selector(styleChanged(_:))
        return popup
    }

    private func synchronizeStyleControls() {
        for (popup, choice) in [
            (folderStylePopup, prefs.folderStyleOverride?.rawValue),
            (fileIconPopup, prefs.iconSetName),
            (toolbarStylePopup, prefs.toolbarStyleOverride?.rawValue),
        ] {
            popup.select(
                popup.itemArray.first {
                    ($0.representedObject as? String) == choice
                } ?? popup.itemArray.first)
        }
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        let choice = sender.selectedItem?.representedObject as? String
        if sender === folderStylePopup {
            prefs.folderStyleOverride = choice.flatMap(ThemeStyles.Folder.init(rawValue:))
        } else if sender === fileIconPopup {
            prefs.iconSetName = choice ?? ""
        } else {
            prefs.toolbarStyleOverride = choice.flatMap(ThemeStyles.Toolbar.init(rawValue:))
        }
        onChange?(prefs)
    }

    private let accentWell = NSColorWell()
    private let tintWell = NSColorWell()

    private func accentColorControl() -> NSView {
        colorControl(
            accentWell, hex: prefs.accentColorHex, fallback: .controlAccentColor,
            action: #selector(accentColorChanged(_:)),
            clearTitle: L("prefs.appearanceSystem", "System"), clear: #selector(clearAccent))
    }

    private func windowTintControl() -> NSView {
        colorControl(
            tintWell, hex: prefs.windowTintHex, fallback: .windowBackgroundColor,
            action: #selector(windowTintChanged(_:)),
            clearTitle: L("prefs.themeClearTint", "None"), clear: #selector(clearWindowTint))
    }

    private func colorControl(
        _ well: NSColorWell, hex: String, fallback: NSColor, action: Selector, clearTitle: String,
        clear: Selector
    ) -> NSView {
        well.color = ThemeManager.color(fromHex: hex) ?? fallback
        well.target = self
        well.action = action
        let button = NSButton(title: clearTitle, target: self, action: clear)
        let stack = NSStackView(views: [well, button])
        stack.spacing = 8
        return stack
    }

    @objc private func accentColorChanged(_ sender: NSColorWell) {
        prefs.accentColorHex = ThemeManager.hex(from: sender.color)
        themeOverridesChanged()
    }

    @objc private func windowTintChanged(_ sender: NSColorWell) {
        prefs.windowTintHex = ThemeManager.hex(from: sender.color)
        themeOverridesChanged()
    }

    @objc private func clearAccent() {
        prefs.accentColorHex = ""
        accentWell.color = .controlAccentColor
        themeOverridesChanged()
    }

    @objc private func clearWindowTint() {
        prefs.windowTintHex = ""
        tintWell.color = .windowBackgroundColor
        themeOverridesChanged()
    }

    private func themeOverridesChanged() {
        updateThemeSelection()
        onChange?(prefs)
    }

    private func densityControl() -> NSView {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: [
            L("prefs.densityComfortable", "Comfortable"), L("prefs.densityCompact", "Compact"),
        ])
        popup.selectItem(at: prefs.density == .compact ? 1 : 0)
        popup.target = self
        popup.action = #selector(densityChanged(_:))
        return popup
    }
    @objc private func densityChanged(_ sender: NSPopUpButton) {
        prefs.density = sender.indexOfSelectedItem == 1 ? .compact : .comfortable
        onChange?(prefs)
    }

    private let newTabPopup = NSPopUpButton()
    private let fixedFolderButton = NSButton()
    private let folderHandlerCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    /// A checkbox that makes Pathem (checked) or Finder (unchecked) the system's default app
    /// for opening folders. Reflects the live system state; the change is fully reversible.
    private func folderHandlerControl() -> NSView {
        folderHandlerCheckbox.title = L(
            "prefs.folderHandler", "Open folders in Pathem instead of Finder")
        folderHandlerCheckbox.state = FolderHandler.isPathem ? .on : .off
        folderHandlerCheckbox.target = self
        folderHandlerCheckbox.action = #selector(folderHandlerToggled(_:))
        return folderHandlerCheckbox
    }
    @objc private func folderHandlerToggled(_ sender: NSButton) {
        guard sender.state == .on else {  // turning it off restores Finder immediately
            applyFolderHandler(toPathem: false, checkbox: sender)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("prefs.folderHandlerConfirmTitle", "Open folders in Pathem?")
        alert.informativeText = L(
            "prefs.folderHandlerConfirmBody",
            "This makes Pathem the default app for opening folders system-wide, so a folder double-click or an app that opens a folder uses Pathem instead of Finder. It does not affect \u{201C}Reveal in Finder.\u{201D} You can switch back here anytime."
        )
        alert.addButton(withTitle: L("prefs.folderHandlerUse", "Use Pathem"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                sender.state = .off
                return
            }
            self?.applyFolderHandler(toPathem: true, checkbox: sender)
        }
    }
    private func applyFolderHandler(toPathem: Bool, checkbox: NSButton) {
        Task { @MainActor in
            do {
                try await FolderHandler.setDefault(toPathem: toPathem)
            } catch {
                let alert = NSAlert()
                alert.messageText = L(
                    "prefs.folderHandlerFailed", "Couldn’t change the default folder app")
                // Recent macOS blocks replacing Finder as the default handler for folders and returns
                // only a generic error; explain the likely cause rather than surface it raw.
                alert.informativeText = String(
                    format: L(
                        "prefs.folderHandlerFailedBody",
                        "This version of macOS may not allow replacing Finder as the default app for folders. You can still open folders in Pathem with drag-and-drop or “Open in Pathem.”\n\n(%@)"
                    ),
                    error.localizedDescription)
                alert.beginSheetModal(for: self.window) { _ in }
            }
            checkbox.state = FolderHandler.isPathem ? .on : .off  // reflect the real state either way
        }
    }

    private let magnetHandlerButton = NSButton(title: "", target: nil, action: nil)
    private let magnetHandlerStatus = NSTextField(labelWithString: "")

    /// A button that makes Pathem the default app for magnet links (and .torrent files), with a live
    /// status line. Reversible by setting another client back as the default in its own settings.
    private func magnetHandlerControl() -> NSView {
        magnetHandlerButton.title = L(
            "prefs.magnetHandler.make", "Make Pathem the Default for Magnet Links")
        magnetHandlerButton.bezelStyle = .rounded
        magnetHandlerButton.target = self
        magnetHandlerButton.action = #selector(makeMagnetHandlerDefault(_:))
        magnetHandlerStatus.font = .systemFont(ofSize: 11)
        magnetHandlerStatus.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [magnetHandlerButton, magnetHandlerStatus])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        refreshMagnetHandlerState()
        return stack
    }
    private func refreshMagnetHandlerState() {
        let isDefault = MagnetHandler.isPathem
        magnetHandlerButton.isEnabled = !isDefault
        magnetHandlerStatus.stringValue =
            isDefault
            ? L("prefs.magnetHandler.isDefault", "Magnet links and .torrent files open in Pathem.")
            : L("prefs.magnetHandler.notDefault", "Magnet links currently open in another app.")
    }
    @objc private func makeMagnetHandlerDefault(_ sender: NSButton) {
        Task { @MainActor in
            do {
                try await MagnetHandler.makeDefault()
            } catch {
                let alert = NSAlert()
                alert.messageText = L(
                    "prefs.magnetHandler.failed", "Couldn’t change the default magnet app")
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: self.window) { _ in }
            }
            self.refreshMagnetHandlerState()  // reflect the real state either way
        }
    }

    private func newTabLocationControl() -> NSView {
        newTabPopup.removeAllItems()
        newTabPopup.addItems(withTitles: [
            L("prefs.newTabLast", "Last folder"), L("prefs.newTabHome", "Home"),
            L("prefs.newTabFixed", "Fixed folder"),
        ])
        newTabPopup.selectItem(
            at: Preferences.NewTabLocation.allCases.firstIndex(of: prefs.newTabLocation) ?? 0)
        newTabPopup.target = self
        newTabPopup.action = #selector(newTabLocationChanged(_:))
        return newTabPopup
    }
    @objc private func newTabLocationChanged(_ sender: NSPopUpButton) {
        prefs.newTabLocation = Preferences.NewTabLocation.allCases[sender.indexOfSelectedItem]
        onChange?(prefs)
    }

    private func fixedFolderControl() -> NSView {
        let name =
            prefs.fixedStartFolder.isEmpty
            ? L("prefs.chooseFolder", "Choose…")
            : (prefs.fixedStartFolder as NSString).lastPathComponent
        fixedFolderButton.title = name
        fixedFolderButton.bezelStyle = .rounded
        fixedFolderButton.target = self
        fixedFolderButton.action = #selector(chooseFixedFolder)
        return fixedFolderButton
    }
    @objc private func chooseFixedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = L("prefs.chooseFolder", "Choose…")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.prefs.fixedStartFolder = url.path
            self.prefs.newTabLocation = .fixed  // choosing a folder implies using it
            self.fixedFolderButton.title = url.lastPathComponent
            self.newTabPopup.selectItem(at: 2)
            self.onChange?(self.prefs)
        }
    }

    private func commanderEditButton() -> NSView {
        let button = NSButton(
            title: L("prefs.commanderEdit", "Customize…"), target: self,
            action: #selector(editCommanderKeys))
        button.bezelStyle = .rounded
        return button
    }
    @objc private func editCommanderKeys() {
        let (alert, popups) = Self.makeCommanderKeysDialog(
            commands: commandList, current: prefs.commanderCommands)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.prefs.commanderCommands = popups.map {
                ($0.selectedItem?.representedObject as? String) ?? ""
            }
            self.onChange?(self.prefs)
        }
    }

    /// Build the real dialog independently of presentation, so the complete alert can be
    /// measured in native layout checks without committing any preference changes.
    static func makeCommanderKeysDialog(
        commands: [(id: String, title: String)], current: [String]
    ) -> (alert: NSAlert, popups: [NSPopUpButton]) {
        let current =
            current.count == 6 ? current : CommanderBar.defaultCommandIDs
        let sorted = commands.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let popups: [NSPopUpButton] = (0..<6).map { index in
            let popup = NSPopUpButton()
            popup.cell?.lineBreakMode = .byTruncatingTail
            for command in sorted {
                let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
                item.representedObject = command.id
                popup.menu?.addItem(item)
            }
            if let match = sorted.firstIndex(where: { $0.id == current[index] }) {
                popup.selectItem(at: match)
            }
            return popup
        }
        // A popup's natural width follows its longest translated command. Bound it so
        // an unusually long title cannot stretch the sheet past a laptop display.
        let naturalPopupWidth = popups.map { $0.fittingSize.width }.max() ?? 0
        let width = min(520, max(320, ceil(naturalPopupWidth) + 38))
        let rows = (0..<6).map { index in
            let label = NSTextField(labelWithString: "F\(3 + index)")
            label.widthAnchor.constraint(equalToConstant: 30).isActive = true
            let popup = popups[index]
            popup.widthAnchor.constraint(equalToConstant: width - 38).isActive = true
            let row = NSStackView(views: [label, popup])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }
        let form = NSStackView(views: rows)
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8

        let alert = NSAlert()
        alert.messageText = L("prefs.commanderSheetTitle", "Commander F-keys")
        alert.informativeText = L(
            "prefs.commanderSheetBody", "Choose the command each F-key runs in Commander mode.")
        // NSAlert positions an accessory using its frame; a width constraint on a
        // zero-frame stack alone leaves the controls outside the reserved sheet area.
        let accessory = MeasuredAccessoryView(content: form, width: width)
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return (alert, popups)
    }

    #if DEBUG
    func debugMakeCommanderKeysDialog() -> (alert: NSAlert, popups: [NSPopUpButton]) {
        Self.makeCommanderKeysDialog(commands: commandList, current: prefs.commanderCommands)
    }
    #endif

    private let defaultViewPopup = NSPopUpButton()
    private func defaultViewControl() -> NSView {
        let popup = defaultViewPopup
        popup.removeAllItems()
        popup.addItems(withTitles: [
            L("view.list", "List"), L("view.icons", "Icons"), L("view.gallery", "Gallery"),
            L("view.column", "Column"), L("view.tree", "Tree"),
        ])
        popup.selectItem(
            at: ViewFormat.ViewMode.allCases.firstIndex(of: prefs.defaultViewMode) ?? 0)
        popup.target = self
        popup.action = #selector(defaultViewChanged(_:))
        return popup
    }
    @objc private func defaultViewChanged(_ sender: NSPopUpButton) {
        prefs.defaultViewMode = ViewFormat.ViewMode.allCases[sender.indexOfSelectedItem]
        onChange?(prefs)
    }

    private let defaultSortKeyPopup = NSPopUpButton()
    private let defaultSortDirPopup = NSPopUpButton()
    /// Keep the visible controls and their callback model aligned with the global view command.
    func synchronizeDefaultFormat(_ format: ViewFormat, shared: Preferences? = nil) {
        if let shared {
            prefs.fontSize = shared.fontSize
            prefs.dateDisplay = shared.dateDisplay
            prefs.iconZoom = shared.iconZoom
            prefs.calculateFolderSizes = shared.calculateFolderSizes
            fontStepper.integerValue = prefs.fontSize
            fontValue.stringValue = "\(prefs.fontSize)"
            dateFormatPopup.selectItem(
                at: Preferences.DateDisplay.allCases.firstIndex(of: prefs.dateDisplay) ?? 0)
            synchronizeCheck(\Preferences.calculateFolderSizes)
        }
        prefs.defaultViewMode = format.viewMode
        prefs.defaultSortKey = format.sortKey
        prefs.defaultSortAscending = format.ascending
        defaultViewPopup.selectItem(
            at: ViewFormat.ViewMode.allCases.firstIndex(of: format.viewMode) ?? 0)
        defaultSortKeyPopup.selectItem(
            at: ViewFormat.SortKey.allCases.firstIndex(of: format.sortKey) ?? 0)
        defaultSortDirPopup.selectItem(at: format.ascending ? 0 : 1)
    }

    private func defaultSortControl() -> NSView {
        defaultSortKeyPopup.removeAllItems()
        defaultSortKeyPopup.addItems(withTitles: ViewFormat.SortKey.allCases.map(\.localizedTitle))
        defaultSortKeyPopup.selectItem(
            at: ViewFormat.SortKey.allCases.firstIndex(of: prefs.defaultSortKey) ?? 0)
        defaultSortKeyPopup.target = self
        defaultSortKeyPopup.action = #selector(defaultSortChanged)
        defaultSortDirPopup.removeAllItems()
        defaultSortDirPopup.addItems(withTitles: [
            L("sort.ascending", "Ascending"), L("sort.descending", "Descending"),
        ])
        defaultSortDirPopup.selectItem(at: prefs.defaultSortAscending ? 0 : 1)
        defaultSortDirPopup.target = self
        defaultSortDirPopup.action = #selector(defaultSortChanged)
        let stack = NSStackView(views: [defaultSortKeyPopup, defaultSortDirPopup])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }
    @objc private func defaultSortChanged() {
        prefs.defaultSortKey = ViewFormat.SortKey.allCases[defaultSortKeyPopup.indexOfSelectedItem]
        prefs.defaultSortAscending = defaultSortDirPopup.indexOfSelectedItem == 0
        onChange?(prefs)
    }

    private func sizeFormatControl() -> NSView {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: [
            L("prefs.sizeDecimal", "Decimal (KB, MB)"), L("prefs.sizeBinary", "Binary (KiB, MiB)"),
        ])
        popup.selectItem(at: prefs.sizeFormat == .binary ? 1 : 0)
        popup.target = self
        popup.action = #selector(sizeFormatChanged(_:))
        return popup
    }
    @objc private func sizeFormatChanged(_ sender: NSPopUpButton) {
        prefs.sizeFormat = sender.indexOfSelectedItem == 1 ? .binary : .decimal
        onChange?(prefs)
    }

    private let dateFormatPopup = NSPopUpButton()
    private func dateFormatControl() -> NSView {
        let popup = dateFormatPopup
        popup.removeAllItems()
        popup.addItems(withTitles: [
            L("prefs.dateRelative", "Relative (Yesterday at 3:14 PM)"),
            L("prefs.dateShort", "Short (7/8/26, 3:14 PM)"),
            L("prefs.dateMedium", "Medium (Jul 8, 2026)"),
        ])
        popup.selectItem(
            at: Preferences.DateDisplay.allCases.firstIndex(of: prefs.dateDisplay) ?? 2)
        popup.target = self
        popup.action = #selector(dateFormatChanged(_:))
        return popup
    }
    @objc private func dateFormatChanged(_ sender: NSPopUpButton) {
        prefs.dateDisplay = Preferences.DateDisplay.allCases[sender.indexOfSelectedItem]
        onChange?(prefs)
    }

    private func iconSizeControl() -> NSView {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: [
            L("prefs.iconSmall", "Small"), L("prefs.iconMedium", "Medium"),
            L("prefs.iconLarge", "Large"),
            L("prefs.iconExtraLarge", "Extra Large"),
        ])
        popup.selectItem(
            at: Preferences.IconSize.allCases.firstIndex(of: prefs.toolbarIconSize) ?? 1)
        popup.target = self
        popup.action = #selector(iconSizeChanged(_:))
        return popup
    }
    @objc private func iconSizeChanged(_ sender: NSPopUpButton) {
        prefs.toolbarIconSize = Preferences.IconSize.allCases[sender.indexOfSelectedItem]
        onChange?(prefs)
    }

    /// Color + width for the super-drag swipe trail.
    private func dragTrailControl() -> NSView {
        let well = NSColorWell()
        well.color = NSColor(hex: prefs.dragTrailColor) ?? .systemBlue
        well.target = self
        well.action = #selector(dragTrailColorChanged(_:))
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let stepper = NSStepper()
        stepper.minValue = 2
        stepper.maxValue = 16
        stepper.increment = 1
        stepper.doubleValue = prefs.dragTrailWidth
        stepper.target = self
        stepper.action = #selector(dragTrailWidthChanged(_:))
        dragTrailWidthValue.stringValue = "\(Int(prefs.dragTrailWidth))"
        dragTrailWidthValue.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let decay = NSStepper()
        decay.minValue = 0.1
        decay.maxValue = 2.5
        decay.increment = 0.1
        decay.doubleValue = prefs.dragTrailDecay
        decay.target = self
        decay.action = #selector(dragTrailDecayChanged(_:))
        dragTrailDecayValue.stringValue = String(format: "%.1fs", prefs.dragTrailDecay)
        dragTrailDecayValue.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let stack = NSStackView(views: [
            well, NSTextField(labelWithString: L("prefs.dragTrailWidth", "Width")), stepper,
            dragTrailWidthValue,
            NSTextField(labelWithString: L("prefs.dragTrailDecay", "Trail time")),
            decay, dragTrailDecayValue,
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }
    @objc private func dragTrailDecayChanged(_ sender: NSStepper) {
        prefs.dragTrailDecay = sender.doubleValue
        dragTrailDecayValue.stringValue = String(format: "%.1fs", sender.doubleValue)
        onChange?(prefs)
    }
    @objc private func dragTrailColorChanged(_ sender: NSColorWell) {
        prefs.dragTrailColor = sender.color.hexString
        onChange?(prefs)
    }
    @objc private func dragTrailWidthChanged(_ sender: NSStepper) {
        prefs.dragTrailWidth = sender.doubleValue
        dragTrailWidthValue.stringValue = "\(Int(sender.doubleValue))"
        onChange?(prefs)
    }

    /// The customizable file right-click menu: a reorderable list with a show/hide checkbox
    /// per entry (drag to reorder, uncheck to hide).
    private func menusPane() -> NSView {
        let editor = ContextMenuEditorController(
            order: prefs.contextMenuOrder, hidden: prefs.hiddenContextItems)
        editor.onChange = { [weak self] order, hidden in
            guard let self else { return }
            // A full default layout persists as empty, so it stays in sync with future defaults.
            self.prefs.contextMenuOrder =
                order == FileContextMenuController.defaultEntries ? [] : order
            self.prefs.hiddenContextItems = hidden
            self.onChange?(self.prefs)
        }
        contextMenuEditor = editor  // retain it; the pane view doesn't own the controller
        return form([editor.view])
    }

    /// File color rules (Directory-Opus labels): a reorderable list of match -> style rules.
    private func labelsPane() -> NSView {
        let editor = ColorRulesEditorController(rules: prefs.colorRules.rules)
        editor.onChange = { [weak self] rules in
            guard let self else { return }
            self.prefs.colorRules = ColorRules(rules: rules)
            self.onChange?(self.prefs)
        }
        colorRulesEditor = editor  // retain it
        return form([editor.view])
    }

    private let fontValue = NSTextField(labelWithString: "13")
    private let fontStepper = NSStepper()
    private let dragTrailWidthValue = NSTextField(labelWithString: "6")
    private let dragTrailDecayValue = NSTextField(labelWithString: "0.6s")
    private func fontControl() -> NSView {
        let stepper = fontStepper
        stepper.minValue = 9
        stepper.maxValue = 24
        stepper.increment = 1
        stepper.integerValue = prefs.fontSize
        stepper.target = self
        stepper.action = #selector(fontChanged(_:))
        fontValue.stringValue = "\(prefs.fontSize)"
        fontValue.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let stack = NSStackView(views: [stepper, fontValue])
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }
    @objc private func fontChanged(_ sender: NSStepper) {
        prefs.fontSize = sender.integerValue
        fontValue.stringValue = "\(sender.integerValue)"
        onChange?(prefs)
    }

    // MARK: Shortcuts pane

    private func shortcutsPane() -> NSView {
        for id in ["command", "shortcut"] {
            let column = NSTableColumn(identifier: .init(id))
            column.title =
                id == "command"
                ? L("shortcuts.colCommand", "Command") : L("shortcuts.colShortcut", "Shortcut")
            column.width = id == "command" ? 320 : 130
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        recorder.onRecord = { [weak self] chord in self?.assignSelected(chord) }
        recorder.onClear = { [weak self] in self?.clearSelected() }
        let clear = NSButton(
            title: L("shortcuts.clear", "Clear"), target: self, action: #selector(clearButton))
        let restore = NSButton(
            title: L("shortcuts.restoreDefaults", "Restore Defaults"), target: self,
            action: #selector(restoreDefaults))
        clear.bezelStyle = .rounded
        restore.bezelStyle = .rounded
        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.textColor = .secondaryLabelColor
        conflictLabel.lineBreakMode = .byTruncatingTail

        let controls = NSStackView(views: [
            NSTextField(labelWithString: L("shortcuts.setLabel", "Shortcut:")), recorder, clear,
            NSView(), restore,
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        for view in [scroll, controls, conflictLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 320),
            controls.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            conflictLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 6),
            conflictLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            conflictLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            conflictLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            container.widthAnchor.constraint(equalToConstant: 560),
        ])
        table.reloadData()
        return container
    }

    private func chords(for id: String) -> [String] {
        effective.filter { $0.value == id }.keys.sorted()
    }

    private var selectedCommandID: String? {
        let row = table.selectedRow
        return (0..<commandList.count).contains(row) ? commandList[row].id : nil
    }

    private func assignSelected(_ chord: KeyChord) {
        guard let id = selectedCommandID else { return }
        let canonical = chord.canonical
        let previous = effective[canonical]
        // One shortcut per command: drop the command's existing chords, then set this.
        for (existing, command) in effective where command == id { effective[existing] = nil }
        effective[canonical] = id
        commitKeymap()
        if let previous, previous != id {
            let title = commandList.first { $0.id == previous }?.title ?? previous
            conflictLabel.stringValue = String(
                format: L("shortcuts.reassigned", "%@ was reassigned from “%@”."),
                ChordFormat.display(canonical), title)
        } else {
            conflictLabel.stringValue = ""
        }
        refreshShortcuts()
    }

    private func clearSelected() {
        guard let id = selectedCommandID else { return }
        for (existing, command) in effective where command == id { effective[existing] = nil }
        conflictLabel.stringValue = ""
        commitKeymap()
        refreshShortcuts()
    }

    @objc private func clearButton() { clearSelected() }

    @objc private func restoreDefaults() {
        effective = Keymap.defaultBindings
        conflictLabel.stringValue = ""
        commitKeymap()
        refreshShortcuts()
    }

    private func commitKeymap() { onKeymapChange?(Keymap.overlay(forEffective: effective)) }

    private func refreshShortcuts() {
        table.reloadData()
        recorder.canonical = selectedCommandID.flatMap { chords(for: $0).first } ?? ""
    }

    // MARK: Gestures pane

    private func gesturesPane() -> NSView {
        for (id, width) in [("command", CGFloat(320)), ("gesture", CGFloat(130))] {
            let column = NSTableColumn(identifier: .init(id))
            column.title =
                id == "command"
                ? L("shortcuts.colCommand", "Command") : L("gestures.colGesture", "Gesture")
            column.width = width
            gestureTable.addTableColumn(column)
        }
        gestureTable.dataSource = self
        gestureTable.delegate = self
        gestureTable.rowHeight = 22
        gestureTable.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = gestureTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        gestureRecorder.onRecord = { [weak self] stroke in self?.assignGesture(stroke) }
        gestureRecorder.onClear = { [weak self] in self?.clearGesture() }
        let restore = NSButton(
            title: L("shortcuts.restoreDefaults", "Restore Defaults"), target: self,
            action: #selector(restoreGestures))
        restore.bezelStyle = .rounded
        gestureConflictLabel.font = .systemFont(ofSize: 11)
        gestureConflictLabel.textColor = .secondaryLabelColor
        gestureConflictLabel.lineBreakMode = .byTruncatingTail
        let help = NSTextField(
            wrappingLabelWithString:
                L(
                    "gestures.help",
                    "Hold the right mouse button and drag in a file view: ← back, → forward, ↑ enclosing folder. Pick a command, then right-drag in the box to rebind."
                ))
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor

        let controls = NSStackView(views: [
            NSTextField(labelWithString: L("gestures.setLabel", "Gesture:")), gestureRecorder,
            NSView(),
            restore,
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        for view in [help, scroll, controls, gestureConflictLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            help.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            help.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            help.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 250),
            controls.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            gestureConflictLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 6),
            gestureConflictLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            gestureConflictLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            gestureConflictLabel.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -16),
            container.widthAnchor.constraint(equalToConstant: 560),
        ])
        gestureTable.reloadData()
        return container
    }

    private func gestures(for id: String) -> [String] {
        gestureEffective.filter { $0.value == id }.keys.sorted()
    }

    private var selectedGestureCommandID: String? {
        let row = gestureTable.selectedRow
        return (0..<commandList.count).contains(row) ? commandList[row].id : nil
    }

    private func assignGesture(_ stroke: String) {
        guard let id = selectedGestureCommandID else { return }
        let previous = gestureEffective[stroke]
        for (existing, command) in gestureEffective where command == id {
            gestureEffective[existing] = nil
        }
        gestureEffective[stroke] = id
        onGestureChange?(GestureMap.overlay(forEffective: gestureEffective))
        if let previous, previous != id {
            let title = commandList.first { $0.id == previous }?.title ?? previous
            gestureConflictLabel.stringValue = String(
                format: L("gestures.reassigned", "%@ was reassigned from “%@”."),
                GestureFormat.display(stroke), title)
        } else {
            gestureConflictLabel.stringValue = ""
        }
        refreshGestures()
    }

    private func clearGesture() {
        guard let id = selectedGestureCommandID else { return }
        for (existing, command) in gestureEffective where command == id {
            gestureEffective[existing] = nil
        }
        gestureConflictLabel.stringValue = ""
        onGestureChange?(GestureMap.overlay(forEffective: gestureEffective))
        refreshGestures()
    }

    @objc private func restoreGestures() {
        gestureEffective = GestureMap.defaultBindings
        gestureConflictLabel.stringValue = ""
        onGestureChange?(GestureMap.overlay(forEffective: gestureEffective))
        refreshGestures()
    }

    private func refreshGestures() {
        gestureTable.reloadData()
        gestureRecorder.stroke = selectedGestureCommandID.flatMap { gestures(for: $0).first } ?? ""
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { commandList.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, row < commandList.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                c.identifier = id
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingTail
                c.addSubview(field)
                c.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
        switch tableColumn.identifier.rawValue {
        case "command":
            cell.textField?.stringValue = commandList[row].title
            cell.textField?.textColor = .labelColor
        case "gesture":
            cell.textField?.stringValue = gestures(for: commandList[row].id).map(
                GestureFormat.display
            )
            .joined(separator: ", ")
            cell.textField?.textColor = .secondaryLabelColor
        default:  // "shortcut"
            cell.textField?.stringValue = chords(for: commandList[row].id).map(ChordFormat.display)
                .joined(separator: ", ")
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === gestureTable {
            gestureRecorder.stroke =
                selectedGestureCommandID.flatMap { gestures(for: $0).first } ?? ""
            gestureConflictLabel.stringValue = ""
        } else {
            recorder.canonical = selectedCommandID.flatMap { chords(for: $0).first } ?? ""
            conflictLabel.stringValue = ""
        }
    }

    // MARK: Updates pane

    private func updatesPane() -> NSView {
        let configured = updater?.isConfigured ?? false
        let auto = NSButton(
            checkboxWithTitle: L("update.autoCheck", "Check for updates automatically"),
            target: self,
            action: #selector(autoCheckToggled(_:)))
        auto.state = (updater?.automaticChecks ?? false) ? .on : .off
        auto.isEnabled = configured
        autoInstall.title = L(
            "update.autoInstall", "Automatically download and install updates")
        autoInstall.target = self
        autoInstall.action = #selector(autoInstallToggled(_:))
        autoInstall.state = (updater?.automaticDownloads ?? false) ? .on : .off
        autoInstall.isEnabled = configured && auto.state == .on
        let checkNow = NSButton(
            title: L("update.checkNow", "Check for Updates Now"), target: self,
            action: #selector(checkNow))
        checkNow.bezelStyle = .rounded
        updatesStatus.font = .systemFont(ofSize: 11)
        updatesStatus.textColor = .secondaryLabelColor
        updatesStatus.stringValue =
            configured
            ? L("update.viaSparkle", "Updates are delivered automatically via Sparkle.")
            : L(
                "update.sourceBuild",
                "This is a source or unsigned build. Download the latest notarized release from GitHub; those builds update themselves."
            )
        updatesStatus.lineBreakMode = .byWordWrapping
        (updatesStatus.cell as? NSTextFieldCell)?.wraps = true
        updatesStatus.preferredMaxLayoutWidth = 400
        return form([auto, autoInstall, checkNow, updatesStatus])
    }

    @objc private func autoCheckToggled(_ sender: NSButton) {
        updater?.automaticChecks = (sender.state == .on)
        // Installing without asking only applies while Sparkle is checking on its own.
        autoInstall.isEnabled = (updater?.isConfigured ?? false) && sender.state == .on
    }
    @objc private func autoInstallToggled(_ sender: NSButton) {
        updater?.automaticDownloads = (sender.state == .on)
    }
    @objc private func checkNow() { updater?.checkForUpdates(self) }

    // MARK: Debug

    /// Present the real window on screen with stub data; returns its window number so a
    /// caller can screencapture it (PATHEM_SETTINGS_SHOT). cacheDisplay can't capture
    /// non-layer AppKit controls offscreen, so this is the conclusive layout check.
    func debugPresentLive() -> Int {
        commandList = [("files.open", "Open"), ("view.toggleHidden", "Show Hidden Files")]
        effective = Keymap.defaultBindings
        gestureEffective = GestureMap.defaultBindings
        terminalThemes = ["Dark", "Light"]
        currentTerminalTheme = "Dark"
        if ProcessInfo.processInfo.environment["PATHEM_COLOR_RULES"] != nil {
            prefs.colorRules = ColorRules(rules: [
                ColorRule(
                    name: "Folders", field: .kind, op: .isAnyOf, value: "folder",
                    colorHex: "#95D5B2", bold: true),
                ColorRule(
                    name: "Images", field: .ext, op: .isAnyOf, value: "png, jpg, gif",
                    colorHex: "#8ECAE6"),
                ColorRule(
                    name: "Drafts", field: .name, op: .contains, value: "draft",
                    colorHex: "#FFB703", italic: true),
                ColorRule(
                    name: "Big files", field: .size, op: .greaterThan, value: "50",
                    colorHex: "#E76F51", bold: true),
            ])
        }
        buildChrome()
        buildAllPanesAndIndex()
        let startPane =
            ProcessInfo.processInfo.environment["PATHEM_SETTINGS_PANE"]
            .flatMap(Pane.init(rawValue:)) ?? .general
        sidebar.select(key: startPane.rawValue)
        select(startPane)
        if let query = ProcessInfo.processInfo.environment["PATHEM_SETTINGS_QUERY"], !query.isEmpty
        {
            sidebar.debugSearch(query)
        }
        window.centerOverMainWindow()
        window.makeKeyAndOrderFront(nil)
        return window.windowNumber
    }

    /// Render each pane to a PNG (run via PATHEM_PREFS_SHOT=1) for headless layout checks.
    func debugRenderPanes(toDir dir: String) {
        commandList = [
            ("files.copyToOtherPane", "Copy to Other Pane"), ("files.open", "Open"),
            ("view.toggleHidden", "Show Hidden Files"), ("palette.show", "Command Palette…"),
        ]
        effective = Keymap.defaultBindings
        gestureEffective = GestureMap.defaultBindings
        terminalThemes = ["Dark", "Light", "Solarized"]
        currentTerminalTheme = "Dark"
        // Whole-window chrome (sidebar + content) so the new layout can be inspected.
        buildChrome()
        buildAllPanesAndIndex()
        sidebar.select(key: Pane.general.rawValue)
        select(.general)
        window.setContentSize(NSSize(width: 740, height: 480))
        if let root = window.contentView {
            root.layoutSubtreeIfNeeded()
            if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(dir)/settings_window.png"))
                    print(
                        "SETTINGS WINDOW SHOT: \(Int(root.bounds.width))x\(Int(root.bounds.height))"
                    )
                }
            }
        }
        for pane in Pane.allCases {
            let view = build(pane)
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            view.frame = NSRect(
                origin: .zero,
                size: NSSize(width: max(size.width, 460), height: max(size.height, 160)))
            view.layoutSubtreeIfNeeded()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/settings_\(pane.rawValue).png"))
                print(
                    "SETTINGS SHOT: \(pane.rawValue) \(Int(view.bounds.width))x\(Int(view.bounds.height))"
                )
            }
        }
    }
}
