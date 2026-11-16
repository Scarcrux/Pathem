import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {

    static var connectionsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("connections.json")
    }

    func loadConnections() {
        if let saved = loadConfig([RemoteConnection].self, from: Self.connectionsURL) {
            connectionsController.connections = saved
        }
        sidebar.setConnections(connectionsController.connections)
        connectionsController.onChange = { [weak self] conns in
            self?.saveConfig(conns, to: Self.connectionsURL)
            self?.sidebar.setConnections(conns)  // keep the sidebar Connections section in sync
        }
        connectionsController.onConnect = { [weak self] connection in
            self?.connectToRemote(connection)
        }
    }

    /// Prompt for a password and open the server in the active pane.
    /// If the site has a default local directory, point the other (local) pane at it, pairing the
    /// local and remote sides on connect.
    private func openLocalPairing(_ connection: RemoteConnection) {
        guard !connection.localPath.isEmpty else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: connection.localPath, isDirectory: &isDir),
            isDir.boolValue
        else { return }
        let otherSide = (activeSide === leftTabs) ? rightTabs : leftTabs
        otherSide.activePane?.navigate(to: URL(fileURLWithPath: connection.localPath))
    }

    func connectToRemote(_ connection: RemoteConnection, forceNewTab: Bool = false) {
        guard let pane = activePane else { return }
        // For SFTP to a host we haven't pinned yet, confirm its key fingerprint first (a visible
        // trust-on-first-use prompt) instead of silently accepting it.
        if connection.proto == .sftp,
            !HostKeyCheck.isKnown(host: connection.host, port: connection.effectivePort)
        {
            Task { @MainActor in
                guard await self.confirmNewHostKey(connection) else { return }
                self.beginConnect(connection, forceNewTab: forceNewTab, pane: pane)
            }
            return
        }
        beginConnect(connection, forceNewTab: forceNewTab, pane: pane)
    }

    /// Show the scanned host-key fingerprint and let the user accept it (or cancel) before the first
    /// SFTP connection. Returns true to proceed. If the key can't be scanned (host unreachable), we
    /// proceed anyway: ssh's own accept-new still pins it on the real connection.
    private func confirmNewHostKey(_ connection: RemoteConnection) async -> Bool {
        guard
            let fingerprint = await HostKeyCheck.fingerprint(
                host: connection.host, port: connection.effectivePort), view.window != nil
        else { return true }
        let alert = NSAlert()
        alert.messageText = String(
            format: L("hostkey.title", "First connection to “%@”"), connection.host)
        alert.informativeText = String(
            format: L(
                "hostkey.body",
                "The server presented this host-key fingerprint:\n\n%@\n\nAccept it only if it matches what you expect. It is pinned for future connections."
            ),
            fingerprint)
        alert.addButton(withTitle: L("hostkey.accept", "Accept and Connect"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return await presentSheet(alert) == .alertFirstButtonReturn
    }

    private func beginConnect(
        _ connection: RemoteConnection, forceNewTab: Bool, pane: PaneController
    ) {
        openLocalPairing(connection)  // point the other pane at the site's default local dir
        // USB devices (adb / iOS) have no password; connect straight through.
        if connection.proto.isDevice {
            openRemoteConnection(connection, password: "", forceNewTab: forceNewTab, fallback: pane)
            return
        }
        // A remembered password connects straight away, no prompt.
        if let saved = KeychainStore.password(for: connection.id) {
            openRemoteConnection(
                connection, password: saved, forceNewTab: forceNewTab, fallback: pane)
            return
        }
        guard let window = view.window else { return }
        let (alert, field, remember) = Self.makePasswordDialog(connection: connection)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if remember.state == .on {
                KeychainStore.setPassword(field.stringValue, for: connection.id)
            }
            self.openRemoteConnection(
                connection, password: field.stringValue, forceNewTab: forceNewTab, fallback: pane)
        }
    }

    private func openRemoteConnection(
        _ connection: RemoteConnection, password: String, forceNewTab: Bool,
        fallback: PaneController
    ) {
        var target = fallback
        if forceNewTab || prefs.openConnectionsInNewTab, let side = activeSide {
            side.newTab(duplicatingCurrent: true)  // the new tab becomes active
            target = activePane ?? fallback
        }
        target.openRemote(connection, password: password)
    }

    // MARK: - Shared (SMB) computers

    /// Resolve a discovered Bonjour host and mount its SMB share, then browse it.
    func connectToShared(_ name: String) {
        sharedDiscovery.resolveHost(named: name) { [weak self] host in
            guard let self, let host else {
                self?.presentInfo(
                    L("smb.unreachableTitle", "Can’t reach that computer"),
                    String(
                        format: L(
                            "smb.unreachableBody",
                            "Couldn’t resolve “%@” on the network. It may have gone offline."),
                        name))
                return
            }
            self.mountSMB(host: host)
        }
    }

    // MARK: - Remote bookmarks

    /// Save the active remote pane's current path as a named bookmark on its
    /// connection, so it can be jumped back to from the Bookmarks menu.
    func addBookmark() {
        guard let ctx = activePane?.remoteContext else {
            NSSound.beep()
            return
        }
        let (alert, field) = Self.makeBookmarkDialog(
            path: ctx.path, connectionName: ctx.connection.name)
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            guard
                let idx = self.connectionsController.connections.firstIndex(where: {
                    $0.id == ctx.connection.id
                })
            else {
                NSSound.beep()
                return
            }
            self.connectionsController.connections[idx].bookmarks.removeAll { $0.name == name }
            self.connectionsController.connections[idx].bookmarks.append(
                RemoteBookmark(name: name, remotePath: ctx.path))
            self.connectionsController.onChange?(self.connectionsController.connections)
        }
    }

    /// Reconnect the active remote pane at a saved bookmark's path, reusing the
    /// live session password so there's no re-prompt.
    func jumpToBookmark(_ bookmark: RemoteBookmark) {
        guard let pane = activePane, let ctx = pane.remoteContext else {
            NSSound.beep()
            return
        }
        var target = ctx.connection
        target.path = bookmark.remotePath
        openRemoteConnection(target, password: ctx.password, forceNewTab: false, fallback: pane)
    }
}

@MainActor
extension BrowserViewController {
    /// Production construction shared with isolated geometry/lifecycle checks.
    static func makePasswordDialog(connection: RemoteConnection) -> (
        NSAlert, NSSecureTextField, NSButton
    ) {
        let who = connection.user.isEmpty ? L("bvc.anonymous", "anonymous") : connection.user
        let usingKey = connection.proto == .sftp && !connection.keyFile.isEmpty
        let alert = NSAlert()
        alert.messageText = String(format: L("bvc.connectTo", "Connect to %@"), connection.host)
        alert.informativeText =
            usingKey
            ? L(
                "bvc.enterPassphrase",
                "Enter the private key’s passphrase (leave blank if it has none).")
            : String(
                format: L("bvc.enterPasswordFor", "Enter the password for %@@%@."), who,
                connection.host)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let remember = NSButton(
            checkboxWithTitle: usingKey
                ? L("bvc.rememberPassphraseInKeychain", "Remember passphrase in Keychain")
                : L("bvc.rememberPasswordInKeychain", "Remember password in Keychain"),
            target: nil, action: nil)
        let accessory = NSStackView(views: [field, remember])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("bvc.connect", "Connect"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return (alert, field, remember)
    }
}

@MainActor
extension BrowserViewController {
    /// Production construction shared with isolated geometry/lifecycle checks.
    static func makeBookmarkDialog(path: String, connectionName: String) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.messageText = L("bookmark.title", "Bookmark This Folder")
        alert.informativeText = String(
            format: L("bookmark.hint", "Save “%@” on %@ so you can jump back to it later."),
            path, connectionName)
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let leaf = (path as NSString).lastPathComponent
        field.stringValue = leaf.isEmpty || leaf == "/" ? connectionName : leaf
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return (alert, field)
    }
}
