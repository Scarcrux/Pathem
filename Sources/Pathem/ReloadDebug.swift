import Foundation

/// Opt-in tracing for the "why is the pane flashing while the app is in the background" class of
/// bug. Set `PATHEM_DEBUG_RELOADS=1` and Pathem appends a timestamped line to
/// `~/pathem-reloads.log` every time a repeated-work suspect fires (a pane reload, an FSEvent-driven
/// refresh, a view-mode swap, a git-status refresh, an active-state change, a device poll). Leave it
/// unset and every call is a cheap early return -- no file, no overhead.
///
/// Reproduce the flash with it on, then read the log: a burst of `reload`/`fsevent` lines every
/// fraction of a second on the same folder points at watcher churn (a cloud-syncing folder); a
/// steady `viewmode-swap` or `setActive` cadence points elsewhere.
enum ReloadDebug {
    /// On when `PATHEM_DEBUG_RELOADS` is set OR the marker file `~/.pathem-debug-reloads` exists --
    /// the marker lets tracing be turned on for a normally launched (Dock/Finder) app, no Terminal
    /// needed: `touch ~/.pathem-debug-reloads`, launch, reproduce, then `rm` it.
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["PATHEM_DEBUG_RELOADS"] != nil { return true }
        let marker = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pathem-debug-reloads")
        return FileManager.default.fileExists(atPath: marker.path)
    }()

    private static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("pathem-reloads.log")
    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Append one timestamped line (no-op unless PATHEM_DEBUG_RELOADS is set).
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let line = "\(stamp.string(from: Date()))  \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)  // first line creates the file
        }
    }
}
