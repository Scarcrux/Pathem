import AppKit

/// Notices when the INSTALLED app bundle on disk is newer than this running process -- i.e. a
/// rebuild + reinstall landed and the window on screen is now executing stale code. This is the
/// local-install counterpart to Sparkle (which delivers released updates over the network): it
/// covers the case Sparkle never sees, where the bundle is replaced under a still-running process
/// (a `make install`, or a drag-install of a newer copy without quitting first).
///
/// Adapted from the commandem menubar's AppUpdateWatch. The detection lives IN the app so it can be
/// a *persistent* affordance (the title-bar "Relaunch to Update" button) rather than a missable
/// banner -- the user stays in control of WHEN to relaunch, but can't be silently stale.
enum StaleBuildWatch {
    private static let lock = NSLock()
    // Hand-synchronized with `lock` (written on the watch queue, read on main), so the manual
    // safety is what `nonisolated(unsafe)` documents.
    nonisolated(unsafe) private static var launchedAt = Date()
    nonisolated(unsafe) private static var started = false
    /// True once a newer build has been seen on disk. Read by `UpdateButtonAccessory`.
    nonisolated(unsafe) private(set) static var isStale = false

    /// How often to stat the bundle. A rebuild is a minutes-long event and the check is one `stat`,
    /// so this is deliberately lazy -- it must never register as background cost.
    private static let interval: TimeInterval = 30

    /// The mtime of the bundle executable ON DISK. Reads a PATH (not our open handle), so it sees the
    /// newly-installed executable even though this process keeps its old (unlinked) inode.
    static func installedBuildDate() -> Date? {
        guard let exe = Bundle.main.executableURL else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: exe.path))?[.modificationDate] as? Date
    }

    /// Whether a strictly-newer build is installed than the one running. Pure, so the policy is
    /// unit-testable. The 5s grace absorbs the gap between writing our own bundle and launching it.
    static func isStale(installed: Date?, launched: Date) -> Bool {
        guard let installed else { return false }
        return installed.timeIntervalSince(launched) > 5
    }

    /// Begin the background poll (idempotent). Skipped under the automation/smoke harnesses, which
    /// launch, do their checks, and exit.
    @MainActor
    static func start() {
        guard !PathemApp.isAutomationLaunch else { return }
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        launchedAt = Date()
        lock.unlock()
        schedule(on: DispatchQueue(label: "com.scarcrux.pathem.stalebuildwatch", qos: .utility))
    }

    private static func schedule(on queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + interval) {
            lock.lock()
            let launched = launchedAt
            let already = isStale
            lock.unlock()
            if !already, isStale(installed: installedBuildDate(), launched: launched) {
                lock.lock(); isStale = true; lock.unlock()
                let built = installedBuildDate().map { ISO8601DateFormatter().string(from: $0) } ?? "?"
                FileHandle.standardError.write(Data(
                    "pathem-stalebuildwatch: a newer build is installed (\(built)); this process is stale\n".utf8))
                // Refresh the title-bar update accessory, which now offers "Relaunch to Update".
                Task { @MainActor in
                    NotificationCenter.default.post(name: .pathemUpdateStateChanged, object: nil)
                }
                return  // stop polling; the state cannot un-stale
            }
            schedule(on: queue)
        }
    }

    /// Quit this process and reopen the installed bundle. The reopen is handed to a detached `sh`
    /// that sleeps a beat so this instance has fully exited before `open` fires; the bundle path is
    /// passed as an argv element (never interpolated into the script), so a path with shell
    /// metacharacters can't be executed.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open \"$1\"", "sh", Bundle.main.bundleURL.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            // Couldn't spawn the relauncher; stay alive rather than quit into nothing. The button
            // remains, so the user can retry.
        }
    }
}
