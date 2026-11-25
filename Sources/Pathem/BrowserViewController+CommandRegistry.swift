import AppKit
import NetFS
import PathemEngine
import PathemTerminal
import TorrentKit
import UniformTypeIdentifiers

// The command-registry setup: every browser action is registered here as a named command
// (id, title, enablement, handler). Split out of BrowserViewController -- it was a single
// 520-line method -- so the core file holds state and wiring, not the whole command catalog.
@MainActor
extension BrowserViewController {
    func registerCommands() {
        func add(
            _ id: String, _ title: String, keywords: [String] = [],
            enabled: @escaping () -> Bool = { true }, _ run: @escaping () -> Void
        ) {
            commands.register(
                .init(id: id, title: title, keywords: keywords, isEnabled: enabled, run: run))
        }
        let hasSelection: () -> Bool = { [weak self] in
            self?.activePane?.selectedEntries.isEmpty == false
        }
        let taggableSelection: () -> Bool = { [weak self] in self?.canTagSelection ?? false }
        let canArrange: () -> Bool = { [weak self] in self?.activePane?.supportsGrouping ?? false }
        add(
            "files.copyToOtherPane", L("bvc.cmd.copyToOtherPane", "Copy to Other Pane"),
            enabled: hasSelection
        ) {
            [weak self] in self?.transfer(move: false)
        }
        add(
            "files.moveToOtherPane", L("bvc.cmd.moveToOtherPane", "Move to Other Pane"),
            enabled: hasSelection
        ) {
            [weak self] in self?.transfer(move: true)
        }
        add(
            "files.openInThisPane", L("bvc.cmd.openInThisPane", "Open in This Pane"),
            enabled: { [weak self] in self?.openInThisPaneTarget() != nil }
        ) { [weak self] in self?.openInThisPane() }
        add(
            "files.openInOtherPane", L("bvc.cmd.openInOtherPane", "Open in Other Pane"),
            enabled: { [weak self] in self?.openInOtherPaneTarget() != nil }
        ) { [weak self] in self?.openInOtherPane() }
        add("files.copyTo", L("bvc.cmd.copyTo", "Copy To…"), enabled: hasSelection) {
            [weak self] in self?.copyOrMoveTo(move: false)
        }
        add("files.moveTo", L("bvc.cmd.moveTo", "Move To…"), enabled: hasSelection) {
            [weak self] in self?.copyOrMoveTo(move: true)
        }
        add("files.copy", L("bvc.cmd.copy", "Copy"), enabled: hasSelection) {
            [weak self] in self?.writeSelectionToPasteboard(cut: false)
        }
        add("files.cut", L("bvc.cmd.cut", "Cut"), enabled: hasSelection) {
            [weak self] in self?.writeSelectionToPasteboard(cut: true)
        }
        add("view.clipboard", L("bvc.cmd.showClipboard", "Show Clipboard…")) { [weak self] in
            self?.showClipboard()
        }
        add("view.asList", L("bvc.cmd.asList", "as List")) { [weak self] in
            self?.setActiveViewMode(.list)
        }
        add("view.asIcons", L("bvc.cmd.asIcons", "as Icons")) { [weak self] in
            self?.setActiveViewMode(.icon)
        }
        add("view.asGallery", L("bvc.cmd.asGallery", "as Gallery")) { [weak self] in
            self?.setActiveViewMode(.gallery)
        }
        add("view.asColumn", L("bvc.cmd.asColumns", "as Columns")) { [weak self] in
            self?.setActiveViewMode(.column)
        }
        add("view.asTree", L("bvc.cmd.asTree", "as Tree")) { [weak self] in
            self?.setActiveViewMode(.tree)
        }
        add(
            "view.saveViewPreset", L("bvc.cmd.saveViewPreset", "Save Current View As…"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.saveViewPreset()
        }
        for key in ViewFormat.GroupKey.allCases {
            add(key.commandID, key.localizedTitle, enabled: canArrange) { [weak self] in
                self?.activePane?.setGroupKey(key)
            }
        }
        for key in ViewFormat.SortKey.allCases {
            add(
                key.commandID, key.localizedTitle,
                enabled: { [weak self] in self?.activePane != nil }
            ) { [weak self] in
                guard let pane = self?.activePane else { return }
                pane.applySort(key: key, ascending: pane.format.ascending)
            }
        }
        add("view.zoomIn", L("bvc.cmd.zoomIn", "Zoom In")) { [weak self] in
            self?.activePane?.zoomContent(0.15)
        }
        add("view.zoomOut", L("bvc.cmd.zoomOut", "Zoom Out")) { [weak self] in
            self?.activePane?.zoomContent(-0.15)
        }
        add("terminal.toggle", L("bvc.cmd.toggleTerminal", "Toggle Terminal")) { [weak self] in
            self?.toggleTerminal()
        }
        add("commander.toggle", L("bvc.cmd.commanderMode", "Commander Mode")) { [weak self] in
            self?.toggleCommander()
        }
        add("nav.vimMode", L("bvc.cmd.vimMode", "Vim Navigation")) { [weak self] in
            self?.vimMode.toggle()
            self?.vimPendingG = false
        }
        add("terminal.here", L("bvc.cmd.openTerminalHere", "Open Terminal Here")) { [weak self] in
            self?.openTerminalHere()
        }
        add("terminal.toggleFollow", L("bvc.cmd.terminalFollowsFolder", "Terminal Follows Folder"))
        {
            [weak self] in self?.toggleTerminalFollows()
        }
        add("files.paste", L("bvc.cmd.paste", "Paste")) { [weak self] in self?.paste(nil) }
        add(
            "files.pasteOtherPane", L("bvc.cmd.pasteOtherPane", "Paste in Other Pane"),
            enabled: { [weak self] in self?.otherPane != nil }
        ) { [weak self] in self?.pasteInto(self?.otherPane) }
        add("files.open", L("bvc.cmd.open", "Open"), enabled: hasSelection) { [weak self] in
            self?.activePane?.openSelection()
        }
        add("files.batchRename", L("bvc.cmd.batchRename", "Batch Rename…"), enabled: hasSelection) {
            [weak self] in self?.showBatchRename()
        }
        add(
            "files.selectByPattern", L("bvc.cmd.selectByPattern", "Select by Pattern…"),
            enabled: { [weak self] in
                self?.activePane != nil
            }
        ) { [weak self] in self?.selectByPattern() }
        add("files.newFolder", L("bvc.cmd.newFolder", "New Folder")) { [weak self] in
            self?.newFolder()
        }
        add(
            "files.newFolderWithSelection",
            L("bvc.newFolderWithSelectionAction", "New Folder with Selection"),
            enabled: { [weak self] in
                guard let pane = self?.activePane else { return false }
                return !pane.isRemote && !pane.isShowingSmartResults
                    && !pane.selectedEntries.isEmpty
            }
        ) { [weak self] in self?.newFolderWithSelection() }
        add("files.newFile", L("bvc.cmd.newFile", "New File")) { [weak self] in self?.newFile() }
        add("files.batchCreate", L("bvc.cmd.batchCreate", "Batch Create…")) { [weak self] in
            self?.showBatchCreate()
        }
        add("templates.manage", L("bvc.cmd.manageTemplates", "Manage Templates…")) { [weak self] in
            self?.showTemplatesManager()
        }
        let inLocalFolder: () -> Bool = { [weak self] in
            guard let pane = self?.activePane else { return false }
            return !pane.isRemote && !pane.isShowingSmartResults
        }
        add("files.findInFiles", L("bvc.cmd.findInFiles", "Find in Files…"), enabled: inLocalFolder)
        { [weak self] in self?.showFindInFiles() }
        add(
            "view.advancedFind", L("bvc.cmd.advancedFind", "Advanced Find…"),
            enabled: { [weak self] in self?.activePane?.isRemote == false }
        ) { [weak self] in self?.showAdvancedFind() }
        add("nav.findFiles", L("bvc.cmd.findFiles", "Find Files Everywhere…")) { [weak self] in
            self?.showGlobalSearch()
        }
        add("tools.processViewer", L("bvc.cmd.processViewer", "Process Viewer")) { [weak self] in
            self?.processViewer.present()
        }
        add("tools.torrents", L("bvc.cmd.torrents", "Torrents")) { [weak self] in
            self?.toggleTorrentsDrawer()
        }
        add(
            "files.addToTorrents", L("bvc.cmd.addToTorrents", "Add to Torrents"),
            enabled: { [weak self] in !(self?.selectedTorrentURLs.isEmpty ?? true) }
        ) {
            [weak self] in self?.addSelectedTorrents()
        }
        add(
            "files.copyMagnetLink", L("bvc.cmd.copyMagnetLink", "Copy Magnet Link"),
            enabled: { [weak self] in !(self?.selectedTorrentURLs.isEmpty ?? true) }
        ) {
            [weak self] in self?.copySelectedMagnetLinks()
        }
        add(
            "files.createTorrent", L("bvc.cmd.createTorrent", "Create Torrent…"),
            enabled: { [weak self] in self?.selectedSingleLocalURL != nil }
        ) {
            [weak self] in self?.createTorrentFromSelection()
        }
        add("tools.transfers", L("bvc.cmd.transfers", "Transfers")) { [weak self] in
            self?.transferController.showWindow()
        }
        add("tools.externalCommands", L("bvc.cmd.externalCommands", "External Commands…")) {
            [weak self] in self?.showExternalCommandsManager()
        }
        add("tools.runShortcut", L("bvc.cmd.runShortcut", "Run Shortcut on Selection…")) {
            [weak self] in self?.showShortcutPicker()
        }
        add(
            "files.ejectVolume", L("bvc.cmd.ejectVolume", "Eject Volume"),
            enabled: { [weak self] in self?.volumeToEject() != nil }
        ) { [weak self] in self?.ejectActiveVolume() }
        add(
            "files.duplicate", L("bvc.cmd.duplicate", "Duplicate"),
            enabled: { [weak self] in
                guard let pane = self?.activePane else { return false }
                return !pane.isRemote && !pane.isShowingSmartResults
                    && !pane.selectedEntries.isEmpty
            }
        ) { [weak self] in self?.duplicateSelection() }
        let hasLocalSelection: () -> Bool = { [weak self] in
            guard let pane = self?.activePane else { return false }
            return !pane.isRemote && !pane.isShowingSmartResults && !pane.selectedEntries.isEmpty
        }
        add(
            "files.makeSymlink", L("bvc.cmd.makeSymlink", "Make Symlink"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.makeLinks(kind: .symlink)
        }
        add("files.makeAlias", L("bvc.cmd.makeAlias", "Make Alias"), enabled: hasLocalSelection) {
            [weak self] in self?.makeLinks(kind: .alias)
        }
        add(
            "files.showOriginal", L("bvc.cmd.showOriginal", "Show Original"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, pane.selectedEntries.count == 1
                else { return false }
                return pane.selectedLocalURLs().first.map(FileContextMenuController.isLink) ?? false
            }
        ) { [weak self] in self?.showOriginal() }
        add(
            "files.showPackageContents", L("bvc.cmd.showPackageContents", "Show Package Contents"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote,
                    pane.selectedEntries.count == 1
                else { return false }
                return pane.selectedLocalURLs().first.map(FileContextMenuController.isPackage)
                    ?? false
            }
        ) { [weak self] in self?.showPackageContents() }
        add(
            "files.makeHardlink", L("bvc.cmd.makeHardlink", "Make Hard Link"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.makeLinks(kind: .hardlink)
        }
        add(
            "files.secureDelete", L("bvc.cmd.secureDelete", "Secure Delete…"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.secureDeleteSelection()
        }
        add(
            "files.encryptDMG", L("bvc.cmd.encryptDMG", "New Encrypted Disk Image…"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.encryptToDiskImage()
        }
        add(
            "files.offload", L("bvc.cmd.offload", "Remove Download"),
            enabled: { [weak self] in self?.cloudActions().showsRemoveDownload ?? false }
        ) { [weak self] in self?.offloadSelection() }
        add("files.backupTo", L("bvc.cmd.backupTo", "Back Up To…"), enabled: hasLocalSelection) {
            [weak self] in self?.backupSelection()
        }
        add(
            "files.repoReclaim", L("bvc.cmd.repoReclaim", "Reclaim in Repo…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane else { return false }
                return !pane.isRemote && !pane.isShowingSmartResults
            }
        ) { [weak self] in self?.repoReclaim() }
        add(
            "files.split", L("bvc.cmd.split", "Split File…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults,
                    pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first
                else { return false }
                return !entry.isDirectory
            }
        ) { [weak self] in self?.splitSelection() }
        add(
            "files.merge", L("bvc.cmd.mergeParts", "Merge Parts"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults,
                    let entry = pane.selectedEntries.first
                else { return false }
                let ext = (entry.name as NSString).pathExtension
                return !ext.isEmpty && ext.allSatisfy(\.isNumber)  // a ".001"-style part
            }
        ) { [weak self] in self?.mergeSelection() }
        add(
            "files.convertImages", L("bvc.cmd.convertImages", "Convert Images…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults
                else { return false }
                return pane.selectedEntries.contains { Self.isImageName($0.name) }
            }
        ) { [weak self] in self?.convertImagesSelection() }
        let hasSelectedImage: () -> Bool = { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else {
                return false
            }
            return pane.selectedEntries.contains { Self.isImageName($0.name) }
        }
        add("image.rotateLeft", L("bvc.cmd.rotateLeft", "Rotate Left"), enabled: hasSelectedImage) {
            [weak self] in self?.rotateSelection(clockwiseDegrees: 270)
        }
        add(
            "image.rotateRight", L("bvc.cmd.rotateRight", "Rotate Right"), enabled: hasSelectedImage
        ) {
            [weak self] in self?.rotateSelection(clockwiseDegrees: 90)
        }
        add(
            "image.removeBackground", L("bvc.cmd.removeBackground", "Remove Background"),
            enabled: hasSelectedImage
        ) {
            [weak self] in self?.removeBackgroundSelection()
        }
        add("image.autoTag", L("bvc.cmd.autoTag", "Auto-Tag by Content"), enabled: hasSelectedImage)
        {
            [weak self] in self?.autoTagSelection()
        }
        add(
            "image.removeLocation", L("bvc.cmd.removeLocation", "Remove Location"),
            enabled: hasSelectedImage
        ) {
            [weak self] in self?.removeLocationFromSelection()
        }
        add(
            "image.crop", L("bvc.cmd.crop", "Crop…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults,
                    pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first
                else { return false }
                return Self.isImageName(entry.name)
            }
        ) { [weak self] in self?.cropSelection() }
        add(
            "image.createPDF", L("bvc.cmd.createPDF", "Create PDF"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults
                else { return false }
                return pane.selectedEntries.contains {
                    Self.isImageName($0.name)
                        || ($0.name as NSString).pathExtension.lowercased() == "pdf"
                }
            }
        ) { [weak self] in self?.createPDFFromSelection() }
        add(
            "files.trimMedia", L("bvc.cmd.trimMedia", "Trim…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults,
                    pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first,
                    !entry.isDirectory
                else { return false }
                return TrimController.trimmableExtensions.contains(
                    (entry.name as NSString).pathExtension.lowercased())
            }
        ) { [weak self] in self?.trimSelection() }
        let hasSelectedMedia: () -> Bool = { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else {
                return false
            }
            return pane.selectedEntries.contains {
                !$0.isDirectory
                    && TrimController.trimmableExtensions.contains(
                        ($0.name as NSString).pathExtension.lowercased())
            }
        }
        add(
            "media.extractAudio", L("bvc.cmd.extractAudio", "Extract Audio (M4A)"),
            enabled: hasSelectedMedia
        ) {
            [weak self] in self?.convertMediaSelection(to: .m4aAudio)
        }
        add(
            "media.convertToMP4", L("bvc.cmd.convertToMP4", "Convert to MP4"),
            enabled: hasSelectedMedia
        ) {
            [weak self] in self?.convertMediaSelection(to: .mp4)
        }
        add(
            "image.markup", L("bvc.cmd.markup", "Markup…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults,
                    pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first
                else { return false }
                return Self.isImageName(entry.name)
            }
        ) { [weak self] in self?.markupSelection() }
        add(
            "files.xattrs", L("bvc.cmd.xattrs", "Extended Attributes…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults
                else { return false }
                return pane.selectedEntries.count == 1
            }
        ) { [weak self] in self?.showXattrs() }
        add(
            "files.removeQuarantine", L("bvc.cmd.removeQuarantine", "Remove Quarantine"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.removeQuarantineFromSelection()
        }
        add(
            "files.diff", L("bvc.cmd.diff", "Compare Files"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults
                else { return false }
                let entries = pane.selectedEntries
                return entries.count == 2 && entries.allSatisfy { !$0.isDirectory }
            }
        ) { [weak self] in self?.compareSelection() }
        add(
            "files.setAttributes", L("bvc.cmd.setAttributes", "Set Attributes…"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.setAttributesSelection()
        }
        add(
            "files.setFinderComment", L("bvc.cmd.setFinderComment", "Set Finder Comment…"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.setFinderCommentSelection()
        }
        add(
            "files.editMetadata", L("bvc.cmd.editMetadata", "Edit Metadata…"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.editMetadataSelection()
        }
        add(
            "files.editACL", L("bvc.cmd.editACL", "Permissions…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults
                else { return false }
                return pane.selectedEntries.count == 1
            }
        ) { [weak self] in self?.editACLSelection() }
        add(
            "files.changeOwner", L("bvc.cmd.changeOwner", "Change Owner (Admin)…"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.changeOwnerViaTerminal()
        }
        add("files.connectToServer", L("bvc.cmd.connectToServer", "Connect to Server…")) {
            [weak self] in self?.connectToServer()
        }
        add(
            "files.addBookmark", L("bvc.cmd.addBookmark", "Bookmark This Remote Folder…"),
            enabled: { [weak self] in self?.activePane?.remoteContext != nil }
        ) {
            [weak self] in self?.addBookmark()
        }
        let localFolder: () -> Bool = { [weak self] in
            guard let pane = self?.activePane else { return false }
            return !pane.isRemote && !pane.isShowingSmartResults
        }
        add(
            "files.setFolderBgColor", L("bvc.cmd.setFolderBgColor", "Background Color…"),
            enabled: localFolder
        ) {
            [weak self] in self?.setFolderBackgroundColor()
        }
        add(
            "files.setFolderBgPicture", L("bvc.cmd.setFolderBgPicture", "Background Picture…"),
            enabled: localFolder
        ) {
            [weak self] in self?.setFolderBackgroundPicture()
        }
        add(
            "files.clearFolderBg", L("bvc.cmd.clearFolderBg", "Remove Background"),
            enabled: localFolder
        ) {
            [weak self] in self?.clearFolderBackground()
        }
        add(
            "files.peekArchive", L("bvc.cmd.peekArchive", "Show Archive Contents"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, pane.selectedEntries.count == 1
                else { return false }
                return pane.selectedLocalURLs().first.map(Archiver.canExtract) ?? false
            }
        ) { [weak self] in self?.peekArchive() }
        add(
            "files.deleteApp", L("bvc.cmd.deleteApp", "Uninstall App…"),
            enabled: { [weak self] in
                guard let entry = self?.activePane?.selectedEntries, entry.count == 1 else {
                    return false
                }
                return entry.first?.name.hasSuffix(".app") == true
            }
        ) { [weak self] in self?.deleteAppWithLeftovers() }
        add("app.resetData", L("bvc.cmd.resetData", "Reset Pathem Data…")) { [weak self] in
            self?.resetPathemData()
        }
        add("git.commit", L("bvc.cmd.gitCommit", "Commit…"), enabled: inLocalFolder) {
            [weak self] in self?.gitCommit()
        }
        add("git.push", L("bvc.cmd.gitPush", "Push"), enabled: inLocalFolder) { [weak self] in
            self?.gitPushPull(push: true)
        }
        add("git.pull", L("bvc.cmd.gitPull", "Pull"), enabled: inLocalFolder) { [weak self] in
            self?.gitPushPull(push: false)
        }
        add(
            "files.rename", L("bvc.cmd.rename", "Rename…"),
            enabled: { [weak self] in self?.activePane?.selectedEntries.count == 1 }
        ) {
            [weak self] in self?.renameSelection()
        }
        add("files.trash", L("bvc.cmd.moveToTrash", "Move to Trash"), enabled: hasSelection) {
            [weak self] in self?.trashSelection()
        }
        add(
            "files.putBack", L("bvc.cmd.putBack", "Put Back"),
            enabled: { [weak self] in self?.selectionIsInTrash ?? false }
        ) { [weak self] in self?.putBackSelection() }
        add(
            "files.deleteImmediately", L("bvc.cmd.deleteImmediately", "Delete Immediately"),
            enabled: hasSelection
        ) { [weak self] in self?.deleteImmediatelySelection() }
        add(
            "files.emptyTrash", L("bvc.cmd.emptyTrash", "Empty Trash"),
            enabled: { [weak self] in self?.trashHasItems ?? false }
        ) { [weak self] in self?.emptyTrash() }
        add(
            "files.setDesktopPicture", L("bvc.cmd.setDesktopPicture", "Set Desktop Picture"),
            enabled: { [weak self] in self?.singleSelectedImageURL != nil }
        ) { [weak self] in self?.setDesktopPicture() }
        add(
            "files.setCustomIcon", L("bvc.cmd.setCustomIcon", "Set Custom Icon…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults
                else { return false }
                return pane.selectedEntries.count == 1
            }
        ) { [weak self] in self?.setCustomIcon() }
        add(
            "files.removeCustomIcon", L("bvc.cmd.removeCustomIcon", "Remove Custom Icon"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.removeCustomIcon()
        }
        add(
            "files.airdrop", L("bvc.cmd.sendViaAirDrop", "Send via AirDrop"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.activePane?.airDropSelection()
        }
        // With nothing selected these act on the folder shown (the empty-space menu's Copy Path and
        // Copy Name), so they are enabled for any local folder too.
        let hasSelectionOrLocalFolder: () -> Bool = { [weak self] in
            guard let pane = self?.activePane else { return false }
            return !pane.selectedEntries.isEmpty || (!pane.isRemote && !pane.isShowingSmartResults)
        }
        add(
            "files.copyPath", L("bvc.cmd.copyPath", "Copy Path"), enabled: hasSelectionOrLocalFolder
        ) {
            [weak self] in self?.copyPaths(asURL: false)
        }
        add("files.copyURL", L("bvc.cmd.copyAsFileURL", "Copy as File URL"), enabled: hasSelection)
        {
            [weak self] in self?.copyPaths(asURL: true)
        }
        add(
            "files.copyName", L("bvc.cmd.copyName", "Copy Name"), enabled: hasSelectionOrLocalFolder
        ) {
            [weak self] in self?.copyNames()
        }
        add(
            "files.addToCollection", L("bvc.cmd.addToCollection", "Add to Collection…"),
            enabled: hasSelection
        ) {
            [weak self] in self?.addToCollection()
        }
        add(
            "files.organizeAI", L("bvc.cmd.organizeWithAI", "Organize with AI…"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.organizeWithAI()
        }
        add(
            "files.organize", L("bvc.cmd.organize", "Organize Folder…"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.organizeFolder()
        }
        add("files.copySHA256", L("bvc.cmd.copySHA256", "Copy SHA-256"), enabled: hasLocalSelection)
        { [weak self] in self?.copyChecksums() }
        add(
            "files.verifyChecksum", L("bvc.cmd.verifyChecksum", "Verify Checksum…"),
            enabled: hasLocalSelection
        ) {
            [weak self] in self?.verifyChecksum()
        }
        add(
            "files.calculateSize", L("bvc.cmd.calculateSize", "Calculate Size"),
            enabled: { [weak self] in self?.activePane?.canCalculateSelectedFolderSizes == true }
        ) {
            [weak self] in self?.activePane?.calculateSelectedFolderSizes()
        }
        add(
            "files.reveal", L("bvc.cmd.revealInFinder", "Reveal in Finder"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.revealSelection()
        }
        add(
            "files.revealInPathem", L("bvc.cmd.revealInPathem", "Reveal in Pathem"),
            enabled: { [weak self] in self?.activePane?.selectedLocalURLs().isEmpty == false }
        ) { [weak self] in self?.revealSelectionInPathem() }
        add(
            "files.getInfo", L("bvc.cmd.getInfo", "Get Info"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.showInfo()
        }
        add(
            "files.download", L("bvc.cmd.download", "Download Now"),
            enabled: { [weak self] in self?.cloudActions().showsDownloadNow ?? false }
        ) { [weak self] in self?.downloadSelection() }
        add(
            "view.preferences", L("bvc.cmd.preferences", "Settings…"),
            keywords: [
                "Preferences", "Prefs", L("bvc.cmd.preferences.keyword", "Preferences"),
            ]
        ) { [weak self] in
            self?.showPreferences()
        }
        add(
            "view.fullPathTitle", L("bvc.cmd.showFullPathInTitleBar", "Show Full Path in Title Bar")
        ) { [weak self] in self?.toggleFullPathTitle() }
        add("view.pathBarBottom", L("bvc.cmd.showPathBarAtBottom", "Show Path Bar at Bottom")) {
            [weak self] in self?.togglePathBarPosition()
        }
        add("search.toggleOCR", L("bvc.cmd.toggleImageOCRInSearch", "Toggle Image OCR in Search")) {
            [weak self] in self?.toggleOCR()
        }
        add(
            "view.toggleHidden", L("bvc.cmd.showHiddenFiles", "Show Hidden Files"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.activePane?.toggleHidden()
        }
        add("view.syncBrowsing", L("bvc.cmd.syncBrowsing", "Sync Browsing")) { [weak self] in
            guard let self else { return }
            self.syncBrowsing.toggle()
            // Seed both panes' anchors so the first move of either one mirrors relative
            // to where they sit right now.
            if self.syncBrowsing {
                for side in [self.leftTabs, self.rightTabs] {
                    if let pane = side.activePane, !pane.isRemote {
                        self.syncBrowseAnchors[ObjectIdentifier(pane)] =
                            pane.currentURL.standardizedFileURL
                    }
                }
            }
        }
        add("workspace.save", L("bvc.cmd.saveWorkspace", "Save Workspace…")) { [weak self] in
            self?.saveWorkspace()
        }
        add("workspace.open", L("bvc.cmd.openWorkspace", "Open Workspace…")) { [weak self] in
            self?.openWorkspace()
        }
        add(
            "view.saveStyle", L("bvc.cmd.saveStyle", "Save Style…"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.saveStyle()
        }
        add(
            "view.applyStyle", L("bvc.cmd.applyStyle", "Apply Style…"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.applyStyle()
        }
        add("tools.automation", L("bvc.cmd.automation", "Automation Rules…")) { [weak self] in
            self?.showAutomationRules()
        }
        add("help.releaseNotes", L("bvc.cmd.releaseNotes", "Release Notes")) {
            ChangelogWindowController.shared.present()
        }
        add("help.fullDiskAccess", L("menu.help.fullDiskAccess", "Full Disk Access Guide…")) {
            [weak self] in self?.showFullDiskAccessGuide()
        }
        add("help.demoWorkspace", L("bvc.cmd.demoWorkspace", "Load Demo Workspace")) {
            [weak self] in self?.loadDemoWorkspace()
        }
        add(
            "view.applyToSubfolders",
            L("bvc.cmd.applyViewToSubfolders", "Apply View to Subfolders"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.applyViewToSubfolders()
        }
        add(
            "view.useAsDefault", L("bvc.cmd.useAsDefaultView", "Use as Default View"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.useCurrentViewAsDefault()
        }
        add(
            "view.options", L("viewopts.title", "View Options"),
            enabled: { [weak self] in
                guard let pane = self?.activePane else { return false }
                return !pane.isRemote && !pane.isShowingSmartResults
            }
        ) { [weak self] in self?.showViewOptions() }
        add(
            "view.calculateSizes", L("bvc.cmd.calculateAllSizes", "Calculate All Sizes"),
            enabled: { [weak self] in
                guard let pane = self?.activePane else { return false }
                return !pane.isRemote && !pane.isShowingSmartResults && pane.viewMode == .list
            }
        ) {
            [weak self] in self?.toggleCalculateSizes()
        }
        add(
            "view.folderTree", L("bvc.cmd.folderTree", "Show Folder Tree"),
            keywords: ["folder tree", "navigation tree", "directory tree", "hierarchy"]
        ) { [weak self] in self?.toggleFolderTree() }
        add(
            "view.stackPanes", L("bvc.cmd.stackPanes", "Stack Panes Vertically"),
            keywords: [
                "horizontal split", "top and bottom", "layout", "stacked", "side by side",
                "panes",
            ]
        ) { [weak self] in self?.toggleStackedPanes() }
        add("view.compactSidebar", L("bvc.cmd.compactSidebar", "Compact Sidebar")) { [weak self] in
            self?.toggleCompactSidebar()
        }
        add(
            "files.share", L("bvc.cmd.share", "Share…"),
            enabled: { [weak self] in !(self?.activePane?.selectedEntries.isEmpty ?? true) }
        ) { [weak self] in self?.activePane?.shareSelection() }
        add(
            "sidebar.importFinderFavorites",
            L("bvc.cmd.importFinderFavorites", "Import Favorites from Finder…")
        ) { [weak self] in self?.importFinderFavorites() }
        add(
            "settings.matchFinder",
            L("finder.match.title", "Match Finder Settings")
        ) { [weak self] in self?.matchFinderPreferences() }
        add("layout.save", L("bvc.cmd.saveLayout", "Save Layout…")) { [weak self] in
            self?.saveLayoutPrompt()
        }
        add("palette.show", L("bvc.cmd.commandPalette", "Command Palette…")) { [weak self] in
            self?.showPalette(prefill: ">")
        }
        add("search.palette", L("bvc.cmd.searchFolder", "Search This Folder…")) { [weak self] in
            self?.showFileSearch()
        }
        add("search.semantic", L("filesearch.semantic", "Semantic Search This Folder…")) {
            [weak self] in self?.showFileSearch(mode: .semantic)
        }
        add("ai.run", L("bvc.cmd.askPathem", "Ask Pathem (Natural Language)…")) { [weak self] in
            self?.showAICommandBar()
        }
        add("view.quickLook", L("bvc.cmd.quickLook", "Quick Look"), enabled: hasSelection) {
            [weak self] in self?.toggleQuickLook()
        }
        add(
            "view.slideshow", L("bvc.cmd.slideshow", "Slideshow"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults
                else { return false }
                return pane.entries.contains {
                    !$0.isDirectory && BrowserViewController.isImageName($0.name)
                }
            }
        ) { [weak self] in self?.startSlideshow() }
        add("tab.new", L("bvc.cmd.newTab", "New Tab")) { [weak self] in
            self?.activeSide?.newTab(duplicatingCurrent: true)
        }
        add("window.new", L("bvc.cmd.newWindow", "New Window")) { [weak self] in
            WindowManager.shared.openWindow(
                start: self?.newWindowStartFolder()
                    ?? FileManager.default.homeDirectoryForCurrentUser)
        }
        add(
            "window.moveTabToNew", L("bvc.cmd.moveTabToNewWindow", "Move Tab to New Window"),
            enabled: { [weak self] in
                guard let side = self?.activeSide, let pane = side.activePane else { return false }
                return !pane.isRemote  // a remote session can't be re-hosted in a fresh window
            }
        ) { [weak self] in self?.moveActiveTabToNewWindow() }
        add(
            "files.openInNewTab", L("bvc.cmd.openInNewTab", "Open in New Tab"),
            enabled: { [weak self] in self?.singleSelectedFolder != nil }
        ) { [weak self] in
            guard let self, let folder = self.singleSelectedFolder else {
                NSSound.beep()
                return
            }
            self.activeSide?.openTab(at: folder)
        }
        add(
            "tab.close", L("bvc.cmd.closeTab", "Close Tab"),
            enabled: { [weak self] in (self?.activeSide?.tabCount ?? 0) > 1 }
        ) {
            [weak self] in self?.activeSide?.closeActiveTab()
        }
        add(
            "tab.next", L("bvc.cmd.nextTab", "Next Tab"),
            enabled: { [weak self] in (self?.activeSide?.tabCount ?? 0) > 1 }
        ) {
            [weak self] in self?.activeSide?.selectNextTab()
        }
        add(
            "tab.previous", L("bvc.cmd.previousTab", "Previous Tab"),
            enabled: { [weak self] in (self?.activeSide?.tabCount ?? 0) > 1 }
        ) {
            [weak self] in self?.activeSide?.selectPreviousTab()
        }
        add(
            "nav.back", L("bvc.cmd.back", "Back"),
            enabled: { [weak self] in self?.activePane?.canGoBack ?? false }
        ) {
            [weak self] in self?.activePane?.goBack()
        }
        add(
            "nav.forward", L("bvc.cmd.forward", "Forward"),
            enabled: { [weak self] in self?.activePane?.canGoForward ?? false }
        ) {
            [weak self] in self?.activePane?.goForward()
        }
        add(
            "nav.up", L("bvc.cmd.enclosingFolder", "Enclosing Folder"),
            enabled: { [weak self] in self?.activePane?.canGoUp ?? false }
        ) {
            [weak self] in self?.activePane?.goUp()
        }
        add("nav.editPath", L("bvc.cmd.goToPath", "Go to Path…")) { [weak self] in
            self?.activePane?.beginEditingPath()
        }
        add(
            "nav.selectFirst", L("bvc.cmd.selectFirst", "Select First Item"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.activePane?.selectFirst()
        }
        add(
            "nav.selectLast", L("bvc.cmd.selectLast", "Select Last Item"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.activePane?.selectLast()
        }
        add(
            "view.flatView", L("bvc.cmd.flatView", "Flat View"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.activePane?.showFlatView()
        }
        add(
            "view.filter", L("bvc.cmd.filter", "Filter…"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.activePane?.beginFilter()
        }
        add(
            "view.previewPane", L("bvc.cmd.previewPane", "Preview Pane"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.togglePreviewPane()
        }
        add("view.demoMode", L("bvc.cmd.demoMode", "Demo Mode (fake data for screenshots)")) {
            [weak self] in self?.toggleDemoMode()
        }
        add(
            "files.findDuplicates", L("bvc.cmd.findDuplicates", "Find Duplicates"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.findDuplicates()
        }
        add(
            "files.findSimilarNames", L("bvc.cmd.findSimilarNames", "Find Similar Names"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.findSimilarNames()
        }
        add(
            "image.findNearDuplicates",
            L("bvc.cmd.findNearDuplicates", "Find Near-Duplicate Photos"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.cullNearDuplicatePhotos()
        }
        add(
            "view.flattenFolder", L("bvc.cmd.flattenFolder", "Flatten Folder (Show All Items)"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults
                else { return false }
                return true
            }
        ) { [weak self] in self?.flattenFolder() }
        add(
            "ai.renameSelection", L("bvc.cmd.aiRename", "AI Rename…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults
                else { return false }
                return pane.selectedEntries.count == 1
                    && !(pane.selectedEntries.first?.isDirectory ?? true)
            }
        ) { [weak self] in self?.aiRenameSelection() }
        add(
            "ai.summarizeFolder", L("bvc.cmd.aiSummarize", "Summarize Folder"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults
                else { return false }
                return true
            }
        ) { [weak self] in self?.aiSummarizeFolder() }
        add(
            "view.sizeBrowser", L("bvc.cmd.sizeBrowser", "Size Browser…"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in
            guard let self, let url = self.activePane?.currentURL else { return }
            self.sizeBrowser.present(for: url, over: self.view.window)
        }
        add(
            "view.cleanup", L("bvc.cmd.cleanup", "Cleanup…"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in
            guard let self, let url = self.activePane?.currentURL else { return }
            // Make Cleanup's bulk-trash undoable and Put-Back-able, like every other trash flow.
            self.cleanup.onTrashed = { [weak self] trashed in
                self?.recordTrashOrigins(trashed)
                self?.registerTrashUndo(trashed)
                self?.reloadBothSides()
            }
            self.cleanup.onEmptyTrash = { [weak self] done in self?.emptyTrash(then: done) }
            self.cleanup.present(for: url, over: self.view.window)
        }
        add(
            "view.customizeToolbar", L("bvc.cmd.customizeToolbar", "Customize Toolbar…"),
            enabled: { [weak self] in
                self?.view.window?.toolbar != nil
            }
        ) { [weak self] in self?.view.window?.toolbar?.runCustomizationPalette(nil) }
        add(
            "files.comparePanes", L("bvc.cmd.comparePanes", "Compare Panes…"),
            enabled: { [weak self] in self?.activePane != nil }
        ) {
            [weak self] in self?.comparePanes()
        }
        add("photos.open", L("bvc.cmd.openPhotos", "Photos Library…")) { [weak self] in
            self?.openPhotosBrowser()
        }
        add("files.compress", L("bvc.cmd.compress", "Compress"), enabled: hasLocalSelection) {
            [weak self] in self?.compressSelection()
        }
        add(
            "files.compress7z", L("bvc.cmd.compress7z", "Compress to 7-Zip"),
            enabled: hasLocalSelection
        ) { [weak self] in self?.compress7zSelection() }
        let hasArchive: () -> Bool = { [weak self] in
            (self?.activePane?.selectedLocalURLs() ?? []).contains { Archiver.canExtract($0) }
        }
        add(
            "files.extract", L("bvc.cmd.extract", "Extract"), enabled: hasArchive
        ) { [weak self] in self?.extractSelection() }
        add(
            "files.extractHere", L("bvc.cmd.extractHere", "Extract Here"), enabled: hasArchive
        ) { [weak self] in self?.extractHereSelection() }
        add(
            "files.extractTo", L("bvc.cmd.extractTo", "Extract to Folder…"), enabled: hasArchive
        ) { [weak self] in self?.extractToSelection() }
        add(
            "shelf.add", L("bvc.cmd.addToShelf", "Add to Drop Stack"),
            enabled: { [weak self] in !(self?.activePane?.selectedEntries.isEmpty ?? true) }
        ) { [weak self] in self?.addSelectionToShelf() }
        add("shelf.toggle", L("bvc.cmd.showShelf", "Show Drop Stack")) { [weak self] in
            self?.toggleShelf()
        }
        add("connections.manage", L("bvc.cmd.connections", "Connections…")) {
            [weak self] in self?.connectionsController.present(over: self?.view.window)
        }
        add(
            "connections.newTabToggle",
            L("bvc.cmd.openConnectionsInNewTab", "Open Connections in a New Tab")
        ) {
            [weak self] in self?.toggleConnectionsNewTab()
        }
        for color in FileTag.Color.displayOrder {
            add(
                "tags.toggle.\(color.rawValue)",
                String(format: L("bvc.cmd.tagColor", "Tag %@"), TagColors.label(color)),
                enabled: taggableSelection
            ) {
                [weak self] in self?.activePane?.tagSelection(toggle: color)
            }
        }
        add("tags.clear", L("bvc.cmd.clearTags", "Clear Tags"), enabled: taggableSelection) {
            [weak self] in self?.activePane?.clearSelectionTags()
        }
        add(
            "remote.download", L("bvc.cmd.downloadFromServer", "Download from Server…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, pane.isRemote else { return false }
                return pane.selectedEntries.contains { !$0.isDirectory }
            }
        ) { [weak self] in self?.downloadSelectedRemote() }
        add(
            "edit.undo", L("bvc.cmd.undo", "Undo"),
            enabled: { [weak self] in self?.actionHistory.canUndo ?? false }
        ) {
            [weak self] in self?.undo(nil)
        }
        add(
            "edit.redo", L("bvc.cmd.redo", "Redo"),
            enabled: { [weak self] in self?.actionHistory.canRedo ?? false }
        ) {
            [weak self] in self?.redo(nil)
        }
        add("edit.showHistory", L("bvc.cmd.showHistory", "Undo History…")) { [weak self] in
            self?.showUndoHistory()
        }
        loadExtensionsIfEnabled()
    }
}
