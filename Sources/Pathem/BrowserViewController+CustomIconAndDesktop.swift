import AppKit

/// NSWorkspace-backed Finder decoration commands: set or remove a custom file/folder icon, and
/// set the desktop picture from the selection.
@MainActor
extension BrowserViewController {
    /// Set the selected image as the desktop picture on every screen.
    /// Set a chosen image as the selected item's custom icon (folder or file), via NSWorkspace.
    func setCustomIcon() {
        guard let pane = activePane, !pane.isRemote, let target = pane.selectedLocalURLs().first, let window = view.window else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = L("customicon.choose", "Set Icon")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let iconURL = panel.url, let icon = NSImage(contentsOf: iconURL), let self else { return }
            if NSWorkspace.shared.setIcon(icon, forFile: target.path, options: []) {
                self.activePane?.reloadIfShowingListing()
            } else {
                self.presentInfo(
                    L("customicon.failedTitle", "Couldn’t set the icon"),
                    L("customicon.failedBody", "The custom icon couldn’t be applied. You may not have permission to change this item."))
            }
        }
    }

    /// Remove the custom icon from the selection (restore the default).
    func removeCustomIcon() {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        for url in pane.selectedLocalURLs() { NSWorkspace.shared.setIcon(nil, forFile: url.path, options: []) }
        pane.reloadIfShowingListing()
    }

    @objc func setDesktopPicture() {
        guard let url = singleSelectedImageURL else { NSSound.beep(); return }
        var failed = false
        for screen in NSScreen.screens {
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) } catch { failed = true }
        }
        if failed {
            presentInfo(
                L("bvc.desktopFailedTitle", "Couldn’t set the desktop picture"),
                L("bvc.desktopFailedBody", "The image may be in a format the desktop can’t use."))
        }
    }
}
