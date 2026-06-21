import Foundation

/// Lists the immediate children of a directory.
///
/// Two implementations are planned (DESIGN.md §3-4):
///   - ``FoundationEnumerator`` — portable, correct, and the test *oracle*.
///   - `BulkEnumerator` (next milestone) — the `getattrlistbulk` hot path.
///
/// Both must satisfy this same contract, so the Foundation implementation pins
/// the expected results in tests once the bulk implementation lands. That is
/// the "contract / probe test" CONVENTIONS asks for around a load-bearing
/// system API.
public protocol DirectoryEnumerating: Sendable {
    /// Returns the immediate (non-recursive) children of `directory`.
    /// - Parameter includingHidden: when `false`, dotfiles and items with the
    ///   hidden flag are omitted.
    func entries(of directory: URL, includingHidden: Bool) throws -> [FileEntry]
}
