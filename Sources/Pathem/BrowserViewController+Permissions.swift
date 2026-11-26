import AppKit
import PathemEngine

// Ownership / access-control actions: edit a file's POSIX ACL, and change owner via a sudo command
// typed into the embedded terminal (no bundled privileged helper). Extracted from
// BrowserViewController to shrink the god-object (5.1); state stays on the controller.
extension BrowserViewController {
    /// Edit the selected item's POSIX ACL (add/remove access-control entries).
    func editACLSelection() {
        guard let pane = activePane, !pane.isRemote, let url = pane.selectedLocalURLs().first else {
            NSSound.beep()
            return
        }
        aclEditor.present(url: url, over: view.window)
    }

    /// Change the owner of the selection. Because giving a file to another user needs root, Pathem
    /// types a ready-to-run `sudo chown` command into the embedded terminal (which prompts for the
    /// password) rather than bundling a privileged helper. Changing only the group is done without
    /// root via Set Attributes ▸ Group.
    func changeOwnerViaTerminal() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let currentOwner = OwnershipEditor.read(urls[0])?.owner ?? ""
        let admin = AdminModeController.isSupported && AdminModeController.shared.isUnlocked

        let alert = NSAlert()
        alert.messageText = String(
            format: L("chown.title", "Change owner of %d item(s)"), urls.count)
        alert.informativeText =
            admin
            ? L("admin.ownerHint", "Set the owner and optionally the group for the selected items.")
            : L(
                "chown.hint",
                "Changing the owner needs administrator rights, so Pathem will type a sudo command into the terminal. Review it and press Return to run it. (To change only the group, use Set Attributes.)"
            )
        alert.addButton(
            withTitle: admin
                ? L("common.apply", "Apply") : L("chown.prepare", "Prepare in Terminal"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))

        let ownerField = NSTextField(string: currentOwner)
        ownerField.placeholderString = L("chown.owner", "new owner (user)")
        let groupField = NSTextField()
        groupField.placeholderString = L("chown.group", "group (optional)")
        let recursive = NSButton(
            checkboxWithTitle: L("chown.recursive", "Apply to folder contents (-R)"), target: nil,
            action: nil)
        let fields = NSStackView(
            views: admin ? [ownerField, groupField] : [ownerField, groupField, recursive])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 84)
        ownerField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        groupField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        alert.accessoryView = fields
        alert.window.initialFirstResponder = ownerField

        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            if admin {
                await self.applyOwnerSelection(
                    urls, user: ownerField.stringValue, group: groupField.stringValue)
                return
            }
            let command = OwnershipEditor.sudoChownCommand(
                owner: ownerField.stringValue, group: groupField.stringValue,
                recursive: recursive.state == .on, paths: urls.map(\.path))
            guard !command.isEmpty else {
                NSSound.beep()
                return
            }
            if self.terminal.view.isHidden { self.toggleTerminal() }  // reveal the terminal
            self.terminal.typeCommand(
                command,
                in: self.activePane?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser)
            self.terminal.focus()
        }
    }

    private func applyOwnerSelection(_ urls: [URL], user: String, group: String) async {
        let groupName = group.trimmingCharacters(in: .whitespaces)
        let gid = groupName.isEmpty ? nil : OwnershipEditor.groupID(groupName)
        guard let uid = OwnershipEditor.userID(user), groupName.isEmpty || gid != nil else {
            activePane?.flashStatus(
                L("admin.unknownOwner", "Unknown owner or group"), isError: true)
            return
        }
        var attributes: [FileAttributeKey: Any] = [.ownerAccountID: NSNumber(value: uid)]
        if let gid { attributes[.groupOwnerAccountID] = NSNumber(value: gid) }
        var failures: [FileOperations.Failure] = []
        for url in urls {
            do {
                try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
            } catch {
                var reported = error
                do {
                    if try await retryAsAdmin(
                        AdminFileRequest(
                            operation: .setOwner, source: url.path, owner: uid, group: gid),
                        after: error) != nil
                    {
                        continue
                    }
                } catch { reported = error }
                failures.append(
                    .init(name: url.lastPathComponent, reason: reported.localizedDescription))
            }
        }
        reloadBothSides()
        if !failures.isEmpty {
            presentFailures(failures, title: L("bvc.setAttrsFailed", "Couldn’t set attributes"))
        }
    }

}
