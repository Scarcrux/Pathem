// Vendored from the shared AppRelaunch package (github.com/Scarcrux/AppRelaunch @ e007472),
// copied in-tree as a local target so a credential-free clone (CI, the public repo) builds
// without resolving a private dependency. Upstream stays the source of truth: re-vendor this
// file and its test when the shared package changes, rather than editing this copy in place.
import AppKit
import Foundation

/// Detects when the app bundle on disk is newer than the running process, and
/// offers the user a relaunch.
///
/// ## Why this exists
///
/// A developer-installed macOS app can silently run stale code for hours. The
/// incident that produced this: a bundle was rebuilt at 13:11 while the running
/// process had started at 03:47, so for nine hours the window on screen executed
/// pre-fix code. The only symptom was "the app is not responding" -- which sent
/// everyone hunting a bug that had already been fixed.
///
/// The obvious fix -- have the installer kill the app -- is worse. It shoots the
/// user's session down mid-thought, and with parallel agent sessions committing,
/// that happens at random. So an install must NEVER force a restart. The app
/// notices instead, and the user chooses when.
///
/// ## Contract
///
/// - Polls the installed executable's mtime by PATH, not through the open file
///   handle. That is what makes it see through an atomic install swap: the
///   installer moves the old bundle aside, so the running process keeps its
///   unlinked inode while the path resolves to the new build.
/// - Fires `onStale` at most ONCE per process, on the main actor. Staleness
///   cannot un-happen, so polling stops on the first hit.
/// - One `stat` every 30s by default, on a utility queue. Never on main.
/// - Silent under snapshot/CI harnesses, which launch and exit in seconds.
///
/// ## Usage
///
/// ```swift
/// AppRelaunch.watch(.init(appName: "MyApp")) {
///     // Surface it PERSISTENTLY (a menu item, a banner). A transient
///     // notification is missable -- that is how the nine hours happened.
///     model.updateAvailable = true
/// }
/// ```
/// then, from that surface: `AppRelaunch.relaunch()`.
public enum AppRelaunch {

    /// Tunables. Defaults suit a menu-bar or window app installed by a script.
    public struct Config: Sendable {
        /// Used in log lines so several adopting apps stay distinguishable.
        public var appName: String
        /// How often to stat the bundle.
        public var interval: TimeInterval
        /// Ignore a bundle whose mtime is within this many seconds of launch:
        /// the bundle we launched FROM is written moments before we start, so
        /// an exact-or-near match is our own build, not a newer one.
        public var graceSeconds: TimeInterval
        /// Environment variables that suppress the watch entirely (snapshot
        /// harnesses, CI). Any one being set disables it.
        public var suppressWhenEnvSet: [String]
        /// Log to stderr on detection. The whole failure mode is a signal
        /// nobody saw, so this defaults on.
        public var logToStderr: Bool

        public init(appName: String,
                    interval: TimeInterval = 30,
                    graceSeconds: TimeInterval = 5,
                    suppressWhenEnvSet: [String] = [],
                    logToStderr: Bool = true) {
            self.appName = appName
            self.interval = interval
            self.graceSeconds = graceSeconds
            self.suppressWhenEnvSet = suppressWhenEnvSet
            self.logToStderr = logToStderr
        }
    }

    /// What the watcher found, handed to the callback so a surface can say
    /// something specific ("built 12 minutes ago") instead of just "update".
    public struct StaleBuild: Sendable, Equatable {
        public let installedAt: Date
        public let launchedAt: Date
        /// How long this process has been running the older code.
        public var staleFor: TimeInterval { installedAt.timeIntervalSince(launchedAt) }

        public init(installedAt: Date, launchedAt: Date) {
            self.installedAt = installedAt
            self.launchedAt = launchedAt
        }
    }

    // MARK: - Pure policy (testable without a bundle or a clock)

    /// Whether a newer build is installed than the one running.
    ///
    /// Pure on purpose: this is the whole decision, and a wrong answer either
    /// nags constantly or never fires. Both failure modes are invisible in a
    /// build, so the policy is unit-tested rather than eyeballed.
    public static func isStale(installed: Date?,
                               launched: Date,
                               graceSeconds: TimeInterval = 5) -> Bool {
        guard let installed else { return false }
        return installed.timeIntervalSince(launched) > graceSeconds
    }

    /// The mtime of the bundle executable ON DISK (by path, see the type doc).
    public static func installedBuildDate(bundle: Bundle = .main) -> Date? {
        guard let exe = bundle.executableURL else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path)
        return attrs?[.modificationDate] as? Date
    }

    /// Human phrasing for a surface. Kept here so adopters render it the same.
    public static func describe(_ s: StaleBuild, now: Date = Date()) -> String {
        let mins = Int(now.timeIntervalSince(s.installedAt) / 60)
        if mins < 1 { return "A new build was just installed." }
        if mins < 60 { return "A new build was installed \(mins) min ago." }
        let hours = mins / 60
        return "A new build was installed \(hours)h ago."
    }

    // MARK: - Watching

    private static let lock = NSLock()
    private static var started = false
    private static var reported = false
    private static var launchedAt = Date()

    /// Begins the background poll. Idempotent; `onStale` fires at most once.
    public static func watch(_ config: Config,
                             onStale: @escaping @MainActor (StaleBuild) -> Void) {
        let env = ProcessInfo.processInfo.environment
        for key in config.suppressWhenEnvSet where env[key] != nil { return }

        lock.lock()
        if started { lock.unlock(); return }
        started = true
        launchedAt = Date()
        lock.unlock()

        let q = DispatchQueue(label: "AppRelaunch.watch.\(config.appName)", qos: .utility)
        schedule(on: q, config: config, onStale: onStale)
    }

    private static func schedule(on q: DispatchQueue,
                                 config: Config,
                                 onStale: @escaping @MainActor (StaleBuild) -> Void) {
        q.asyncAfter(deadline: .now() + config.interval) {
            lock.lock()
            let launched = launchedAt
            let already = reported
            lock.unlock()
            if already { return }

            let installed = installedBuildDate()
            guard isStale(installed: installed, launched: launched,
                          graceSeconds: config.graceSeconds), let installed else {
                schedule(on: q, config: config, onStale: onStale)
                return
            }
            lock.lock(); reported = true; lock.unlock()

            let info = StaleBuild(installedAt: installed, launchedAt: launched)
            if config.logToStderr {
                let f = ISO8601DateFormatter()
                FileHandle.standardError.write(Data(
                    "\(config.appName)-relaunch: STALE running build (installed \(f.string(from: installed)), this process launched \(f.string(from: launched)))\n".utf8))
            }
            Task { @MainActor in onStale(info) }
            // No reschedule: staleness cannot un-happen.
        }
    }

    /// Test seam: forget that the watch ran, so a test can drive it again.
    public static func resetForTesting() {
        lock.lock()
        started = false
        reported = false
        launchedAt = Date()
        lock.unlock()
    }

    // MARK: - Relaunching

    /// Quits this process and reopens the installed bundle.
    ///
    /// The reopen runs in a detached `sh` so it outlives our termination, after
    /// a beat so this instance has fully exited first -- otherwise `open` just
    /// re-activates the dying process, or a single-instance lock rejects the new
    /// one. The bundle path is passed as an ARGV element, never interpolated
    /// into the script text, so a path containing shell metacharacters cannot
    /// be executed.
    ///
    /// On failure it stays alive rather than quitting into nothing; the calling
    /// surface should remain visible so the user can retry.
    @discardableResult
    public static func relaunch(bundle: Bundle = .main,
                                terminate: () -> Void = { NSApp.terminate(nil) }) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"$1\"", "sh", bundle.bundleURL.path]
        do {
            try p.run()
            terminate()
            return true
        } catch {
            return false
        }
    }
}
