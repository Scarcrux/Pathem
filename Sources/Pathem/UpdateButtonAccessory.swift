import AppKit

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
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
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
        isHidden = version == nil
        if let version {
            button.toolTip = L("update.buttonTooltip", "Version %@ is ready to install").replacingOccurrences(
                of: "%@", with: version)
        }
    }

    @objc private func openPendingUpdate() {
        (updater ?? UpdaterController.shared)?.presentPendingUpdate()
    }
}
