import AppKit

/// macOS Services for the file views. AppKit adds a Services submenu to a context menu when the
/// view that owns the selection answers `validRequestor(forSendType:returnType:)` for a type it
/// can write, and the app registered those send types (see `register()`). Every file view
/// (list, column, tree, icon, gallery filmstrip) routes its two requestor methods through here so
/// they cannot drift apart.
@MainActor
enum FileServices {
    /// The legacy filenames type that older services still ask for.
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    /// The pasteboard types the views can write for a selection of files.
    static let sendTypes: [NSPasteboard.PasteboardType] = [.fileURL, filenamesType]

    /// False when the user hid the "Services" entry in the right-click menu settings: the views
    /// then decline every requestor query, so AppKit adds no Services submenu.
    static var enabledInContextMenus = true

    /// Register the send types once at launch (AppKit never asks a view for file types before
    /// this) and install the application menu's Services submenu.
    static func register(servicesMenu: NSMenu) {
        NSApp.registerServicesMenuSendTypes(sendTypes, returnTypes: [])
        NSApp.servicesMenu = servicesMenu
    }

    /// Whether a view with a selection should answer for this query: a file send type and no
    /// return type (Pathem's views never accept replacement content from a service).
    static func accepts(
        sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?,
        hasSelection: Bool
    ) -> Bool {
        guard enabledInContextMenus, hasSelection, returnType == nil, let sendType else {
            return false
        }
        return sendTypes.contains(sendType)
    }

    /// Write the selected file URLs to `pasteboard` as the requested types. False when there is
    /// nothing to write or no requested type is one of ours.
    static func write(
        _ urls: [URL], to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        let wanted = types.filter { sendTypes.contains($0) }
        guard !urls.isEmpty, !wanted.isEmpty else { return false }
        // One API per pasteboard: writeObjects for the URL items (one item per file, as Finder
        // writes them), then the legacy filenames list added to the first item. Declaring types
        // first and then calling writeObjects mixes the two APIs.
        pasteboard.clearContents()
        var wrote = false
        if wanted.contains(.fileURL) {
            wrote = pasteboard.writeObjects(urls as [NSURL])
        }
        if wanted.contains(filenamesType) {
            if !wrote {
                pasteboard.declareTypes([filenamesType], owner: nil)
            } else {
                pasteboard.addTypes([filenamesType], owner: nil)
            }
            wrote = pasteboard.setPropertyList(urls.map(\.path), forType: filenamesType) || wrote
        }
        return wrote
    }
}

/// The write half of the Services requestor contract, as a main-actor protocol so the views'
/// conformance is checked at compile time and the automation harness can call it.
@MainActor @objc protocol FileServicesWriter {
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool
}
extension KeyTableView: FileServicesWriter {}
extension KeyOutlineView: FileServicesWriter {}
extension KeyCollectionView: FileServicesWriter {}
