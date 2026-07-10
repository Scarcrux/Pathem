import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// Load collections and register each as a "Collection: <name>" command that
    /// shows its (still-existing) files as a cross-folder smart list.
    func loadCollections() {
        collectionsStore = loadConfig(Collections.self, from: Self.collectionsConfigURL) ?? Collections()
        for name in collectionsStore.names { registerCollectionCommand(name) }
    }

    private func registerCollectionCommand(_ name: String) {
        commands.register(
            .init(
                id: "collection.\(name)", title: String(format: L("bvc.collectionCmdTitle", "Collection: %@"), name), isEnabled: { true },
                run: { [weak self] in self?.showCollection(name) }))
    }

    private func showCollection(_ name: String) {
        guard let pane = activePane, !pane.isRemote,
            let paths = collectionsStore.collection(named: name)?.paths
        else { NSSound.beep(); return }
        let token = pane.beginContentRequest()
        pane.showSmartResults([], title: String(format: L("bvc.collectionLoading", "Collection: %@…"), name))
        Task { @MainActor in
            let entries = await Task.detached { () -> [FileEntry] in
                paths.filter { FileManager.default.fileExists(atPath: $0) }
                    .map { FileEntry(contentsOf: URL(fileURLWithPath: $0)) }
            }.value
            guard self.activePane === pane, pane.isContentRequestCurrent(token) else { return }
            pane.showSmartResults(entries, title: String(format: L("bvc.collectionCount", "Collection: %@ (%d)"), name, entries.count))
        }
    }

    /// Add the selection to a collection (prompting for / creating the name).
    func addToCollection() {
        guard let urls = activePane?.selectedLocalURLs(), !urls.isEmpty else { NSSound.beep(); return }
        Task { @MainActor in
            guard let name = await self.promptForName(title: L("bvc.addToCollectionPrompt", "Add to Collection"), default: L("bvc.collectionDefaultName", "Collection")) else { return }
            let isNew = self.collectionsStore.collection(named: name) == nil
            self.collectionsStore.add(urls.map(\.path), to: name)
            self.saveConfig(self.collectionsStore, to: Self.collectionsConfigURL)
            if isNew { self.registerCollectionCommand(name) }
        }
    }

    func loadSavedSearches() {
        savedSearches = loadConfig(SavedSearches.self, from: Self.savedSearchesURL) ?? SavedSearches.default
        registerSavedSearchCommands()
    }
    private func registerSavedSearchCommands() {
        for command in commands.all where command.id.hasPrefix("search.") { commands.unregister(command.id) }
        for search in savedSearches.searches where !search.name.isEmpty {
            let query = search.mdfindQuery()
            guard !query.isEmpty else { continue }
            let name = search.name
            commands.register(
                .init(
                    id: "search.\(name)", title: String(format: L("bvc.searchCmdTitle", "Search: %@"), name), isEnabled: { true },
                    run: { [weak self] in self?.runSavedSearch(name, query: query) }))
        }
    }
    /// Persist a smart folder (replacing any with the same name) and re-register the commands.
    private func saveSmartFolder(_ search: SavedSearch) {
        savedSearches.searches.removeAll { $0.name == search.name }
        savedSearches.searches.append(search)
        saveConfig(savedSearches, to: Self.savedSearchesURL)
        registerSavedSearchCommands()
        sidebar.savedSearches = savedSearches.searches  // reflect it in the sidebar section
    }

    /// Advanced Find: a builder over Spotlight (name / extension / kind / content / tag / size /
    /// date). Search shows results in the active pane; Save persists a reusable smart folder.
    func showAdvancedFind() {
        guard let window = view.window, let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        func field(_ placeholder: String) -> NSTextField {
            let f = NSTextField()
            f.placeholderString = placeholder
            f.widthAnchor.constraint(equalToConstant: 240).isActive = true
            return f
        }
        func labeled(_ title: String, _ control: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }
        let name = field(L("find.namePh", "contains…"))
        let ext = field(L("find.extPh", "e.g. pdf"))
        let content = field(L("find.contentPh", "text inside the file"))
        let tag = field(L("find.tagPh", "Finder tag"))
        let minSize = field(L("find.sizePh", "MB"))
        let days = field(L("find.daysPh", "days"))
        let kind = NSPopUpButton()
        kind.addItems(withTitles: [
            L("find.kindAny", "Any"), L("find.kindImages", "Images"), L("find.kindPDF", "PDF"),
            L("find.kindDocs", "Documents"), L("find.kindAudio", "Audio"), L("find.kindVideo", "Video"),
            L("find.kindFolders", "Folders"),
        ])
        let kindUTIs: [String?] = [nil, "public.image", "com.adobe.pdf", "public.content", "public.audio", "public.movie", "public.folder"]
        let rows = NSStackView(views: [
            labeled(L("find.nameLabel", "Name"), name), labeled(L("find.extLabel", "Extension"), ext),
            labeled(L("find.kindLabel", "Kind"), kind), labeled(L("find.contentLabel", "Content"), content),
            labeled(L("find.tagLabel", "Tag"), tag), labeled(L("find.sizeLabel", "Min size (MB)"), minSize),
            labeled(L("find.daysLabel", "Modified within"), days),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.frame = NSRect(x: 0, y: 0, width: 380, height: 250)

        func criteria(named: String) -> SavedSearch {
            func nz(_ f: NSTextField) -> String? {
                let v = f.stringValue.trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            return SavedSearch(
                name: named, nameContains: nz(name), fileExtension: nz(ext),
                minSizeBytes: nz(minSize).flatMap { Double($0) }.map { Int64($0 * 1_000_000) },
                modifiedWithinDays: nz(days).flatMap { Int($0) },
                contentType: kindUTIs[kind.indexOfSelectedItem],
                contentContains: nz(content), tag: nz(tag))
        }

        let alert = NSAlert()
        alert.messageText = L("find.title", "Advanced Find")
        alert.informativeText = L("find.info", "Find files across your Mac by any combination of criteria (Spotlight).")
        alert.accessoryView = rows
        alert.addButton(withTitle: L("find.search", "Search"))
        alert.addButton(withTitle: L("find.save", "Save as Smart Folder…"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                let search = criteria(named: L("find.resultsName", "Find Results"))
                guard !search.mdfindQuery().isEmpty else { NSSound.beep(); return }
                self.runSavedSearch(search.name, query: search.mdfindQuery())
            case .alertSecondButtonReturn:
                Task { @MainActor in
                    guard let chosen = await self.promptForName(
                        title: L("find.saveTitle", "Save Smart Folder"), default: L("find.saveDefault", "My Search"))
                    else { return }
                    let search = criteria(named: chosen)
                    guard !search.mdfindQuery().isEmpty else { NSSound.beep(); return }
                    self.saveSmartFolder(search)
                    self.runSavedSearch(search.name, query: search.mdfindQuery())
                }
            default:
                break
            }
        }
    }
}
