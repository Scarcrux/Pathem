import AppKit
import OSLog
import PathemEngine

private let adminBadgeLog = Logger(subsystem: "com.scarcrux.pathem", category: "admin")

extension BrowserViewController {
    func observeAdminMode() {
        guard AdminModeController.isSupported else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(adminModeChanged), name: .pathemAdminModeChanged, object: nil)
    }

    func synchronizeAdminBadge(source: String) {
        guard AdminModeController.isSupported, let window = view.window else { return }
        AdminBadge.synchronize(
            in: window, unlocked: AdminModeController.shared.isUnlocked, source: source)
    }

    @objc private func adminModeChanged() {
        synchronizeAdminBadge(source: "adminModeChanged")
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
                guard !(error is CancellationError), view.window?.isVisible == true else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                let systemDenied =
                    error is AdminUnlockError || (error as NSError).domain == NSOSStatusErrorDomain
                alert.messageText =
                    systemDenied
                    ? L("admin.authorizationDenied", "macOS denied the administrator authorization")
                    : L("admin.unlockFailed", "Could not unlock Admin Mode")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L("common.ok", "OK"))
                _ = await presentSheet(alert)
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    fileprivate static func synchronize(in window: NSWindow, unlocked: Bool, source: String) {
        let accessories = window.titlebarAccessoryViewControllers
        let badges = accessories.indices.filter { accessories[$0] is AdminBadge }
        let visibleBefore = badges.contains { !accessories[$0].isHidden }

        // Do not leave a hidden Admin accessory in AppKit's titlebar while locked.
        if unlocked {
            if badges.isEmpty { window.addTitlebarAccessoryViewController(AdminBadge()) }
        } else {
            for index in badges.reversed() {
                window.removeTitlebarAccessoryViewController(at: index)
            }
        }

        let visible = window.titlebarAccessoryViewControllers.contains {
            $0 is AdminBadge && !$0.isHidden
        }
        adminBadgeLog.notice(
            "Admin badge source=\(source, privacy: .public) stateSource=liveAdminSession window=\(window.windowNumber, privacy: .public) unlocked=\(unlocked, privacy: .public) mountedBefore=\(!badges.isEmpty, privacy: .public) visibleBefore=\(visibleBefore, privacy: .public) visible=\(visible, privacy: .public)"
        )
    }

    #if DEBUG
    static func runFixture() -> Bool {
        func window() -> NSWindow {
            NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        }
        func badges(in window: NSWindow) -> [AdminBadge] {
            window.titlebarAccessoryViewControllers.compactMap { $0 as? AdminBadge }
        }

        let admin = AdminModeController.shared
        let original = window()
        synchronize(in: original, unlocked: admin.isUnlocked, source: "fixtureCreation")
        let startedLocked = badges(in: original).isEmpty
        synchronize(in: original, unlocked: true, source: "fixtureUnlock")
        synchronize(in: original, unlocked: true, source: "fixtureRepeatUnlock")
        let mounted = badges(in: original)
        let unlocked =
            mounted.count == 1
            && mounted.allSatisfy {
                !$0.isHidden && $0.view.frame.width >= 48
                    && $0.view.subviews.first?.layer?.backgroundColor == NSColor.systemRed.cgColor
            }

        // Use the same session encoder and decoder as the browser while the original
        // titlebar displays Admin. A new process starts with a locked live controller.
        let session = WindowStateStore.Session(
            left: ["/fixture"], leftActive: 0, right: ["/fixture/other"],
            rightActive: 0, leftIsActive: true)
        WindowStateStore().saveSession(session)
        let restoredSession = WindowStateStore().loadSession() == session
        original.setContentSize(NSSize(width: 580, height: 420))
        original.center()
        let frame = original.frameDescriptor
        let restored = window()
        restored.setFrame(from: frame)
        let restoredFrame = restored.frame.size == original.frame.size
        print("ADMIN FIXTURE: sessionDecoded=\(restoredSession) frameSizeRestored=\(restoredFrame)")
        synchronize(in: restored, unlocked: admin.isUnlocked, source: "fixtureSessionRestore")
        let restoredLocked =
            restoredSession && restoredFrame && !admin.isUnlocked && badges(in: restored).isEmpty

        // Negative control: a visible accessory actually mounted before a restore
        // must be removed by the locked state reconciliation.
        restored.addTitlebarAccessoryViewController(AdminBadge())
        let injectedVisible = badges(in: restored).contains { !$0.isHidden }
        synchronize(in: restored, unlocked: admin.isUnlocked, source: "fixtureStaleRestore")
        let discardedStaleBadge = injectedVisible && badges(in: restored).isEmpty

        synchronize(in: original, unlocked: admin.isUnlocked, source: "fixtureLock")
        let detachedOnLock = badges(in: original).isEmpty
        let backgroundReply = AdminModeController.checkBackgroundAuthorizationReply()
        let checks = [
            startedLocked, unlocked, restoredLocked, discardedStaleBadge, detachedOnLock,
            backgroundReply,
        ]
        for (label, passed) in zip(
            [
                "locked creation", "one visible unlock badge", "locked session restore",
                "discarded visible stale accessory", "detached on lock", "background XPC reply",
            ], checks
        ) {
            print("ADMIN FIXTURE: \(label)=\(passed)")
        }
        let passed = checks.filter { $0 }.count
        print("RESULT: \(passed == checks.count ? "PASS" : "FAIL") (\(passed)/\(checks.count))")
        return passed == checks.count
    }
    #endif
}
