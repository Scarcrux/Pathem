import AppKit
import NetFS
import PathemEngine

// Mounting network shares (SMB / AFP / NFS) via NetFS. Split out of BrowserViewController
// to keep that file focused; the discovered-host list and the site manager live elsewhere.
extension BrowserViewController {
    /// The manual "Connect to Server" dialog: mount an smb:// / afp:// / nfs:// address and
    /// browse the mount point in the active pane.
    func connectToServer() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L("connect.title", "Connect to Server")
        alert.informativeText = L("connect.hint", "Enter a server address, for example smb://host/share or afp://host.")
        alert.addButton(withTitle: L("connect.connect", "Connect"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "smb://host/share"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            var text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            if !text.contains("://") { text = "smb://" + text }  // bare host defaults to SMB
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                ["smb", "afp", "nfs"].contains(scheme)
            else {
                self.presentInfo(
                    L("connect.badTitle", "Unsupported address"),
                    L("connect.badBody", "Use an smb://, afp://, or nfs:// address."))
                return
            }
            let result = await Self.mountShare(url)
            if let mount = result.mount {
                self.activePane?.navigate(to: mount)
            } else if result.status != ECANCELED {  // ECANCELED = user dismissed the OS prompt
                self.presentInfo(
                    L("smb.failedTitle", "Couldn’t connect"),
                    String(format: L("connect.failedBody", "Couldn’t mount “%@”. Check the address and your credentials."), text))
            }
        }
    }

    /// Mount smb://host via NetFS (the OS handles auth/Keychain and shows its own prompt when
    /// needed), then navigate the active pane to the mount point.
    func mountSMB(host: String) {
        // The host comes from a Bonjour-resolved service on the LAN; validate it and
        // build the URL via URLComponents so a hostile name can't smuggle a path,
        // query, or alternate authority into the smb:// URL.
        guard RemoteConnection.isValidHost(host) else {
            NSSound.beep()
            return
        }
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        guard let url = components.url else {
            NSSound.beep()
            return
        }
        Task { [weak self] in
            let result = await Self.mountShare(url)
            guard let self else { return }
            if let mount = result.mount {
                self.activePane?.navigate(to: mount)
            } else if result.status != ECANCELED {
                // nil with ECANCELED means the user dismissed the OS credential prompt;
                // only a real failure (unreachable host, wrong password, share gone) warrants
                // an alert.
                self.presentInfo(
                    L("smb.failedTitle", "Couldn’t connect"),
                    String(
                        format: L("smb.failedBody", "Couldn’t mount “%@”. Check that the share is available and your credentials are correct."),
                        host))
            }
        }
    }

    /// Off-main NetFS mount. Returns the mount point (nil on failure/cancel) plus the NetFS
    /// status, so the caller can tell a user cancel (ECANCELED) from a real failure.
    nonisolated static func mountShare(_ url: URL) async -> (mount: URL?, status: Int32) {
        await withCheckedContinuation { (cont: CheckedContinuation<(URL?, Int32), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let openOptions = NSMutableDictionary()
                openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI  // let the OS prompt for credentials
                var mountpoints: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(
                    url as CFURL, nil, nil, nil, openOptions as CFMutableDictionary, nil, &mountpoints)
                let paths = (mountpoints?.takeRetainedValue() as? [String]) ?? []
                cont.resume(
                    returning: (status == 0 ? paths.first.map { URL(fileURLWithPath: $0) } : nil, status))
            }
        }
    }
}
