import AppKit
import PathemEngine

/// The app's Settings window: a System-Settings-style window whose toolbar switches
/// between panes. Exposes every Preferences field, a full keyboard-shortcut editor
/// (built on the engine Keymap + the command registry), and update options. Prefs
/// changes are reported live via `onChange`; shortcut changes via `onKeymapChange`
/// (a user overlay for keymap.json).
@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    enum Pane: String, CaseIterable {
        case general, appearance, layout, search, shortcuts, updates
        var title: String {
            switch self {
            case .general: return L("settings.general", "General")
            case .appearance: return L("settings.appearance", "Appearance")
            case .layout: return L("settings.layout", "Layout")
            case .search: return L("settings.search", "Search")
            case .shortcuts: return L("settings.shortcuts", "Shortcuts")
            case .updates: return L("settings.updates", "Updates")
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .layout: return "sidebar.squares.left"
            case .search: return "magnifyingglass"
            case .shortcuts: return "keyboard"
            case .updates: return "arrow.down.circle"
            }
        }
        var itemID: NSToolbarItem.Identifier { .init("settings.\(rawValue)") }
    }

    private let window: NSWindow
    private var prefs = Preferences.default
    private var onChange: ((Preferences) -> Void)?

    // Shortcut editor state.
    private var commandList: [(id: String, title: String)] = []
    private var effective: [String: String] = [:]  // chord canonical -> command id
    private var onKeymapChange: (([String: String]) -> Void)?
    private let table = NSTableView()
    private let recorder = KeyRecorderView()
    private let conflictLabel = NSTextField(labelWithString: "")
    private weak var updater: UpdaterController?
    private let updatesStatus = NSTextField(labelWithString: "")

    private var paneViews: [Pane: NSView] = [:]

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = L("settings.title", "Settings")
        window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "com.scarcrux.pathem.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        if #available(macOS 11, *) { window.toolbarStyle = .preference }
    }

    /// Show the window, populated with current state.
    func present(
        prefs: Preferences, commands: [(id: String, title: String)], effective: [String: String],
        updater: UpdaterController?, over parent: NSWindow?,
        onChange: @escaping (Preferences) -> Void,
        onKeymapChange: @escaping ([String: String]) -> Void
    ) {
        self.prefs = prefs
        self.commandList = commands
        self.effective = effective
        self.updater = updater
        self.onChange = onChange
        self.onKeymapChange = onKeymapChange
        paneViews = [:]  // rebuild with fresh state
        select(.general)
        if !window.isVisible, let parent { window.setFrameOrigin(NSPoint(x: parent.frame.midX - 240, y: parent.frame.midY - 160)) }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Pane switching

    private func select(_ pane: Pane) {
        let view = paneViews[pane] ?? {
            let built = build(pane)
            paneViews[pane] = built
            return built
        }()
        window.contentView = view
        window.toolbar?.selectedItemIdentifier = pane.itemID
        let size = view.fittingSize
        window.setContentSize(NSSize(width: max(size.width, 460), height: max(size.height, 120)))
        window.title = "\(L("settings.title", "Settings")) — \(pane.title)"
    }

    @objc private func toolbarSelected(_ sender: NSToolbarItem) {
        if let pane = Pane.allCases.first(where: { $0.itemID == sender.itemIdentifier }) { select(pane) }
    }

    private func build(_ pane: Pane) -> NSView {
        switch pane {
        case .general: return form([
            check(L("prefs.openConnectionsNewTab", "Open connections in a new tab"), \.openConnectionsInNewTab),
            check(L("prefs.calculateFolderSizes", "Calculate folder sizes"), \.calculateFolderSizes),
        ])
        case .appearance: return form([
            labeled(L("prefs.densityLabel", "Density"), densityControl()),
            labeled(L("prefs.fontSizeLabel", "Font size"), fontControl()),
            check(L("prefs.alternatingRows", "Alternating row colors"), \.alternatingRows),
        ])
        case .layout: return form([
            check(L("prefs.showFullPath", "Show full path in the title bar"), \.showFullPathInTitle),
            check(L("prefs.pathBarBottom", "Show the path bar at the bottom"), \.pathBarAtBottom),
            check(L("prefs.compactSidebar", "Compact sidebar (icons only)"), \.compactSidebar),
        ])
        case .search: return form([
            check(L("prefs.searchOCR", "Search image contents (OCR, slower)"), \.searchOCR),
            hint(L("prefs.searchOCRHint", "Text and PDF contents are always indexed; image OCR is extra.")),
        ])
        case .shortcuts: return shortcutsPane()
        case .updates: return updatesPane()
        }
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

    @objc private func checkToggled(_ sender: NSButton) {
        guard let keyPath = boolPaths[ObjectIdentifier(sender)] else { return }
        prefs[keyPath: keyPath] = (sender.state == .on)
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

    private let fontValue = NSTextField(labelWithString: "13")
    private func fontControl() -> NSView {
        let stepper = NSStepper()
        stepper.minValue = 10
        stepper.maxValue = 18
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
            column.title = id == "command" ? L("shortcuts.colCommand", "Command") : L("shortcuts.colShortcut", "Shortcut")
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
        let clear = NSButton(title: L("shortcuts.clear", "Clear"), target: self, action: #selector(clearButton))
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

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { commandList.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
        if tableColumn.identifier.rawValue == "command" {
            cell.textField?.stringValue = commandList[row].title
            cell.textField?.textColor = .labelColor
        } else {
            let shortcut = chords(for: commandList[row].id).map(ChordFormat.display).joined(separator: ", ")
            cell.textField?.stringValue = shortcut
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        recorder.canonical = selectedCommandID.flatMap { chords(for: $0).first } ?? ""
        conflictLabel.stringValue = ""
    }

    // MARK: Updates pane

    private func updatesPane() -> NSView {
        let configured = updater?.isConfigured ?? false
        let auto = NSButton(
            checkboxWithTitle: L("update.autoCheck", "Check for updates automatically"), target: self,
            action: #selector(autoCheckToggled(_:)))
        auto.state = (updater?.automaticChecks ?? false) ? .on : .off
        auto.isEnabled = configured
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
                "This is a source or unsigned build. Download the latest notarized release from GitHub; those builds update themselves.")
        updatesStatus.lineBreakMode = .byWordWrapping
        (updatesStatus.cell as? NSTextFieldCell)?.wraps = true
        updatesStatus.preferredMaxLayoutWidth = 400
        return form([auto, checkNow, updatesStatus])
    }

    @objc private func autoCheckToggled(_ sender: NSButton) { updater?.automaticChecks = (sender.state == .on) }
    @objc private func checkNow() { updater?.checkForUpdates(self) }

    // MARK: Toolbar

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = Pane.allCases.first(where: { $0.itemID == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarSelected(_:))
        return item
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.itemID)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.itemID)
    }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.itemID)
    }

    // MARK: Debug

    /// Render each pane to a PNG (run via PATHEM_PREFS_SHOT=1) for headless layout checks.
    func debugRenderPanes(toDir dir: String) {
        commandList = [
            ("files.copyToOtherPane", "Copy to Other Pane"), ("files.open", "Open"),
            ("view.toggleHidden", "Show Hidden Files"), ("palette.show", "Command Palette…"),
        ]
        effective = Keymap.defaultBindings
        for pane in Pane.allCases {
            let view = build(pane)
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            view.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, 460), height: max(size.height, 160)))
            view.layoutSubtreeIfNeeded()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/settings_\(pane.rawValue).png"))
                print("SETTINGS SHOT: \(pane.rawValue) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
            }
        }
    }
}
