import Foundation

/// Relative ("delta") mirroring for synchronized dual-pane browsing.
///
/// When sync browsing is on, the two panes track two different roots in step: the
/// driver pane moving from one folder to another is expressed as "rise N levels,
/// then descend into this tail", and the same transform is replayed on the other
/// pane. So a left pane at `/projA` descending into `/projA/src` pulls a right pane
/// at `/projB` down into `/projB/src`, and rising back up moves both together.
public enum SyncBrowse {
    /// Where the *other* pane should navigate to mirror the driver pane's move from
    /// `prev` to `next`, given the other pane currently sits at `other`. All three are
    /// absolute POSIX paths (already standardized: no `.`, `..`, or trailing slash).
    ///
    /// Returns nil when there is nothing to mirror: an empty move (`prev == next`), or a
    /// move that would rise above the filesystem root from `other`. The result is a
    /// normalized absolute path.
    public static func mirroredPath(
        driverFrom prev: String, driverTo next: String, otherAt other: String
    ) -> String? {
        let p = components(prev), n = components(next), o = components(other)
        guard p != n else { return nil }  // no move, nothing to mirror
        // Longest common prefix of the driver's old and new paths.
        var common = 0
        while common < p.count, common < n.count, p[common] == n[common] { common += 1 }
        let ups = p.count - common  // levels the driver rose above the common ancestor
        let downs = n[common...]  // tail the driver then descended into
        guard ups <= o.count else { return nil }  // can't rise above root from the other pane
        var result = Array(o[0..<(o.count - ups)])
        result.append(contentsOf: downs)
        return result.isEmpty ? "/" : "/" + result.joined(separator: "/")
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
