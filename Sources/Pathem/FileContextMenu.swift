import AppKit
import PathemEngine
import UniformTypeIdentifiers

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
    /// The user's saved entry order (command ids + "@openWith"/"@tags"); empty = default.
    var menuOrder: [String] = [] {
        didSet { if oldValue != menuOrder { rebuild() } }
    }
    /// The current selection as file URLs (location-aware). Set by the owning view.
    var selectedURLs: () -> [URL] = { [] }
    /// The pane's current folder, so folder-scoped actions (Empty Trash) can show with nothing
    /// selected. Set by the owning view.
    var currentFolder: () -> URL? = { nil }

    /// The shared context menu; assign to a view's `menu`.
    let menu = NSMenu()
    private let openWithMenu = NSMenu()

    private static let archiveCommandIDs: Set<String> = [
        "files.extract", "files.extractHere", "files.extractTo",
    ]

    /// The default order of the menu's entries: command ids plus the two submenu tokens.
    /// Separators aren't listed; they're auto-inserted between groups (see `group`).
    static let defaultEntries: [String] = [
        "files.open", "files.openInNewTab", "files.openInThisPane", "files.openInOtherPane", "@openWith",
        "files.trash", "files.putBack", "files.deleteImmediately", "files.emptyTrash",  // near the top, set apart, like Finder
        "files.getInfo", "files.share", "files.download", "files.reveal", "files.revealInPathem",
        "files.setDesktopPicture", "files.rename",
        "@tags",
        "files.newFolder", "files.newFolderWithSelection", "files.newFile",
        "files.copy", "files.copyPath", "files.copyName", "files.cut", "files.paste",
        "files.extract", "files.extractHere", "files.extractTo",
        "files.createTorrent", "files.addToTorrents", "files.copyMagnetLink",
    ]

    /// The group an entry belongs to. A separator is auto-inserted wherever the group changes
    /// between two visible entries, so reordering keeps sensible dividers with no manual
    /// separator management.
    private static func group(_ token: String) -> Int {
        switch token {
        case "files.trash", "files.putBack", "files.deleteImmediately", "files.emptyTrash":
            return 5  // set apart, like Finder
        case "@tags": return 1
        case "files.newFolder", "files.newFolderWithSelection", "files.newFile": return 2
        case "files.copy", "files.copyPath", "files.copyName", "files.cut", "files.paste": return 3
        case "files.extract", "files.extractHere", "files.extractTo": return 4
        case "files.createTorrent", "files.addToTorrents", "files.copyMagnetLink": return 6  // torrent actions
        default: return 0  // open / info / rename actions
        }
    }

    /// The display title for any entry token (a command or a submenu), for the editor.
    static func title(for token: String) -> String {
        switch token {
        case "@openWith": return L("list.openWith", "Open With")
        case "@tags": return L("list.tags", "Tags")
        default:
            return Dictionary(uniqueKeysWithValues: hideableCommands.map { ($0.id, $0.title) })[token]
                ?? token
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
    private static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) ?? false
    }
    private static let trashDir =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").standardizedFileURL.path
    private static let trashPrefix = trashDir + "/"
    private static func isInTrash(_ url: URL) -> Bool { url.path.hasPrefix(trashPrefix) }
    /// True when `url` is the Trash folder itself (so Empty Trash can show on its background).
    static func isTrashFolder(_ url: URL?) -> Bool { url?.standardizedFileURL.path == trashDir }

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
        ("files.openInNewTab", L("bvc.cmd.openInNewTab", "Open in New Tab")),
        ("files.openInThisPane", L("bvc.cmd.openInThisPane", "Open in This Pane")),
        ("files.openInOtherPane", L("bvc.cmd.openInOtherPane", "Open in Other Pane")),
        ("files.getInfo", L("list.getInfo", "Get Info")),
        ("files.download", L("list.download", "Download")),
        ("files.share", L("list.share", "Share…")),
        ("files.reveal", L("list.revealInFinder", "Reveal in Finder")),
        ("files.revealInPathem", L("list.revealInPathem", "Reveal in Pathem")),
        ("files.setDesktopPicture", L("bvc.cmd.setDesktopPicture", "Set Desktop Picture")),
        ("files.rename", L("list.rename", "Rename…")),
        ("files.trash", L("list.moveToTrash", "Move to Trash")),
        ("files.putBack", L("bvc.cmd.putBack", "Put Back")),
        ("files.deleteImmediately", L("bvc.cmd.deleteImmediately", "Delete Immediately")),
        ("files.emptyTrash", L("bvc.cmd.emptyTrash", "Empty Trash")),
        ("files.newFolder", L("list.newFolder", "New Folder")),
        ("files.newFolderWithSelection", L("bvc.newFolderWithSelectionAction", "New Folder with Selection")),
        ("files.newFile", L("bvc.cmd.newFile", "New File")),
        ("files.copy", L("list.copy", "Copy")),
        ("files.copyPath", L("bvc.cmd.copyPath", "Copy Path")),
        ("files.copyName", L("bvc.cmd.copyName", "Copy Name")),
        ("files.cut", L("list.cut", "Cut")),
        ("files.paste", L("list.paste", "Paste")),
        ("files.extract", L("bvc.cmd.extract", "Extract")),
        ("files.extractHere", L("bvc.cmd.extractHere", "Extract Here")),
        ("files.extractTo", L("bvc.cmd.extractTo", "Extract to Folder…")),
        ("files.createTorrent", L("bvc.cmd.createTorrent", "Create Torrent…")),
        ("files.addToTorrents", L("bvc.cmd.addToTorrents", "Add to Torrents")),
        ("files.copyMagnetLink", L("bvc.cmd.copyMagnetLink", "Copy Magnet Link")),
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
        var lastGroup: Int?
        for token in ContextMenuLayout.ordered(default: Self.defaultEntries, user: menuOrder) {
            if hiddenItems.contains(token) { continue }  // user hid this entry
            let g = Self.group(token)
            if let lastGroup, lastGroup != g { menu.addItem(.separator()) }  // divide groups
            switch token {
            case "@openWith":
                // A submenu populated live in menuNeedsUpdate with the apps for the selection.
                let openWith = NSMenuItem(title: L("list.openWith", "Open With"), action: nil, keyEquivalent: "")
                openWith.image = MenuIcons.image("app.dashed")
                openWith.submenu = openWithMenu
                menu.addItem(openWith)
            case "@tags":
                menu.addItem(makeTagsItem())
            default:
                guard let title = titles[token] else { continue }  // unknown id: skip
                let item = NSMenuItem(
                    title: title, action: #selector(BrowserViewController.performMenuCommand(_:)),
                    keyEquivalent: "")
                item.representedObject = token
                item.image = MenuIcons.image(forCommand: token)
                menu.addItem(item)
            }
            lastGroup = g
        }
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
            let count = urls.count
            // The per-URL flag scans (some stat the file, e.g. isInTrash) are bounded to a sample
            // so right-clicking a 100k-item selection doesn't hang the menu; the archive/trash/
            // torrent actions tolerate a mixed selection past the sample.
            let sample = urls.prefix(2000)
            let showArchive = sample.contains { Archiver.canExtract($0) }
            let singleFolder = count == 1 && Self.isDirectory(urls[0])
            let inTrash = !urls.isEmpty && sample.allSatisfy { Self.isInTrash($0) }
            let allTorrents = !urls.isEmpty && sample.allSatisfy { $0.pathExtension.lowercased() == "torrent" }
            for item in menu.items {
                guard let id = item.representedObject as? String else { continue }
                switch id {
                case _ where Self.archiveCommandIDs.contains(id):
                    item.isHidden = !showArchive
                case "files.newFolderWithSelection":
                    // Only meaningful with a selection; show a live count when there is one.
                    item.isHidden = urls.isEmpty
                    item.title = Self.newFolderWithSelectionTitle(count: urls.count)
                case "files.openInNewTab":
                    item.isHidden = !singleFolder
                case "files.openInThisPane":
                    // A PDF/image to view in the current pane (a folder just opens); single selection.
                    item.isHidden = !(count == 1 && DocumentPreviewView.isViewable(urls[0]))
                case "files.openInOtherPane":
                    // A folder (browse there) or a PDF/image (view in place); single selection only.
                    item.isHidden = !(count == 1 && (singleFolder || DocumentPreviewView.isViewable(urls[0])))
                case "files.share":
                    item.isHidden = urls.isEmpty
                case "files.setDesktopPicture":
                    item.isHidden = !(urls.count == 1 && Self.isImage(urls[0]))
                case "files.putBack", "files.deleteImmediately":
                    item.isHidden = !inTrash  // act on the trashed selection
                case "files.emptyTrash":
                    // Empties the whole Trash, not a selection: show it whenever this pane is the
                    // Trash, even with nothing selected (Finder's background-menu gesture).
                    item.isHidden = !(inTrash || Self.isTrashFolder(self.currentFolder()))
                case "files.addToTorrents", "files.copyMagnetLink":
                    item.isHidden = !allTorrents  // only for .torrent selections
                case "files.createTorrent":
                    item.isHidden = urls.count != 1  // make a torrent from one file/folder
                case "files.revealInPathem":
                    // Only meaningful when the selection lives outside the folder on screen (search,
                    // smart folders, flat view, recents). In a normal listing you're already in its
                    // folder, so revealing in place is a no-op -- hide it there.
                    let here = self.currentFolder()?.standardizedFileURL
                    item.isHidden =
                        urls.isEmpty
                        || (here != nil
                            && urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == here })
                default:
                    break
                }
            }
            Self.tidySeparators(menu)  // hide dividers left dangling by the hides above
            return
        }
        guard menu === openWithMenu else { return }
        populateOpenWith(menu)
    }

    /// Hide separators that are leading, trailing, or adjacent to another separator once the
    /// conditional items above are hidden, so the menu never shows a dangling or doubled
    /// divider (e.g. the archive divider when nothing extractable is selected).
    private static func tidySeparators(_ menu: NSMenu) {
        var pending: NSMenuItem?  // a separator with a visible item before it, awaiting one after
        var sawVisibleSinceSeparator = false
        for item in menu.items {
            if item.isSeparatorItem {
                item.isHidden = true  // hidden until a following visible item justifies it
                pending = sawVisibleSinceSeparator ? item : pending
                sawVisibleSinceSeparator = false
            } else if !item.isHidden {
                pending?.isHidden = false  // a visible item follows: keep the pending divider
                pending = nil
                sawVisibleSinceSeparator = true
            }
        }
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
        // LaunchServices hands these back in an arbitrary order, so an app that only claims a
        // catch-all (Adobe Illustrator for a .txt) can sit near the top. Rank by how well each app
        // actually fits the file's type -- exact-type claims above broad ones -- with the OS default
        // pinned first. See OpenWithRanker.
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: first)
        let apps = OpenWithRanker.ranked(
            apps: NSWorkspace.shared.urlsForApplications(toOpen: first), for: first, defaultApp: preferred)
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
