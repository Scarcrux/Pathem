import AppKit
import PathemEngine

// The synthetic "Network" location. Clicking Network in the sidebar drops the active pane into a
// browsable listing -- like Finder's Network view -- rather than jumping straight to a Connect to
// Server prompt. It lists the mounted network volumes (OrbStack, mounted SMB/AFP/NFS shares), which
// open by navigating into them, plus the Bonjour-discovered computers on the LAN, which open by
// mounting their share. Connect to Server stays available from the Go menu / command palette.
extension BrowserViewController {
    /// Show the Network view in the active pane.
    func showNetworkView() {
        guard let pane = activePane else { NSSound.beep(); return }
        let (entries, hostNames) = networkListing()
        pane.showNetworkResults(
            entries, hostNames: hostNames, title: L("network.title", "Network"))
    }

    /// Rebuild the Network view in place when the discovered-host set changes, but only if a pane is
    /// actually showing it (so live Bonjour churn doesn't yank a pane out of a folder).
    func refreshNetworkViewIfShowing() {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs where pane.isShowingNetworkView {
                let (entries, hostNames) = networkListing()
                pane.showNetworkResults(
                    entries, hostNames: hostNames, title: L("network.title", "Network"))
            }
        }
    }

    /// The Network listing: real network-volume mounts as file entries (navigable) plus the
    /// discovered-but-unmounted hosts as placeholder entries (mounted on open). Returns the entries
    /// and the set of names that are hosts (so the pane knows which ones mount vs. navigate).
    private func networkListing() -> (entries: [FileEntry], hostNames: Set<String>) {
        var entries: [FileEntry] = []
        var mountedNames: Set<String> = []

        // Mounted network volumes (local == false): OrbStack's NFS share, mounted SMB/AFP shares.
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        let mounts = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for url in mounts {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsBrowsable != false, v?.volumeIsLocal == false else { continue }
            entries.append(FileEntry(contentsOf: url))
            mountedNames.insert(v?.volumeName ?? url.lastPathComponent)
        }

        // Discovered computers not already represented by a mount. Placeholder directory entries
        // (no real path) that the pane resolves to a mount action on open.
        var hostNames: Set<String> = []
        for host in discoveredHosts where !mountedNames.contains(host) {
            entries.append(FileEntry(name: host, isDirectory: true, size: 0, modificationDate: nil))
            hostNames.insert(host)
        }
        return (entries, hostNames)
    }
}
