import AppKit
import PathemEngine

extension BrowserViewController {
    func installAdminBadge() {
        guard AdminModeController.isSupported, let window = view.window,
            !window.titlebarAccessoryViewControllers.contains(where: { $0 is AdminBadge })
        else { return }
        window.addTitlebarAccessoryViewController(AdminBadge())
        NotificationCenter.default.addObserver(
            self, selector: #selector(adminModeChanged), name: .pathemAdminModeChanged, object: nil)
    }

    @objc private func adminModeChanged() {
        // Revoking the session also discards the displayed privileged listing.
        reloadBothSides()
    }

    func unlockAdminMode() {
        guard AdminModeController.isSupported else { return }
        let admin = AdminModeController.shared
        if admin.needsSetup {
            // Setup and authorization are separate actions. From Settings the user can
            // enroll the helper, then return here to unlock for this session.
            activePane?.flashStatus(
                L(
                    "admin.setupHint",
                    "Set up the Admin Helper in Settings, then approve it in Login Items."),
                isError: true)
            return
        }
        Task { @MainActor in
            do { try await admin.unlock(minutes: prefs.adminSessionMinutes) } catch {
                if !(error is CancellationError) {
                    self.activePane?.flashStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    /// Use only after the ordinary call failed. Returns nil for ordinary errors and while locked,
    /// so the caller can retain its original error handling and undo behavior.
    func retryAsAdmin(_ request: AdminFileRequest, after originalError: Error) async throws -> Data?
    {
        guard AdminModeController.isSupported else { return nil }
        let admin = AdminModeController.shared
        guard admin.mayRetry(originalError) else { return nil }
        let result = try await admin.perform(request)
        activePane?.flashStatus(
            String(
                format: L("admin.used", "Used Admin Mode for %@"),
                (request.source as NSString).lastPathComponent))
        return result
    }
}

@MainActor
final class AdminBadge: NSTitlebarAccessoryViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
        let label = NSTextField(labelWithString: L("admin.badge", "Admin"))
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        let width = max(48, ceil(label.fittingSize.width) + 14)
        let badge = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 19))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        label.frame = NSRect(x: 0, y: 2, width: width, height: 15)
        badge.addSubview(label)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width + 8, height: 19))
        container.addSubview(badge)
        view = container
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: .pathemAdminModeChanged, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func refresh() {
        showUnlocked(AdminModeController.shared.isUnlocked)
    }

    private func showUnlocked(_ unlocked: Bool) {
        isHidden = !unlocked
    }

    #if DEBUG
    static func runFixture() -> Bool {
        let badge = AdminBadge()
        let startedLocked = badge.isHidden
        badge.showUnlocked(true)
        let unlocked =
            !badge.isHidden && badge.view.frame.width >= 48
            && badge.view.subviews.first?.layer?.backgroundColor == NSColor.systemRed.cgColor
        badge.showUnlocked(false)
        let relocked = badge.isHidden
        let passed = [startedLocked, unlocked, relocked].filter { $0 }.count
        print("RESULT: \(passed == 3 ? "PASS" : "FAIL") (\(passed)/3)")
        return passed == 3
    }
    #endif
}
