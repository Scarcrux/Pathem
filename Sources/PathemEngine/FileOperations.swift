import Foundation

/// Bulk file operations behind copy/move (between panes, and the clipboard).
///
/// Each item is attempted independently. When a name already exists at the
/// destination the caller picks a `ConflictResolution`: skip it, replace it (the
/// existing item goes to the Trash, so it is recoverable), or keep both (the new
/// item is renamed "x copy"). Every operation records what it did so the UI can
/// offer undo. Sources can be given by name within a folder, or as full URLs
/// (so a paste can pull from any location, including a Finder copy).
public enum FileOperations {
    public struct Failure: Error, Equatable, Sendable {
        public let name: String
        public let reason: String
        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    public enum ConflictResolution: Sendable { case skip, replace, keepBoth }

    public enum Action: Sendable { case copied, moved }

    /// One item that was actually copied or moved. Enough to reverse it.
    public struct Performed: Sendable, Equatable {
        public let action: Action
        public let source: URL
        public let destination: URL
        /// If a Replace conflict trashed an existing item at `destination`, where it
        /// landed in the Trash, so undo can restore the overwritten file.
        public let replacedOriginalTrashed: URL?
        public init(action: Action, source: URL, destination: URL, replacedOriginalTrashed: URL? = nil) {
            self.action = action
            self.source = source
            self.destination = destination
            self.replacedOriginalTrashed = replacedOriginalTrashed
        }
    }

    public struct Outcome: Sendable {
        public var performed: [Performed] = []
        public var skipped: [String] = []
        public var failures: [Failure] = []
        public init() {}
    }

    /// A running snapshot of a transfer, for a byte-based progress bar with speed/ETA.
    public struct Progress: Sendable {
        public var completedBytes: Int64
        public var totalBytes: Int64
        public var completedItems: Int
        public var totalItems: Int
        /// The item currently being transferred (its last path component).
        public var currentFile: String
        public init(
            completedBytes: Int64 = 0, totalBytes: Int64 = 0, completedItems: Int = 0,
            totalItems: Int = 0, currentFile: String = ""
        ) {
            self.completedBytes = completedBytes
            self.totalBytes = totalBytes
            self.completedItems = completedItems
            self.totalItems = totalItems
            self.currentFile = currentFile
        }
    }

    /// Total logical size of these items (recursing into folders), for a transfer's
    /// progress denominator. Unreadable items count as zero rather than failing.
    public static func totalBytes(of urls: [URL]) -> Int64 {
        urls.reduce(0) { $0 + byteCount(of: $1) }
    }

    static func byteCount(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        // A symlink is copied as the link itself (copyItem does not follow it), so it
        // transfers ~0 bytes; counting its target would wildly inflate the denominator
        // (isDirectoryKey resolves a link-to-directory to `true` and would recurse the
        // whole target tree). Treat it as zero.
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }
        let fm = FileManager.default
        // Include hidden files (copyItem copies them); skip symlink descendants, which
        // FileManager surfaces but copyItem recreates as links rather than their targets.
        guard
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [])
        else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let v = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { continue }
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: Conflict detection

    public static func conflicts(_ names: [String], from source: URL, to destination: URL) -> [String]
    {
        conflicts(urls: names.map { source.appendingPathComponent($0) }, into: destination)
    }

    public static func conflicts(urls: [URL], into destination: URL) -> [String] {
        urls.compactMap { url in
            let name = url.lastPathComponent
            let exists = FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(name).path)
            return exists ? name : nil
        }
    }

    // MARK: New folder

    /// Create a new folder in `directory`, picking a unique "untitled folder"
    /// name (Finder-style) when the base name is taken. Returns the name created.
    @discardableResult
    public static func makeFolder(in directory: URL, baseName: String = "untitled folder") throws -> String {
        let fm = FileManager.default
        var name = baseName
        var n = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(baseName) \(n)"
            n += 1
        }
        try fm.createDirectory(
            at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
        return name
    }

    // MARK: New file

    /// Create a new empty file in `directory`, picking a unique name (Finder-style)
    /// when the base name is taken. A number is inserted before the extension, so
    /// "note.txt" becomes "note 2.txt". Returns the name created.
    @discardableResult
    public static func makeFile(in directory: URL, baseName: String = "untitled file") throws -> String {
        let fm = FileManager.default
        let ext = (baseName as NSString).pathExtension
        let stem = ext.isEmpty ? baseName : (baseName as NSString).deletingPathExtension
        func assemble(_ s: String) -> String { ext.isEmpty ? s : "\(s).\(ext)" }
        var name = baseName
        var n = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = assemble("\(stem) \(n)")
            n += 1
        }
        guard fm.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return name
    }

    // MARK: Duplicate

    /// Duplicate `name` in `directory` as "<name> copy[.ext]" (Finder-style), picking a
    /// unique suffix. Works for files and folders. Returns the created name.
    @discardableResult
    public static func duplicate(_ name: String, in directory: URL) throws -> String {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        func assemble(_ s: String) -> String { ext.isEmpty ? s : "\(s).\(ext)" }
        var dest = assemble("\(stem) copy")
        var n = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(dest).path) {
            dest = assemble("\(stem) copy \(n)")
            n += 1
        }
        try fm.copyItem(
            at: directory.appendingPathComponent(name), to: directory.appendingPathComponent(dest))
        return dest
    }

    // MARK: Rename

    /// Rename a single item. Throws if the destination exists (no clobber) or the
    /// move fails; a no-op when the name is unchanged or empty.
    public static func rename(_ name: String, to newName: String, in directory: URL) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }
        // A slash is the path separator (appendingPathComponent would move into a nonexistent
        // subfolder and fail cryptically); NUL terminates a C string. Reject both with a clear error
        // instead of a confusing move failure.
        guard !trimmed.contains("/"), !trimmed.contains("\0") else { throw InvalidNameError(name: trimmed) }
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent(name),
            to: directory.appendingPathComponent(trimmed))
    }

    public struct InvalidNameError: LocalizedError {
        public let name: String
        public var errorDescription: String? {
            "“\(name)” isn’t a valid file name. A name can’t contain a slash (/)."
        }
    }

    // MARK: Trash

    /// A trashed item plus where it landed, so a move-to-trash can be undone.
    public struct Trashed: Sendable, Equatable {
        public let original: URL
        public let trashed: URL
        public init(original: URL, trashed: URL) {
            self.original = original
            self.trashed = trashed
        }
    }

    /// Move `names` in `directory` to the Trash. Returns the trashed items (for
    /// undo) and any failures.
    public static func trash(_ names: [String], in directory: URL)
        -> (trashed: [Trashed], failures: [Failure])
    {
        trash(urls: names.map { directory.appendingPathComponent($0) })
    }

    /// Move the given file URLs to the Trash (they may span folders, e.g. a
    /// smart-result selection). Returns the trashed items (for undo) and failures.
    public static func trash(urls: [URL]) -> (trashed: [Trashed], failures: [Failure]) {
        let fm = FileManager.default
        var trashed: [Trashed] = []
        var failures: [Failure] = []
        for source in urls {
            var resulting: NSURL?
            do {
                try fm.trashItem(at: source, resultingItemURL: &resulting)
                if let landed = resulting as URL? {
                    trashed.append(Trashed(original: source, trashed: landed))
                }
            } catch {
                failures.append(Failure(name: source.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return (trashed, failures)
    }

    /// Restore trashed items to their original locations (the undo of `trash`). If
    /// the original location was reoccupied, restore under a non-colliding name and
    /// report it, so the file comes back instead of the undo silently failing.
    /// The result of restoring items from the Trash: where each one actually landed (so a redo
    /// re-trashes the real file, not whatever unrelated file now sits at the recorded original
    /// path), plus any failures.
    public struct UntrashResult: Sendable {
        public var restored: [URL]  // the actual restored locations, in input order (successes only)
        public var failures: [Failure]
        public init(restored: [URL] = [], failures: [Failure] = []) {
            self.restored = restored
            self.failures = failures
        }
    }

    @discardableResult
    public static func untrash(_ items: [Trashed]) -> UntrashResult {
        let fm = FileManager.default
        var result = UntrashResult()
        for item in items {
            let destination = fm.fileExists(atPath: item.original.path)
                ? uniqueDestination(item.original) : item.original
            do {
                try fm.moveItem(at: item.trashed, to: destination)
                result.restored.append(destination)
                if destination != item.original {
                    result.failures.append(
                        Failure(
                            name: item.original.lastPathComponent,
                            reason:
                                "the original location was taken; restored as \"\(destination.lastPathComponent)\""))
                }
            } catch {
                result.failures.append(
                    Failure(name: item.original.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return result
    }

    // MARK: Copy / move

    @discardableResult
    public static func copy(
        _ names: [String], from source: URL, to destination: URL,
        onConflict: ConflictResolution = .skip
    ) -> Outcome {
        copy(urls: names.map { source.appendingPathComponent($0) }, into: destination, onConflict: onConflict)
    }

    @discardableResult
    public static func move(
        _ names: [String], from source: URL, to destination: URL,
        onConflict: ConflictResolution = .skip
    ) -> Outcome {
        move(urls: names.map { source.appendingPathComponent($0) }, into: destination, onConflict: onConflict)
    }

    /// A copy whose SHA-256 didn't match the source (verification was on). The bad copy is
    /// removed before this is thrown, so no corrupt file is left behind.
    public struct CopyVerificationError: LocalizedError {
        public let name: String
        public var errorDescription: String? {
            "Verification failed: the copy of \(name) doesn’t match the original."
        }
    }

    /// A cross-volume move that copied `name` but then could neither remove the original nor roll the
    /// copy back, so a duplicate remains at the destination. Surfaced so the user isn't left with an
    /// unexplained stray copy after a bare "move failed".
    public struct MoveIncompleteError: LocalizedError {
        public let name: String
        public var errorDescription: String? {
            "Couldn’t finish moving \(name): the original couldn’t be removed, and a copy was left at the destination."
        }
    }

    @discardableResult
    public static func copy(
        urls: [URL], into destination: URL, onConflict: ConflictResolution = .skip,
        verify: Bool = false,
        shouldCancel: @escaping () -> Bool = { false }, report: @escaping (Progress) -> Void = { _ in }
    ) -> Outcome {
        apply(
            urls, into: destination, action: .copied, onConflict: onConflict,
            shouldCancel: shouldCancel, report: report
        ) { source, dest, onBytes in
            // Stream the copy so the bar/speed/ETA move as the bytes land (metadata-preserving,
            // cancellable), instead of the opaque all-or-nothing of FileManager.copyItem.
            try ProgressiveCopy.copy(from: source, to: dest, onBytes: onBytes, shouldCancel: shouldCancel)
            // Verify files by SHA-256 (a directory hashes to nil on both sides, so it passes
            // through); a mismatch means a corrupt copy -- remove it and fail that item.
            if verify {
                let matched = (try? FileHasher.hash(source)) == (try? FileHasher.hash(dest))
                if !matched {
                    try? FileManager.default.removeItem(at: dest)
                    throw CopyVerificationError(name: source.lastPathComponent)
                }
            }
        }
    }

    @discardableResult
    public static func move(
        urls: [URL], into destination: URL, onConflict: ConflictResolution = .skip,
        shouldCancel: @escaping () -> Bool = { false }, report: @escaping (Progress) -> Void = { _ in }
    ) -> Outcome {
        apply(
            urls, into: destination, action: .moved, onConflict: onConflict,
            shouldCancel: shouldCancel, report: report
        ) { source, dest, onBytes in
            // A same-volume move is an instant rename (same inode, no bytes copied). A cross-volume
            // move must physically copy then delete the source, so stream it with progress and only
            // unlink the source once the copy fully lands -- rolling the copy back if the delete
            // fails, so the move stays all-or-nothing.
            if sameVolume(source, dest) {
                try FileManager.default.moveItem(at: source, to: dest)
            } else {
                try ProgressiveCopy.copy(from: source, to: dest, onBytes: onBytes, shouldCancel: shouldCancel)
                do {
                    try FileManager.default.removeItem(at: source)
                } catch {
                    // The copy landed but the source couldn't be removed, so the move didn't complete.
                    // Roll the copy back so there's no duplicate; if the rollback ALSO fails, a stray
                    // copy is left at the destination -- say so explicitly rather than reporting a bare
                    // "move failed" that hides the duplicate.
                    do {
                        try FileManager.default.removeItem(at: dest)
                    } catch {
                        throw MoveIncompleteError(name: source.lastPathComponent)
                    }
                    throw error
                }
            }
        }
    }

    /// Whether `source` and the folder that will hold `dest` live on the same volume. A move
    /// within a volume is a cheap rename; across volumes it is a copy + delete. An unknown
    /// volume identifier falls back to "different" so we take the safe, progress-reporting path.
    static func sameVolume(_ source: URL, _ dest: URL) -> Bool {
        let destDir = dest.deletingLastPathComponent()
        let a = try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let b = try? destDir.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        if let a = a as? NSObject, let b = b as? NSObject { return a.isEqual(b) }
        return false
    }

    /// Reverse a set of performed operations: moves go back to their source,
    /// copies go to the Trash. Used to implement undo.
    @discardableResult
    public static func undo(_ performed: [Performed]) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for op in performed {
            do {
                switch op.action {
                case .moved:
                    guard !fm.fileExists(atPath: op.source.path) else {
                        outcome.failures.append(
                            Failure(
                                name: op.destination.lastPathComponent,
                                reason: "original location is occupied"))
                        continue
                    }
                    try fm.moveItem(at: op.destination, to: op.source)
                case .copied:
                    try fm.trashItem(at: op.destination, resultingItemURL: nil)
                }
                // Restore a file that a Replace conflict overwrote, so undo doesn't
                // leave it stranded in the Trash (and report failure if it can't).
                if let trashed = op.replacedOriginalTrashed {
                    do {
                        try fm.moveItem(at: trashed, to: op.destination)
                    } catch {
                        outcome.failures.append(
                            Failure(
                                name: op.destination.lastPathComponent,
                                reason: "couldn't restore the replaced file: \(error.localizedDescription)"))
                    }
                }
                outcome.performed.append(op)
            } catch {
                outcome.failures.append(
                    Failure(name: op.destination.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return outcome
    }

    /// Re-apply performed operations (the redo of `undo`): moves and copies go from source to
    /// their recorded destination again. Replace-aware: if the op originally overwrote a file
    /// (undo restored it to the destination), re-trash that restored file first and record the
    /// new trash location, so the returned Performed can undo the redo correctly. Returns only
    /// the ops that actually re-applied, so the caller re-registers undo for exactly those.
    @discardableResult
    public static func redo(_ performed: [Performed]) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for op in performed {
            do {
                var replacedTrash: URL?
                // Undo of a Replace restored the overwritten original to the destination. Redo must
                // displace it again (to a fresh trash location), or the copy/move below fails
                // "file exists" and a later undo would trash the restored original by mistake.
                if op.replacedOriginalTrashed != nil, fm.fileExists(atPath: op.destination.path) {
                    var landed: NSURL?
                    try fm.trashItem(at: op.destination, resultingItemURL: &landed)
                    replacedTrash = landed as URL?
                }
                switch op.action {
                case .moved: try fm.moveItem(at: op.source, to: op.destination)
                case .copied: try fm.copyItem(at: op.source, to: op.destination)
                }
                outcome.performed.append(
                    Performed(
                        action: op.action, source: op.source, destination: op.destination,
                        replacedOriginalTrashed: replacedTrash))
            } catch {
                outcome.failures.append(
                    Failure(name: op.destination.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return outcome
    }

    // MARK: Core

    private static func apply(
        _ sources: [URL], into destination: URL,
        action: Action, onConflict: ConflictResolution,
        shouldCancel: @escaping () -> Bool, report: @escaping (Progress) -> Void,
        _ op: (URL, URL, _ onItemBytes: @escaping (Int64) -> Void) throws -> Void
    ) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        let totalBytes = totalBytes(of: sources)
        var progress = Progress(totalBytes: totalBytes, totalItems: sources.count)
        for (index, from) in sources.enumerated() {
            if shouldCancel() { break }  // stop; items already done remain in `performed`
            let name = from.lastPathComponent
            progress.currentFile = name
            report(progress)  // name the item before the (possibly slow) copy starts
            let itemBytes = byteCount(of: from)
            let base = progress.completedBytes  // bytes fully done before this item
            var to = destination.appendingPathComponent(name)
            var replacedTrash: URL?  // where a Replace put the overwritten file (for undo)
            do {
                // Never act on the source onto itself: a no-op self-transfer via a
                // different spelling, a symlink, or letter case on a case-insensitive
                // volume would otherwise trash the source under .replace. This is the
                // backstop for every caller (drag-drop, transfer commands, undo/redo).
                if Self.isSameItem(from, to) {
                    // Pasting/copying an item into its own folder with Keep Both should make a
                    // duplicate ("file copy"), not silently no-op; any other resolution skips
                    // (and .replace must never trash the source onto itself).
                    guard onConflict == .keepBoth else {
                        outcome.skipped.append(name)
                        continue
                    }
                    to = uniqueDestination(to)
                }
                // Never nest a folder inside its own subtree (the destination is `from` or lives
                // under it). The app guards this too; this is the engine backstop so a copy can't
                // recurse into itself and duplicate the tree until the path length blows up.
                if Self.isDescendant(to, of: from) {
                    outcome.failures.append(Failure(name: name, reason: "A folder can’t be moved inside itself."))
                    continue
                }
                if fm.fileExists(atPath: to.path) {
                    switch onConflict {
                    case .skip:
                        outcome.skipped.append(name)
                        continue
                    case .replace:
                        var landed: NSURL?
                        try fm.trashItem(at: to, resultingItemURL: &landed)
                        replacedTrash = landed as URL?  // remember it so undo can restore it
                    case .keepBoth:
                        to = uniqueDestination(to)
                    }
                }
                do {
                    try op(from, to) { copiedInItem in
                        // Live intra-file progress: cap at the item's own size so a slightly
                        // ahead-of-itself count never pushes the bar past this item.
                        progress.completedBytes = base + min(copiedInItem, itemBytes)
                        report(progress)
                    }
                } catch {
                    // Replace already trashed the old destination. If the op then fails, restore it
                    // so a failed replace doesn't silently leave the user's file in the Trash.
                    if let trashed = replacedTrash {
                        try? fm.moveItem(at: trashed, to: to)
                    }
                    throw error
                }
                outcome.performed.append(
                    Performed(
                        action: action, source: from, destination: to, replacedOriginalTrashed: replacedTrash))
                // Only a file that actually transferred advances the byte counter, so a
                // failure doesn't inflate the bar the way a completed item would. Skips
                // (handled by `continue` above) likewise never reach this line. Set (not +=)
                // to the exact total so intra-file reporting granularity can't drift the count.
                progress.completedBytes = base + itemBytes
            } catch is ProgressiveCopy.Cancelled {
                // User cancelled mid-file: the partial destination was already removed, so drop
                // its bytes and stop cleanly without recording a failure.
                progress.completedBytes = base
                break
            } catch {
                progress.completedBytes = base  // a failed item contributes nothing to the bar
                outcome.failures.append(Failure(name: name, reason: error.localizedDescription))
            }
            progress.completedItems = index + 1
            report(progress)
        }
        return outcome
    }

    /// Whether two URLs refer to the same on-disk item. Prefers the file's
    /// resource identifier (authoritative across symlinks and case); falls back
    /// to a symlink-resolved, case-insensitive path compare when `to` does not
    /// exist yet.
    /// Whether `inner` is the destination-side descendant of folder `ancestor` (or equal to it),
    /// by symlink-resolved, case-insensitive path prefix. Used to refuse nesting a folder in
    /// its own subtree; `inner` (the destination) may not exist yet, so this is path-based.
    static func isDescendant(_ inner: URL, of ancestor: URL) -> Bool {
        let a = ancestor.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let i = inner.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        return i == a || i.hasPrefix(a + "/")
    }

    private static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        let idA = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let idB = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let idA = idA as? NSObject, let idB = idB as? NSObject { return idA.isEqual(idB) }
        return a.resolvingSymlinksInPath().standardizedFileURL.path
            .compare(b.resolvingSymlinksInPath().standardizedFileURL.path, options: .caseInsensitive)
            == .orderedSame
    }

    /// A non-colliding variant like "report copy.txt", then "report copy 2.txt".
    static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent

        func candidate(_ suffix: String) -> URL {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            return dir.appendingPathComponent(name)
        }

        var result = candidate("copy")
        var n = 2
        while fm.fileExists(atPath: result.path) {
            result = candidate("copy \(n)")
            n += 1
        }
        return result
    }

    // MARK: Links

    public enum LinkKind: String, Sendable, CaseIterable {
        case symlink, alias, hardlink
    }

    /// Create a link of `kind` next to each item (named "<name> symlink/alias/hardlink"),
    /// pointing at the original. Symlinks and aliases work for files and folders. A
    /// hardlink must be same-volume; for a folder, FileManager recursively hardlinks the
    /// contents (a shared-inode clone). Records each created link as a `.copied` op, so
    /// undo trashes it like a copy.
    @discardableResult
    public static func makeLinks(_ urls: [URL], kind: LinkKind) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for url in urls {
            let link = suffixedName(url, suffix: kind.rawValue)
            do {
                switch kind {
                case .symlink:
                    try fm.createSymbolicLink(at: link, withDestinationURL: url)
                case .hardlink:
                    try fm.linkItem(at: url, to: link)
                case .alias:
                    let data = try url.bookmarkData(
                        options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil,
                        relativeTo: nil)
                    try URL.writeBookmarkData(data, to: link)
                }
                outcome.performed.append(Performed(action: .copied, source: url, destination: link))
            } catch {
                outcome.failures.append(Failure(name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return outcome
    }

    /// A non-colliding "<base> <suffix>[.ext]" next to `url` (e.g. "report symlink.pdf").
    static func suffixedName(_ url: URL, suffix: String) -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        func candidate(_ n: Int?) -> URL {
            let extra = n.map { " \($0)" } ?? ""
            let name = ext.isEmpty ? "\(base) \(suffix)\(extra)" : "\(base) \(suffix)\(extra).\(ext)"
            return dir.appendingPathComponent(name)
        }
        var result = candidate(nil)
        var n = 2
        while fm.fileExists(atPath: result.path) {
            result = candidate(n)
            n += 1
        }
        return result
    }
}
