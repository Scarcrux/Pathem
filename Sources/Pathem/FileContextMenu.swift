import AppKit
import PathemEngine

/// The single file/selection context menu, shared by every pane view (list, icon, gallery,
/// column) so the four can never drift apart. Add an item here once and it appears in all of
/// them. Each view owns an instance, points `selectedURLs` at its own selection, and assigns
/// `menu` to its table/collection. The standard items act through the responder chain
/// (`BrowserViewController.performMenuCommand`); only the live "Open With" apps target this
/// controller, which the owning view keeps alive.
@MainActor
final class FileContextMenuController: NSObject, NSMenuDelegate {
    /// Command ids the user hid in Settings; rebuilds the menu when it changes.
    var hiddenItems: Set<String> = [] {
        didSet { if oldValue != hiddenItems { rebuild() } }
    }
    /// The current selection as file URLs (location-aware). Set by the owning view.
    var selectedURLs: () -> [URL] = { [] }

    /// The shared context menu; assign to a view's `menu`.
    let menu = NSMenu()
    private let openWithMenu = NSMenu()

    /// Extract items appear only when the selection holds an extractable archive; this tags
    /// their separator so it hides with them.
    private static let archiveSeparatorTag = 7701
    private static let archiveCommandIDs: Set<String> = [
        "files.extract", "files.extractHere", "files.extractTo",
    ]

    /// The New Folder with Selection title, pluralized with the live selection count (Finder
    /// shows "(3 Items)"). Shared by the context menu and the File menu.
    static func newFolderWithSelectionTitle(count: Int) -> String {
        switch count {
        case 0: return L("bvc.newFolderWithSelectionAction", "New Folder with Selection")
        case 1: return L("cmenu.nfws.one", "New Folder with Selection (1 Item)")
        default: return String(format: L("cmenu.nfws.many", "New Folder with Selection (%d Items)"), count)
        }
    }

    /// The flat list of hideable commands, used by the Settings toggles and the smoke-test
    /// icon check. The single source of truth for what the menu can contain.
    static let hideableCommands: [(id: String, title: String)] = [
        ("files.open", L("common.open", "Open")),
        ("files.getInfo", L("list.getInfo", "Get Info")),
        ("files.download", L("list.download", "Download")),
        ("files.reveal", L("list.revealInFinder", "Reveal in Finder")),
        ("files.revealInPathem", L("list.revealInPathem", "Reveal in Pathem")),
        ("files.rename", L("list.rename", "Rename…")),
        ("files.trash", L("list.moveToTrash", "Move to Trash")),
        ("files.newFolder", L("list.newFolder", "New Folder")),
        ("files.newFolderWithSelection", L("bvc.newFolderWithSelectionAction", "New Folder with Selection")),
        ("files.newFile", L("bvc.cmd.newFile", "New File")),
        ("files.copy", L("list.copy", "Copy")),
        ("files.cut", L("list.cut", "Cut")),
        ("files.paste", L("list.paste", "Paste")),
        ("files.extract", L("bvc.cmd.extract", "Extract")),
        ("files.extractHere", L("bvc.cmd.extractHere", "Extract Here")),
        ("files.extractTo", L("bvc.cmd.extractTo", "Extract to Folder…")),
    ]

    override init() {
        super.init()
        menu.delegate = self
        openWithMenu.delegate = self
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        let titles = Dictionary(uniqueKeysWithValues: Self.hideableCommands.map { ($0.id, $0.title) })
        func add(_ id: String) {
            guard !hiddenItems.contains(id), let title = titles[id] else { return }
            let item = NSMenuItem(
                title: title, action: #selector(BrowserViewController.performMenuCommand(_:)), keyEquivalent: "")
            item.representedObject = id
            item.image = MenuIcons.image(forCommand: id)
            menu.addItem(item)
        }
        add("files.open")
        // Open With: a submenu populated live in menuNeedsUpdate with the apps for the selection.
        let openWith = NSMenuItem(title: L("list.openWith", "Open With"), action: nil, keyEquivalent: "")
        openWith.image = MenuIcons.image("app.dashed")
        openWith.submenu = openWithMenu
        menu.addItem(openWith)
        add("files.getInfo")
        add("files.download")
        add("files.reveal")
        add("files.revealInPathem")
        add("files.rename")
        add("files.trash")
        menu.addItem(.separator())
        menu.addItem(makeTagsItem())
        menu.addItem(.separator())
        add("files.newFolder")
        add("files.newFolderWithSelection")
        add("files.newFile")
        menu.addItem(.separator())
        add("files.copy")
        add("files.cut")
        add("files.paste")
        // Archive actions: always added, but the separator + items stay hidden unless an
        // archive is selected (toggled in menuNeedsUpdate).
        let archiveSep = NSMenuItem.separator()
        archiveSep.tag = Self.archiveSeparatorTag
        menu.addItem(archiveSep)
        add("files.extract")
        add("files.extractHere")
        add("files.extractTo")
    }

    private func makeTagsItem() -> NSMenuItem {
        let tags = NSMenuItem(title: L("list.tags", "Tags"), action: nil, keyEquivalent: "")
        tags.image = MenuIcons.image("tag")
        let tagsMenu = NSMenu()
        for color in FileTag.Color.displayOrder {
            let item = NSMenuItem(
                title: color.label, action: #selector(BrowserViewController.performMenuCommand(_:)),
                keyEquivalent: "")
            item.representedObject = "tags.toggle.\(color.rawValue)"
            item.image = TagColors.dot(color)
            tagsMenu.addItem(item)
        }
        tagsMenu.addItem(.separator())
        let clear = NSMenuItem(
            title: L("list.clearTags", "Clear Tags"),
            action: #selector(BrowserViewController.performMenuCommand(_:)), keyEquivalent: "")
        clear.representedObject = "tags.clear"
        tagsMenu.addItem(clear)
        tags.submenu = tagsMenu
        return tags
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            // Right-click already moved the selection to the clicked item, so this is current.
            let urls = selectedURLs()
            let showArchive = urls.contains { Archiver.canExtract($0) }
            for item in menu.items {
                if let id = item.representedObject as? String {
                    if Self.archiveCommandIDs.contains(id) {
                        item.isHidden = !showArchive
                    } else if id == "files.newFolderWithSelection" {
                        // Only meaningful with a selection; show a live count when there is one.
                        item.isHidden = urls.isEmpty
                        item.title = Self.newFolderWithSelectionTitle(count: urls.count)
                    }
                } else if item.isSeparatorItem, item.tag == Self.archiveSeparatorTag {
                    item.isHidden = !showArchive
                }
            }
            return
        }
        guard menu === openWithMenu else { return }
        populateOpenWith(menu)
    }

    /// Fill the Open With submenu with the apps that can open the selection (default first),
    /// plus "Other…" and "Always Open With…".
    private func populateOpenWith(_ menu: NSMenu) {
        menu.removeAllItems()
        func disabled(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        guard let first = selectedURLs().first else { disabled(L("list.noSelection", "No selection")); return }
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: first),
            let index = apps.firstIndex(of: preferred)
        {
            apps.remove(at: index)
            apps.insert(preferred, at: 0)
        }
        guard !apps.isEmpty else { disabled(L("list.noApplications", "No applications")); return }
        for app in apps {
            let item = NSMenuItem(
                title: FileManager.default.displayName(atPath: app.path),
                action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            // Copy before resizing: mutating the shared cached icon corrupts it process-wide.
            let icon = (NSWorkspace.shared.icon(forFile: app.path).copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(
            title: L("list.other", "Other…"), action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        // Setting a persistent/scoped default is owned by BrowserViewController (opener rules),
        // reached through the responder chain.
        let setDefault = NSMenuItem(
            title: L("list.alwaysOpenWith", "Always Open With…"),
            action: #selector(BrowserViewController.setDefaultOpener(_:)), keyEquivalent: "")
        menu.addItem(setDefault)
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openWithOther(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let app = panel.url else { return }
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
