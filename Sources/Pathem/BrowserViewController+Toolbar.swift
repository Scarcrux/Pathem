import AppKit
import PathemEngine

// The window toolbar: a native, user-customizable NSToolbar whose buttons all dispatch
// through the command registry. Split out of BrowserViewController to keep that file focused.
extension BrowserViewController {
    /// Put the search field in the window's unified toolbar (Finder-style), so it
    /// doesn't waste a whole strip at the top of the content.
    func installToolbarIfNeeded() {
        guard let window = view.window, window.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "com.scarcrux.pathem.toolbar")
        toolbar.delegate = self
        // Native customization: users drag items in/out and reorder via the standard
        // sheet, and NSToolbar autosaves the arrangement under the toolbar identifier.
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unified
        // No hairline under the toolbar. Our sidebar is a plain split view (not an
        // NSSplitViewController sidebar), so the automatic separator would draw straight
        // across the top of the sidebar, under the first group label ("Favorites").
        window.titlebarSeparatorStyle = .none
        window.toolbar = toolbar
    }

    /// Add the trailing "Update Ready" title-bar button once per window. It stays hidden until
    /// a Sparkle update is pending (see `UpdateButtonAccessory` / `UpdaterController`).
    func installUpdateButtonIfNeeded() {
        guard let window = view.window else { return }
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0 is UpdateButtonAccessory })
        else { return }
        window.addTitlebarAccessoryViewController(UpdateButtonAccessory(updater: updater))
    }

    /// Resize the window toolbar's icon(s) to match the toolbar-icon-size preference.
    func applyToolbarIconSize() {
        guard let toolbar = view.window?.toolbar else { return }
        let config = NSImage.SymbolConfiguration(
            pointSize: prefs.toolbarIconSize.pointSize + 2, weight: .regular)
        for item in toolbar.items {
            guard let id = Self.toolbarCommandID(item.itemIdentifier) else { continue }
            item.image = NSImage(
                systemSymbolName: Self.toolbarSymbolName(for: id), accessibilityDescription: item.label)?
                .withSymbolConfiguration(config)
        }
    }
}

extension BrowserViewController: NSToolbarDelegate {
    /// A toolbar button the user can add: a command id, an SF Symbol, and a label. The
    /// label doubles as the tooltip. Everything a customizable toolbar can offer comes
    /// from this catalog; the command's own `isEnabled` drives validation.
    struct ToolbarEntry {
        let commandID: String
        let symbol: String
        let label: String
    }

    /// The palette of buttons offered in the customization sheet, in the order they
    /// appear there. Each is backed by a registered command.
    static let toolbarCatalog: [ToolbarEntry] = [
        .init(commandID: "nav.back", symbol: "chevron.backward", label: "Back"),
        .init(commandID: "nav.forward", symbol: "chevron.forward", label: "Forward"),
        .init(commandID: "nav.up", symbol: "chevron.up", label: "Enclosing Folder"),
        .init(commandID: "files.newFolder", symbol: "folder.badge.plus", label: "New Folder"),
        .init(commandID: "files.newFile", symbol: "doc.badge.plus", label: "New File"),
        .init(commandID: "files.getInfo", symbol: "info.circle", label: "Get Info"),
        .init(commandID: "files.open", symbol: "arrow.up.forward.app", label: "Open"),
        .init(commandID: "files.rename", symbol: "pencil", label: "Rename"),
        .init(commandID: "ai.renameSelection", symbol: "wand.and.stars", label: "AI Rename"),
        .init(commandID: "ai.summarizeFolder", symbol: "text.append", label: "Summarize Folder"),
        .init(commandID: "files.duplicate", symbol: "plus.square.on.square", label: "Duplicate"),
        .init(commandID: "files.copy", symbol: "doc.on.doc", label: "Copy"),
        .init(commandID: "files.paste", symbol: "doc.on.clipboard", label: "Paste"),
        .init(commandID: "files.copyPath", symbol: "link", label: "Copy Path"),
        .init(commandID: "files.compress", symbol: "archivebox", label: "Compress"),
        .init(commandID: "files.trash", symbol: "trash", label: "Move to Trash"),
        .init(commandID: "files.reveal", symbol: "arrow.up.forward.square", label: "Reveal in Finder"),
        .init(commandID: "files.revealInPathem", symbol: "dot.viewfinder", label: "Reveal in Pathem"),
        .init(commandID: "files.organize", symbol: "wand.and.stars", label: "Organize"),
        .init(commandID: "view.cleanup", symbol: "sparkles", label: "Cleanup"),
        .init(commandID: "files.repoReclaim", symbol: "internaldrive", label: "Reclaim in Repo"),
        .init(commandID: "files.findInFiles", symbol: "doc.text.magnifyingglass", label: "Find in Files"),
        .init(commandID: "files.findDuplicates", symbol: "square.on.square.dashed", label: "Find Duplicates"),
        .init(commandID: "files.findSimilarNames", symbol: "rectangle.on.rectangle.angled", label: "Find Similar Names"),
        .init(commandID: "view.quickLook", symbol: "eye", label: "Quick Look"),
        .init(commandID: "view.slideshow", symbol: "play.rectangle", label: "Slideshow"),
        .init(commandID: "view.filter", symbol: "line.3.horizontal.decrease.circle", label: "Filter"),
        .init(commandID: "view.toggleHidden", symbol: "eye.slash", label: "Show Hidden Files"),
        .init(commandID: "view.sizeBrowser", symbol: "chart.pie", label: "Size Browser"),
        .init(commandID: "view.previewPane", symbol: "sidebar.right", label: "Preview Pane"),
        .init(commandID: "tools.transfers", symbol: "arrow.left.arrow.right", label: "Transfers"),
        .init(commandID: "tools.torrents", symbol: "arrow.down.circle", label: "Torrents"),
        .init(commandID: "terminal.toggle", symbol: "terminal", label: "Terminal"),
        .init(commandID: "git.commit", symbol: "checkmark.seal", label: "Commit"),
        .init(commandID: "palette.show", symbol: "command", label: "Command Palette"),
    ]

    static func toolbarEntry(for identifier: NSToolbarItem.Identifier) -> ToolbarEntry? {
        guard identifier.rawValue.hasPrefix(toolbarCmdPrefix) else { return nil }
        let id = String(identifier.rawValue.dropFirst(toolbarCmdPrefix.count))
        return toolbarCatalog.first { $0.commandID == id }
    }

    /// The command id an item identifier carries, or nil if it isn't a command button.
    static func toolbarCommandID(_ identifier: NSToolbarItem.Identifier) -> String? {
        guard identifier.rawValue.hasPrefix(toolbarCmdPrefix) else { return nil }
        return String(identifier.rawValue.dropFirst(toolbarCmdPrefix.count))
    }

    /// The SF Symbol for a command button: the curated catalog symbol, a bolt for a
    /// user-defined external command, or a generic command glyph for anything else.
    static func toolbarSymbolName(for commandID: String) -> String {
        if let entry = toolbarCatalog.first(where: { $0.commandID == commandID }) { return entry.symbol }
        if commandID.hasPrefix("external.cmd.") { return "bolt.fill" }
        return "command.square"
    }

    private static func identifier(for entry: ToolbarEntry) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(toolbarCmdPrefix + entry.commandID)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if identifier == Self.searchItemID {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = searchButton  // opens the search-and-command overlay (Cmd-F / Cmd-K)
            item.label = L("bvc.searchToolbarLabel", "Search")
            item.visibilityPriority = .high
            return item
        }
        if identifier == Self.overflowItemID {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = L("overflow.label", "Options")
            item.toolTip = L("overflow.tooltip", "Options and theme")
            item.image = NSImage(
                systemSymbolName: "ellipsis.circle", accessibilityDescription: L("overflow.label", "Options"))?
                .withSymbolConfiguration(.init(pointSize: prefs.toolbarIconSize.pointSize + 2, weight: .regular))
            item.showsIndicator = false
            let menu = NSMenu()
            menu.delegate = overflowMenuDelegate  // repopulated on open, so checkmarks stay fresh
            item.menu = menu
            return item
        }
        // A command button: the curated catalog entry, or any other registered command
        // (external commands included) resolved dynamically -- so anything can go on the toolbar.
        guard let commandID = Self.toolbarCommandID(identifier) else { return nil }
        let entry = Self.toolbarCatalog.first { $0.commandID == commandID }
        guard entry != nil || commands.command(commandID) != nil else { return nil }
        let label = entry.map { L("toolbar.\($0.commandID)", $0.label) } ?? (commands.command(commandID)?.title ?? commandID)
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label
        item.image = NSImage(
            systemSymbolName: Self.toolbarSymbolName(for: commandID), accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: prefs.toolbarIconSize.pointSize + 2, weight: .regular))
        item.isBordered = true
        item.target = self
        item.action = #selector(runToolbarCommand(_:))
        return item
    }

    @objc private func runToolbarCommand(_ sender: NSToolbarItem) {
        guard let id = Self.toolbarCommandID(sender.itemIdentifier) else { NSSound.beep(); return }
        if !commands.perform(id) { NSSound.beep() }
    }

    /// Grey out a toolbar button when its command isn't currently applicable.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let id = Self.toolbarCommandID(item.itemIdentifier) else { return true }
        return commands.command(id)?.isEnabled() ?? true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // A sensible starting arrangement; the rest live in the customization palette.
        let defaults = ["nav.back", "nav.forward", "nav.up", "files.newFolder", "files.getInfo", "view.cleanup"]
        return defaults.compactMap { id in Self.toolbarCatalog.first { $0.commandID == id } }
            .map(Self.identifier(for:)) + [.flexibleSpace, Self.searchItemID, Self.overflowItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The curated catalog first, then user external commands, then every other registered
        // command -- so the customization palette can put anything on the toolbar.
        let catalog = Self.toolbarCatalog.map(\.commandID)
        let known = Set(catalog)
        let others = commands.all.map(\.id).filter { !known.contains($0) }
        let external = others.filter { $0.hasPrefix("external.cmd.") }.sorted()
        let rest = others.filter { !$0.hasPrefix("external.cmd.") }.sorted()
        let ids = catalog + external + rest
        return ids.map { NSToolbarItem.Identifier(Self.toolbarCmdPrefix + $0) }
            + [.space, .flexibleSpace, Self.searchItemID, Self.overflowItemID]
    }
}
