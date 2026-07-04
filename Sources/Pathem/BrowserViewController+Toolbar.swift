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

    /// Resize the window toolbar's icon(s) to match the toolbar-icon-size preference.
    func applyToolbarIconSize() {
        guard let toolbar = view.window?.toolbar else { return }
        let config = NSImage.SymbolConfiguration(
            pointSize: prefs.toolbarIconSize.pointSize + 2, weight: .regular)
        for item in toolbar.items {
            guard let entry = Self.toolbarEntry(for: item.itemIdentifier) else { continue }
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: item.label)?
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
        .init(commandID: "files.duplicate", symbol: "plus.square.on.square", label: "Duplicate"),
        .init(commandID: "files.copy", symbol: "doc.on.doc", label: "Copy"),
        .init(commandID: "files.paste", symbol: "doc.on.clipboard", label: "Paste"),
        .init(commandID: "files.copyPath", symbol: "link", label: "Copy Path"),
        .init(commandID: "files.compress", symbol: "archivebox", label: "Compress"),
        .init(commandID: "files.trash", symbol: "trash", label: "Move to Trash"),
        .init(commandID: "files.reveal", symbol: "arrow.up.forward.square", label: "Reveal in Finder"),
        .init(commandID: "files.organize", symbol: "wand.and.stars", label: "Organize"),
        .init(commandID: "view.cleanup", symbol: "sparkles", label: "Cleanup"),
        .init(commandID: "files.repoReclaim", symbol: "internaldrive", label: "Reclaim in Repo"),
        .init(commandID: "files.findInFiles", symbol: "doc.text.magnifyingglass", label: "Find in Files"),
        .init(commandID: "files.findDuplicates", symbol: "square.on.square.dashed", label: "Find Duplicates"),
        .init(commandID: "view.quickLook", symbol: "eye", label: "Quick Look"),
        .init(commandID: "view.filter", symbol: "line.3.horizontal.decrease.circle", label: "Filter"),
        .init(commandID: "view.toggleHidden", symbol: "eye.slash", label: "Show Hidden Files"),
        .init(commandID: "view.sizeBrowser", symbol: "chart.pie", label: "Size Browser"),
        .init(commandID: "view.previewPane", symbol: "sidebar.right", label: "Preview Pane"),
        .init(commandID: "tools.transfers", symbol: "arrow.left.arrow.right", label: "Transfers"),
        .init(commandID: "terminal.toggle", symbol: "terminal", label: "Terminal"),
        .init(commandID: "git.commit", symbol: "checkmark.seal", label: "Commit"),
        .init(commandID: "palette.show", symbol: "command", label: "Command Palette"),
    ]

    static func toolbarEntry(for identifier: NSToolbarItem.Identifier) -> ToolbarEntry? {
        guard identifier.rawValue.hasPrefix(toolbarCmdPrefix) else { return nil }
        let id = String(identifier.rawValue.dropFirst(toolbarCmdPrefix.count))
        return toolbarCatalog.first { $0.commandID == id }
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
            item.view = searchField  // the on-device semantic search field
            item.label = L("bvc.searchToolbarLabel", "Search")
            item.visibilityPriority = .high
            return item
        }
        guard let entry = Self.toolbarEntry(for: identifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = L("toolbar.\(entry.commandID)", entry.label)
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.label)?
            .withSymbolConfiguration(.init(pointSize: prefs.toolbarIconSize.pointSize + 2, weight: .regular))
        item.isBordered = true
        item.target = self
        item.action = #selector(runToolbarCommand(_:))
        return item
    }

    @objc private func runToolbarCommand(_ sender: NSToolbarItem) {
        guard let entry = Self.toolbarEntry(for: sender.itemIdentifier) else { NSSound.beep(); return }
        if !commands.perform(entry.commandID) { NSSound.beep() }
    }

    /// Grey out a toolbar button when its command isn't currently applicable.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let entry = Self.toolbarEntry(for: item.itemIdentifier) else { return true }
        return commands.command(entry.commandID)?.isEnabled() ?? false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // A sensible starting arrangement; the rest live in the customization palette.
        let defaults = ["nav.back", "nav.forward", "nav.up", "files.newFolder", "files.getInfo", "view.cleanup"]
        return defaults.compactMap { id in Self.toolbarCatalog.first { $0.commandID == id } }
            .map(Self.identifier(for:)) + [.flexibleSpace, Self.searchItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarCatalog.map(Self.identifier(for:)) + [.space, .flexibleSpace, Self.searchItemID]
    }
}
