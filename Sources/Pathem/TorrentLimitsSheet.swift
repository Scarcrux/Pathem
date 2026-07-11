import AppKit

/// The Speed Limits sheet: global download/upload caps plus the super-seed, MSE-encryption, µTP, and
/// VPN-binding toggles, with a live VPN status line. Shared by the torrents drawer.
@MainActor
enum TorrentLimitsSheet {
    static func present(over window: NSWindow?, client: TorrentDaemonClient) {
        let alert = NSAlert()
        alert.messageText = L("torrents.limits.title", "Speed Limits")
        alert.informativeText = L("torrents.limits.message", "Maximum download and upload speed in KB/s. Leave 0 for unlimited.")
        alert.addButton(withTitle: L("torrents.limits.apply", "Apply"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))

        func field(_ bytesPerSecond: Int) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 70, y: 0, width: 90, height: 22))
            f.integerValue = bytesPerSecond / 1024
            f.alignment = .right
            return f
        }
        let downField = field(client.downLimit)
        let upField = field(client.upLimit)
        let superSeed = NSButton(checkboxWithTitle: L("torrents.limits.superSeed", "Super-seed (efficient initial seeding)"), target: nil, action: nil)
        superSeed.state = client.superSeed ? .on : .off
        let encrypt = NSButton(checkboxWithTitle: L("torrents.limits.encrypt", "Encrypt outgoing connections (MSE)"), target: nil, action: nil)
        encrypt.state = client.encryptOutgoing ? .on : .off
        let utp = NSButton(checkboxWithTitle: L("torrents.limits.utp", "Prefer µTP (BEP 29), fall back to TCP"), target: nil, action: nil)
        utp.state = client.preferUTP ? .on : .off
        let vpn = NSButton(checkboxWithTitle: L("torrents.limits.vpn", "Bind torrents to a VPN (kill-switch when it drops)"), target: nil, action: nil)
        vpn.state = client.bindToVPN ? .on : .off
        let vpnStatus = NSTextField(labelWithString: vpnStatusLine(client))
        vpnStatus.font = .systemFont(ofSize: 11)
        vpnStatus.textColor = client.bindToVPN && client.vpnInterface == nil ? .systemRed : .secondaryLabelColor

        let container = NSStackView(views: [
            labeledRow(L("torrents.limits.down", "Download"), downField),
            labeledRow(L("torrents.limits.up", "Upload"), upField),
            superSeed, encrypt, utp, vpn, vpnStatus,
        ])
        container.orientation = .vertical
        container.spacing = 8
        container.alignment = .leading
        container.frame = NSRect(x: 0, y: 0, width: 340, height: 168)
        alert.accessoryView = container
        alert.window.initialFirstResponder = downField

        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            client.setLimits(
                down: max(0, downField.integerValue) * 1024, up: max(0, upField.integerValue) * 1024,
                superSeed: superSeed.state == .on, encryptOutgoing: encrypt.state == .on,
                preferUTP: utp.state == .on, bindToVPN: vpn.state == .on)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    private static func labeledRow(_ title: String, _ field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
        let unit = NSTextField(labelWithString: L("torrents.limits.unit", "KB/s"))
        let row = NSStackView(views: [label, field, unit])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private static func vpnStatusLine(_ client: TorrentDaemonClient) -> String {
        guard client.bindToVPN else {
            return L("torrents.vpn.off", "Not bound. Torrents use your normal connection.")
        }
        if let iface = client.vpnInterface {
            return String(format: L("torrents.vpn.bound", "Bound to %@. Traffic only leaves over the VPN."), iface)
        }
        return L("torrents.vpn.killed", "No VPN detected. Torrents paused to prevent leaks.")
    }
}
