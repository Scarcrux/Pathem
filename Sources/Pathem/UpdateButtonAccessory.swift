import AppKit
import AppRelaunch

/// A trailing title-bar accessory that shows a small "Update Ready" button while a Sparkle
/// update is pending (see `UpdaterController`'s gentle-reminder wiring), and hides itself the
/// rest of the time. Clicking it opens the installer (with its release notes) -- the update is
/// visible and one click away, but never forced in front of the user. One per window.
@MainActor
final class UpdateButtonAccessory: NSTitlebarAccessoryViewController {
    private let button = NSButton()
    private weak var updater: UpdaterController?

    init(updater: UpdaterController?) {
        self.updater = updater
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing

        button.title = L("update.buttonTitle", "Update Ready")
        button.image = NSImage(
            systemSymbolName: "arrow.down.circle.fill",
            accessibilityDescription: L("update.buttonTitle", "Update Ready"))
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.bezelColor = ThemeManager.shared.accent  // a soft "there's something new" tint
        button.target = self
        button.action = #selector(openPendingUpdate)
        button.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(button)
        // The title bar sizes this container by frame, and it is empty while no update is
        // pending. Just under required, the trailing pin still sets the fitting width but
        // yields quietly to a zero-width frame instead of being broken on every launch.
        let trailing = button.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -8)
        trailing.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            trailing,
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor),
            button.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        view = container

        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: .pathemUpdateStateChanged, object: nil)
        ThemeManager.shared.onChange(owner: self) { [weak self] in
            self?.button.bezelColor = ThemeManager.shared.accent
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refresh() {
        let version = (updater ?? UpdaterController.shared)?.pendingUpdateVersion
        if let version {
            // A downloaded Sparkle update takes priority: one click installs it.
            isHidden = false
            button.title = L("update.buttonTitle", "Update Ready")
            button.image = NSImage(
                systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: button.title)
            button.action = #selector(openPendingUpdate)
            button.toolTip = L("update.buttonTooltip", "Version %@ is ready to install")
                .replacingOccurrences(
                    of: "%@", with: version)
        } else if StaleBuildState.current != nil {
            // No network update, but a newer build was installed under us: offer a relaunch.
            isHidden = false
            button.title = L("update.relaunchTitle", "Relaunch to Update")
            button.image = NSImage(
                systemSymbolName: "arrow.clockwise.circle.fill",
                accessibilityDescription: button.title)
            button.action = #selector(relaunchForUpdate)
            button.toolTip = L(
                "update.relaunchTooltip",
                "A newer build of Pathem is installed. Relaunch to run it.")
        } else {
            isHidden = true
        }
        // Hiding the accessory collapses its slot but the button can still draw past the window's
        // trailing edge as an accent-colored sliver beside the toolbar; hide the content too.
        view.isHidden = isHidden
    }

    @objc private func openPendingUpdate() {
        (updater ?? UpdaterController.shared)?.presentPendingUpdate()
    }

    @objc private func relaunchForUpdate() {
        AppRelaunch.relaunch()
    }
}
