import AppKit

/// A menu-bar indicator for the torrent VPN kill-switch. It appears only while VPN binding is on,
/// and shows at a glance whether torrent traffic is safely bound to a tunnel (a green shield) or the
/// kill-switch has paused everything because no VPN is up (a red shield). Its menu carries the live
/// status line, a shortcut to the Torrents window, and a quick way to turn binding off.
@MainActor
final class VPNStatusItem {
    private let item: NSStatusItem
    private let client = TorrentDaemonClient.shared

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = .removalAllowed
        item.button?.imageScaling = .scaleProportionallyDown
        buildMenu()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: .torrentVPNStateChanged, object: nil)
        refresh()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private func buildMenu() {
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let open = NSMenuItem(
            title: L("vpn.menu.openTorrents", "Open Torrents…"), action: #selector(openTorrents), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        toggleItem.title = L("vpn.menu.turnOff", "Turn Off VPN Binding")
        toggleItem.action = #selector(turnOff)
        toggleItem.target = self
        menu.addItem(toggleItem)
        item.menu = menu
    }

    /// Update the icon, tint, tooltip, and menu text from the client's current VPN state.
    @objc private func refresh() {
        guard client.bindToVPN else {
            item.isVisible = false  // the indicator only exists while the feature is on
            return
        }
        item.isVisible = true
        let bound = client.vpnInterface
        let isBound = bound != nil
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: isBound ? "lock.shield.fill" : "exclamationmark.shield.fill",
                accessibilityDescription: L("vpn.menu.title", "Torrent VPN binding"))
            button.contentTintColor = isBound ? .systemGreen : .systemRed
            button.toolTip = statusText(bound: bound)
        }
        statusLine.title = statusText(bound: bound)
    }

    private func statusText(bound: String?) -> String {
        if let bound {
            return String(format: L("vpn.status.bound", "Torrents bound to %@"), bound)
        }
        return L("vpn.status.killed", "No VPN, torrents paused")
    }

    @objc private func openTorrents() {
        WindowManager.shared.primaryBrowser?.showTorrentsDrawer()
    }

    @objc private func turnOff() {
        // Preserve the other limits; just clear the VPN binding.
        client.setLimits(
            down: client.downLimit, up: client.upLimit, superSeed: client.superSeed,
            encryptOutgoing: client.encryptOutgoing, preferUTP: client.preferUTP, bindToVPN: false)
    }
}
