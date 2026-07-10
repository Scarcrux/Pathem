import AppKit
import PathemEngine

// Per-folder background color/picture: load the persisted config at launch, reapply it to
// every open pane, and set/clear a color or picture on the current folder. Split out of
// BrowserViewController.
@MainActor
extension BrowserViewController {
    func loadFolderBackgrounds() {
        folderBackgrounds = loadConfig(FolderBackgrounds.self, from: Self.folderBackgroundsURL) ?? .default
    }
    private func reapplyFolderBackgrounds() {
        for side in [leftTabs, rightTabs] { for pane in side.tabs { pane.applyFolderBackground() } }
    }

    /// Set the current folder's background to a solid color (a color well in a sheet), applied
    /// immediately and persisted; a color replaces any picture.
    func setFolderBackgroundColor() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults, let window = view.window else { NSSound.beep(); return }
        _ = window
        let folder = pane.currentURL
        let alert = NSAlert()
        alert.messageText = String(format: L("folderbg.colorTitle", "Background color for “%@”"), folder.lastPathComponent)
        alert.addButton(withTitle: L("common.apply", "Apply"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 44))
        if let hex = folderBackgrounds.background(for: folder.path)?.colorHex, let color = ThemeManager.color(fromHex: hex) {
            well.color = color
        }
        alert.accessoryView = well
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            var background = self.folderBackgrounds.background(for: folder.path) ?? FolderBackground()
            background.colorHex = ThemeManager.hex(from: well.color)
            background.imagePath = ""  // a color replaces a picture
            self.folderBackgrounds.set(background, for: folder.path)
            self.saveConfig(self.folderBackgrounds, to: Self.folderBackgroundsURL)
            self.reapplyFolderBackgrounds()
        }
    }

    /// Set the current folder's background to a picture chosen from disk; a picture replaces any color.
    func setFolderBackgroundPicture() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults, let window = view.window else { NSSound.beep(); return }
        let folder = pane.currentURL
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = L("folderbg.choose", "Choose")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            var background = self.folderBackgrounds.background(for: folder.path) ?? FolderBackground()
            background.imagePath = url.path
            background.colorHex = ""
            self.folderBackgrounds.set(background, for: folder.path)
            self.saveConfig(self.folderBackgrounds, to: Self.folderBackgroundsURL)
            self.reapplyFolderBackgrounds()
        }
    }

    /// Remove the current folder's background (restore the default).
    func clearFolderBackground() {
        guard let pane = activePane, !pane.isShowingSmartResults else { NSSound.beep(); return }
        folderBackgrounds.set(nil, for: pane.currentURL.path)
        saveConfig(folderBackgrounds, to: Self.folderBackgroundsURL)
        reapplyFolderBackgrounds()
    }
}
