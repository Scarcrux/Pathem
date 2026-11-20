import AppKit

/// Detects whether Pathem has Full Disk Access. Reading the user's TCC database
/// is gated by FDA, so a successful open means we have it. Best-effort: if the
/// file is missing we assume access rather than nag.
enum FullDiskAccess {
    static func isGranted() -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_TEST"] != nil {
            return false  // Deterministic denied state; do not open the owner's TCC database.
        }
        #endif
        let path = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString)
            .expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return true }
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false  // EPERM: not granted
    }
}

/// A guided, step-by-step Full Disk Access panel: numbered steps,
/// a button straight to the Settings pane, and a live status row that flips to a
/// green check the moment access is detected, polled on a timer and whenever the
/// user returns from System Settings.
@MainActor
final class FullDiskAccessGuide: NSObject {
    private let panel: NSPanel
    private let spinner = NSProgressIndicator()
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(
        labelWithString: L("fda.waitingForAccess", "Waiting for access…"))
    private let relaunchButton = NSButton(
        title: L("fda.relaunchButton", "Relaunch Pathem"), target: nil, action: nil)
    private let primaryButton = NSButton(
        title: L("fda.notNow", "Not Now"), target: nil, action: nil)

    private weak var host: NSWindow?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private let openSettingsPane: () -> Bool
    private var openedSettings = false
    private var granted = false
    private var onDismiss: (() -> Void)?

    init(openSettingsPane: (() -> Bool)? = nil) {
        self.openSettingsPane = openSettingsPane ?? Self.openPrivacySettings
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        panel.isReleasedWhenClosed = false
        build()
    }

    private func build() {
        panel.title = L("fda.panelTitle", "Full Disk Access")

        let title = NSTextField(labelWithString: L("fda.headline", "Give Pathem Full Disk Access"))
        title.font = .boldSystemFont(ofSize: 16)
        let subtitle = NSTextField(
            wrappingLabelWithString:
                L(
                    "fda.subtitle",
                    "Your home folder works now. To browse everything (other users, system "
                        + "folders, and some app data), add Pathem to Full Disk Access."))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let openButton = NSButton(
            title: L("fda.openSettingsButton", "Open Full Disk Access Settings"), target: self,
            action: #selector(openSettings))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        statusIcon.isHidden = true
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        statusLabel.font = .systemFont(ofSize: 12)
        let statusRow = NSStackView(views: [spinner, statusIcon, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6

        relaunchButton.target = self
        relaunchButton.action = #selector(relaunch)
        relaunchButton.bezelStyle = .rounded
        relaunchButton.isHidden = true
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.bezelStyle = .rounded
        // Start subdued: this is "Not Now" (a dismiss), so it must not read as the primary action --
        // the blue "Open Full Disk Access Settings" button above is. updateStatus() makes it a
        // prominent default only once it becomes "Done".
        primaryButton.isBordered = false
        primaryButton.contentTintColor = .secondaryLabelColor

        let buttonRow = NSStackView(views: [NSView(), relaunchButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let step1 = stepRow(1, L("fda.step1", "Click the button below to open the settings pane."))
        let step2 = stepRow(
            2,
            L(
                "fda.step2",
                "Click + and add Pathem from Applications. macOS may ask for your password."))
        let step3 = stepRow(
            3, L("fda.step3", "After adding Pathem, use Relaunch Pathem here to apply access."))
        let stack = NSStackView(views: [
            title, subtitle, step1, openButton, step2, step3,
            separator,
            statusRow,
            buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            step1.widthAnchor.constraint(equalTo: stack.widthAnchor),
            step2.widthAnchor.constraint(equalTo: stack.widthAnchor),
            step3.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    /// A numbered step: a small accent circle with the number, then the text.
    private func stepRow(_ number: Int, _ text: String) -> NSView {
        let badge = NSTextField(labelWithString: "\(number)")
        badge.alignment = .center
        badge.font = .boldSystemFont(ofSize: 12)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = ThemeManager.shared.accent.cgColor
        badge.layer?.cornerRadius = 11
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 22).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [badge, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    func present(over window: NSWindow, onDismiss: @escaping () -> Void) {
        if host === window {
            panel.makeKey()
            return
        }
        guard host == nil, window.attachedSheet == nil else { return }

        self.host = window
        self.onDismiss = onDismiss
        granted = FullDiskAccess.isGranted()
        openedSettings = false
        updateStatus()

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(hostWillClose), name: NSWindow.willCloseNotification,
            object: window)
        panel.setFrameOrigin(
            NSPoint(
                x: window.frame.midX - panel.frame.width / 2,
                y: window.frame.midY - panel.frame.height / 2))
        // AppKit can refuse Quit AppleEvents while a sheet is attached, before the app's
        // delegate can act. A child window keeps the guide above its browser without modality.
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    private func check() {
        guard !granted else { return }
        if FullDiskAccess.isGranted() {
            granted = true
            updateStatus()
        } else if openedSettings {
            // Settings opened from this presentation. A relaunch applies the grant.
            statusLabel.stringValue = L(
                "fda.addedRelaunchHint", "Added Pathem? A relaunch will apply it.")
            relaunchButton.isHidden = false
        }
    }

    private func updateStatus() {
        if granted {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            statusIcon.image = NSImage(
                systemSymbolName: "checkmark.circle.fill",
                accessibilityDescription: L("fda.grantedA11y", "Granted"))
            statusIcon.contentTintColor = .systemGreen
            statusIcon.isHidden = false
            statusLabel.stringValue = L("fda.grantedStatus", "Full Disk Access granted.")
            relaunchButton.isHidden = true
            // Now the affirmative action: promote it to the prominent default (blue, Enter).
            primaryButton.title = L("common.done", "Done")
            primaryButton.keyEquivalent = "\r"
            primaryButton.isBordered = true
            primaryButton.contentTintColor = nil
        } else {
            spinner.isHidden = false
            spinner.startAnimation(nil)
            statusIcon.isHidden = true
            statusLabel.stringValue = L("fda.waitingForAccess", "Waiting for access…")
            relaunchButton.isHidden = true
            // Still just the "Not Now" dismiss: keep it subdued behind the Open Settings button.
            primaryButton.title = L("fda.notNow", "Not Now")
            primaryButton.keyEquivalent = ""
            primaryButton.isBordered = false
            primaryButton.contentTintColor = .secondaryLabelColor
        }
    }

    @objc private func openSettings() {
        if openSettingsPane() {
            openedSettings = true
            check()
        }
    }

    private static func openPrivacySettings() -> Bool {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return false }
        return NSWorkspace.shared.open(url)
    }

    @objc private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc private func primaryClicked() { dismiss(notify: true) }

    @objc private func hostWillClose(_ notification: Notification) { dismiss(notify: false) }

    private func dismiss(notify: Bool) {
        guard let host else { return }
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        self.host = nil
        let callback = onDismiss
        onDismiss = nil
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: host)
        host.removeChildWindow(panel)
        panel.orderOut(nil)
        if notify { callback?() }
    }
}
