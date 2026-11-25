import AppKit

/// Owns the dynamic menus and their install-once lifecycle.
///
/// BrowserViewController still supplies menu actions and on-demand content, but it no longer keeps
/// five NSMenu instances plus five independent installation flags in its already-large state bag.
@MainActor
final class BrowserMenuInstaller {
    let layoutsMenu = NSMenu(title: "Layouts")
    let savedViewsMenu = NSMenu(title: "Saved Views")
    let bookmarksMenu = NSMenu(title: "Bookmarks")
    let recentFoldersMenu = NSMenu(title: "Recent Folders")
    let externalCommandsMenu = NSMenu(title: "External Commands")
    let tabGroupsMenu = NSMenu(title: "Tab Groups")

    var recentFolders: [URL] = []

    private var installedMenuIDs: Set<String> = []

    var installedMenuCount: Int { installedMenuIDs.count }

    func installBrowserMenus(delegate: NSMenuDelegate) {
        guard let mainMenu = NSApp.mainMenu else { return }
        installTopLevel(
            id: "layouts", title: L("bvc.layoutsMenu", "Layouts"), menu: layoutsMenu,
            in: mainMenu, delegate: delegate)
        installTopLevel(
            id: "savedViews", title: L("bvc.savedViewsMenu", "Saved Views"), menu: savedViewsMenu,
            in: mainMenu, delegate: delegate)
        installTopLevel(
            id: "bookmarks", title: L("bvc.bookmarksMenu", "Bookmarks"), menu: bookmarksMenu,
            in: mainMenu, delegate: delegate)
    }

    func installRecentFoldersMenu(delegate: NSMenuDelegate) {
        guard !installedMenuIDs.contains("recentFolders"), let mainMenu = NSApp.mainMenu,
            let goMenu = mainMenu.items.compactMap(\.submenu).first(where: {
                $0.title == L("menu.go", "Go")
            })
        else { return }
        recentFoldersMenu.delegate = delegate
        let item = NSMenuItem(
            title: L("menu.recentFolders", "Recent Folders"), action: nil, keyEquivalent: "")
        item.submenu = recentFoldersMenu
        goMenu.addItem(.separator())
        goMenu.addItem(item)
        installedMenuIDs.insert("recentFolders")
    }

    /// File > Tab Groups, right after Close Tab.
    func installTabGroupsMenu(delegate: NSMenuDelegate) {
        guard !installedMenuIDs.contains("tabGroups"), let mainMenu = NSApp.mainMenu,
            let fileMenu = mainMenu.items.compactMap(\.submenu).first(where: {
                $0.title == L("menu.file", "File")
            })
        else { return }
        tabGroupsMenu.delegate = delegate
        let item = NSMenuItem(
            title: L("menu.tabGroups", "Tab Groups"), action: nil, keyEquivalent: "")
        item.submenu = tabGroupsMenu
        let closeIndex = fileMenu.items.firstIndex {
            ($0.representedObject as? String) == "tab.lock"
        }
        fileMenu.insertItem(item, at: closeIndex.map { $0 + 1 } ?? fileMenu.items.count)
        installedMenuIDs.insert("tabGroups")
    }

    func installExternalCommandsMenu(delegate: NSMenuDelegate) {
        guard !installedMenuIDs.contains("externalCommands"), let mainMenu = NSApp.mainMenu,
            let toolsMenu = mainMenu.items.compactMap(\.submenu).first(where: {
                $0.title == L("menu.tools", "Tools")
            })
        else { return }
        externalCommandsMenu.delegate = delegate
        let item = NSMenuItem(
            title: L("menu.externalCommands", "External Commands"), action: nil, keyEquivalent: "")
        item.submenu = externalCommandsMenu
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(item)
        installedMenuIDs.insert("externalCommands")
    }

    private func installTopLevel(
        id: String, title: String, menu: NSMenu, in mainMenu: NSMenu, delegate: NSMenuDelegate
    ) {
        guard !installedMenuIDs.contains(id) else { return }
        let item = NSMenuItem()
        item.title = title
        item.submenu = menu
        menu.delegate = delegate
        mainMenu.addItem(item)
        installedMenuIDs.insert(id)
    }
}
