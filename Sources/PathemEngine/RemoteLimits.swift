import Foundation

/// A global transfer-speed cap honored by the out-of-process backends. The browser sets
/// it from Preferences; each provider appends the right rate-limit flag when building its
/// curl / sftp command. 0 means unlimited.
public enum RemoteLimits {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _bandwidthKBps = 0

    /// Cap in kilobytes per second (0 = unlimited).
    public static var bandwidthKBps: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _bandwidthKBps
        }
        set {
            lock.lock()
            _bandwidthKBps = max(0, newValue)
            lock.unlock()
        }
    }

    /// `curl --limit-rate` flag for the current cap (KB/s), or empty when unlimited.
    public static var curlArgs: [String] {
        let kbps = bandwidthKBps
        return kbps > 0 ? ["--limit-rate", "\(kbps)k"] : []
    }

    /// `sftp -l` flag for the current cap. sftp's limit is in Kbit/s, so KB/s * 8.
    public static var sftpArgs: [String] {
        let kbps = bandwidthKBps
        return kbps > 0 ? ["-l", "\(kbps * 8)"] : []
    }
}
