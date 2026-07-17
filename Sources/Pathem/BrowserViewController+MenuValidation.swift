import AppKit
import PathemEngine

// NSMenu integration: route a clicked menu item to its registry command, and validate each
// item's enabled state / dynamic title (undo/redo names, checkmarks, column toggles). Split
// out of BrowserViewController.
@MainActor
extension BrowserViewController {
    /// Run a registry command from a menu item carrying its id in representedObject.
    @objc func performMenuCommand(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { commands.perform(id) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTerminalTheme(_:)) {
            menuItem.state = (menuItem.representedObject as? String == terminal.theme.name) ? .on : .off
            return true
        }
        // The Edit menu's Undo/Redo reflect the file-op history -- unless a text field is being
        // edited, in which case its own field-editor undo drives them.
        if menuItem.action == Selector(("undo:")) {
            if isEditingText { menuItem.title = L("menu.undo", "Undo"); return view.window?.undoManager?.canUndo ?? false }
            menuItem.title = actionHistory.undoActionName.map { String(format: L("menu.undoNamed", "Undo %@"), $0) } ?? L("menu.undo", "Undo")
            return actionHistory.canUndo
        }
        if menuItem.action == Selector(("redo:")) {
            if isEditingText { menuItem.title = L("menu.redo", "Redo"); return view.window?.undoManager?.canRedo ?? false }
            menuItem.title = actionHistory.redoActionName.map { String(format: L("menu.redoNamed", "Redo %@"), $0) } ?? L("menu.redo", "Redo")
            return actionHistory.canRedo
        }
        guard menuItem.action == #selector(performMenuCommand(_:)),
            let id = menuItem.representedObject as? String
        else { return true }
        if id == "terminal.toggleFollow" { menuItem.state = terminalFollows ? .on : .off }
        switch id {
        case "view.asList": menuItem.state = activePane?.viewMode == .list ? .on : .off
        case "view.asIcons": menuItem.state = activePane?.viewMode == .icon ? .on : .off
        case "view.asGallery": menuItem.state = activePane?.viewMode == .gallery ? .on : .off
        case "view.asColumn": menuItem.state = activePane?.viewMode == .column ? .on : .off
        case "view.asTree": menuItem.state = activePane?.viewMode == .tree ? .on : .off
        case "nav.vimMode": menuItem.state = vimMode ? .on : .off
        case "view.arrangeNone": menuItem.state = (activePane?.groupKey ?? .none) == .none ? .on : .off
        case "view.arrangeKind": menuItem.state = activePane?.groupKey == .kind ? .on : .off
        case "view.arrangeSize": menuItem.state = activePane?.groupKey == .size ? .on : .off
        case "view.arrangeDate": menuItem.state = activePane?.groupKey == .dateModified ? .on : .off
        case "view.arrangeTag": menuItem.state = activePane?.groupKey == .tag ? .on : .off
        case "view.fullPathTitle": menuItem.state = prefs.showFullPathInTitle ? .on : .off
        case "view.pathBarBottom": menuItem.state = prefs.pathBarAtBottom ? .on : .off
        case "view.demoMode": menuItem.state = isDemoMode ? .on : .off
        case "view.calculateSizes": menuItem.state = prefs.calculateFolderSizes ? .on : .off
        case "view.syncBrowsing": menuItem.state = syncBrowsing ? .on : .off
        case "view.compactSidebar": menuItem.state = prefs.compactSidebar ? .on : .off
        case "view.previewPane": menuItem.state = previewVisible ? .on : .off
        case "shelf.toggle":
            menuItem.state = shelf.view.isHidden ? .off : .on
            menuItem.title = shelf.view.isHidden ? L("bvc.showShelf", "Show Shelf") : L("bvc.hideShelf", "Hide Shelf")
        case "connections.newTabToggle": menuItem.state = prefs.openConnectionsInNewTab ? .on : .off
        case "files.newFolderWithSelection":
            menuItem.title = FileContextMenuController.newFolderWithSelectionTitle(
                count: activePane?.selectedEntries.count ?? 0)
        default: break
        }
        return commands.command(id)?.isEnabled() ?? true
    }

    // MARK: - Preferences

    static var preferencesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("prefs.json")
    }
}
