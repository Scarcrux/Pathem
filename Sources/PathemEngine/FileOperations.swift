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
        public let incompleteMove: MoveIncompleteError?
        public let adminRetry: AdminFileRequest?
        public init(
            name: String, reason: String, incompleteMove: MoveIncompleteError? = nil,
            adminRetry: AdminFileRequest? = nil
        ) {
            self.name = name
            self.reason = reason
            self.incompleteMove = incompleteMove
            self.adminRetry = adminRetry
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
        /// The replaced directory entry can differ in case or Unicode spelling from destination.
        public let replacedOriginal: URL?
        public let linkKind: LinkKind?
        public init(
            action: Action, source: URL, destination: URL, replacedOriginalTrashed: URL? = nil,
            replacedOriginal: URL? = nil, linkKind: LinkKind? = nil
        ) {
            self.action = action
            self.source = source
            self.destination = destination
            self.replacedOriginalTrashed = replacedOriginalTrashed
            self.replacedOriginal = replacedOriginal
            self.linkKind = linkKind
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
            let v = try? child.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if v?.isSymbolicLink == true { continue }
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: Conflict detection

    public static func conflicts(_ names: [String], from source: URL, to destination: URL)
        -> [String]
    {
        conflicts(urls: names.map { source.appendingPathComponent($0) }, into: destination)
    }

    public static func conflicts(urls: [URL], into destination: URL) -> [String] {
        // A name conflicts if it already exists at the destination OR appears more than once in
        // this batch: two selected sources that share a basename (e.g. a/photo.jpg + b/photo.jpg)
        // would land on the same target, so the second must be resolved (prompt / keep-both /
        // skip) rather than silently dropped.
        var seen = Set<String>()
        var conflicting: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let existsAtDestination = FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(name).path)
            if existsAtDestination || seen.contains(name) {
                conflicting.append(name)
            }
            seen.insert(name)
        }
        return conflicting
    }

    // MARK: New folder

    /// Create a new folder in `directory`, picking a unique "untitled folder"
    /// name (Finder-style) when the base name is taken. Returns the name created.
    @discardableResult
    public static func makeFolder(in directory: URL, baseName: String = "untitled folder") throws
        -> String
    {
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
    public static func makeFile(in directory: URL, baseName: String = "untitled file") throws
        -> String
    {
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
        guard fm.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
        else {
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
        guard !trimmed.contains("/"), !trimmed.contains("\0") else {
            throw InvalidNameError(name: trimmed)
        }
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
                } else {
                    // macOS almost always returns the landing URL; if it didn't, locate the item in
                    // the home Trash by name so undo / Put Back still work (else it's trashed but
                    // un-restorable). Skipped only if even that isn't found.
                    let guess = fm.homeDirectoryForCurrentUser
                        .appendingPathComponent(".Trash").appendingPathComponent(
                            source.lastPathComponent)
                    if fm.fileExists(atPath: guess.path) {
                        trashed.append(Trashed(original: source, trashed: guess))
                    }
                }
            } catch {
                failures.append(
                    Failure(
                        name: source.lastPathComponent, reason: error.localizedDescription,
                        adminRetry: AdminFileRequest.isPermissionFailure(error)
                            ? AdminFileRequest(operation: .trash, source: source.path) : nil))
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
            let destination =
                fm.fileExists(atPath: item.original.path)
                ? uniqueDestination(item.original) : item.original
            do {
                try fm.moveItem(at: item.trashed, to: destination)
                result.restored.append(destination)
                if destination != item.original {
                    result.failures.append(
                        Failure(
                            name: item.original.lastPathComponent,
                            reason:
                                "the original location was taken; restored as \"\(destination.lastPathComponent)\""
                        ))
                }
            } catch {
                result.failures.append(
                    Failure(
                        name: item.original.lastPathComponent, reason: error.localizedDescription))
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
        copy(
            urls: names.map { source.appendingPathComponent($0) }, into: destination,
            onConflict: onConflict)
    }

    @discardableResult
    public static func move(
        _ names: [String], from source: URL, to destination: URL,
        onConflict: ConflictResolution = .skip
    ) -> Outcome {
        move(
            urls: names.map { source.appendingPathComponent($0) }, into: destination,
            onConflict: onConflict)
    }

    /// A copy whose SHA-256 didn't match the source (verification was on). The bad copy is
    /// removed before this is thrown, so no corrupt file is left behind.
    public struct CopyVerificationError: LocalizedError {
        public let name: String
        public var errorDescription: String? {
            "Verification failed: the copy of \(name) doesn’t match the original."
        }
    }

    /// The full copy landed. Source cleanup stopped at the first error and the landed
    /// copy must be kept, including when the items already removed were only part of a tree.
    public struct MoveIncompleteError: LocalizedError, Equatable {
        public let destination: URL
        public let remainingSourceItems: [URL]
        public let cleanupFailure: String

        public var remainingPathSummary: String {
            let items = remainingSourceItems.prefix(8).map(\.path).joined(separator: ", ")
            return items + (remainingSourceItems.count > 8 ? ", …" : "")
        }

        public var errorDescription: String? {
            return
                "Moved, but \(remainingSourceItems.count) item(s) could not be removed from the original "
                + "location. The full copy is at \(destination.path). Remaining: \(remainingPathSummary). "
                + cleanupFailure
        }
    }

    private typealias PublishMove = (URL, URL) throws -> Void

    @discardableResult
    public static func copy(
        urls: [URL], into destination: URL, onConflict: ConflictResolution = .skip,
        verify: Bool = false,
        shouldCancel: @escaping () -> Bool = { false },
        report: @escaping (Progress) -> Void = { _ in }
    ) -> Outcome {
        apply(
            urls, into: destination, action: .copied, onConflict: onConflict,
            shouldCancel: shouldCancel, report: report
        ) { source, dest, onBytes, publish in
            try ProgressiveCopy.withStagedCopy(
                from: source, beside: dest, onBytes: onBytes, shouldCancel: shouldCancel
            ) { staged in
                if verify { try verifyCopy(source: source, dest: staged) }
                try publish(staged, dest)
            }
        }
    }

    /// Confirm a copied file matches its source by SHA-256; on a mismatch (a corrupt copy) remove
    /// the destination and throw `CopyVerificationError`. A directory hashes to nil on both sides,
    /// so it passes through. Extracted so the corrupt-copy path is testable without staging a real
    /// corruption mid-copy.
    static func verifyCopy(source: URL, dest: URL) throws {
        let matched = (try? FileHasher.hash(source)) == (try? FileHasher.hash(dest))
        if !matched {
            try? FileManager.default.removeItem(at: dest)
            throw CopyVerificationError(name: source.lastPathComponent)
        }
    }

    @discardableResult
    public static func move(
        urls: [URL], into destination: URL, onConflict: ConflictResolution = .skip,
        shouldCancel: @escaping () -> Bool = { false },
        report: @escaping (Progress) -> Void = { _ in }
    ) -> Outcome {
        apply(
            urls, into: destination, action: .moved, onConflict: onConflict,
            shouldCancel: shouldCancel, report: report
        ) { source, dest, onBytes, publish in
            // File providers must coordinate the source and destination before accessing either.
            if requiresCoordinatedMove(from: source, to: dest) {
                try coordinatedMove(
                    from: source, to: dest, onBytes: onBytes, shouldCancel: shouldCancel,
                    publish: publish)
            } else {
                try moveItem(
                    from: source, to: dest, onBytes: onBytes, shouldCancel: shouldCancel,
                    publish: publish)
            }
        }
    }

    private static func moveItem(
        from source: URL, to dest: URL,
        onBytes: @escaping (Int64) -> Void, shouldCancel: @escaping () -> Bool,
        publish: PublishMove
    ) throws {
        if sameVolume(source, dest) {
            try publish(source, dest)
            return
        }
        try ProgressiveCopy.withStagedCopy(
            from: source, beside: dest, onBytes: onBytes, shouldCancel: shouldCancel
        ) { staged in
            try publish(staged, dest)
        }

        do {
            try removeSourceItem(source, copiedTo: dest)
        } catch {
            // This copy may be the only surviving location for descendants already unlinked.
            throw incompleteMove(from: source, to: dest, cause: error)
        }
    }

    private static func removeSourceItem(_ url: URL, copiedTo copy: URL) throws {
        var item = stat()
        guard lstat(url.path, &item) == 0 else { throw removalError(errno, at: url) }
        // A new descendant can appear after the copyfile walk. Never delete an entry for
        // which no corresponding copy exists.
        var copied = stat()
        let type = item.st_mode & S_IFMT
        guard lstat(copy.path, &copied) == 0, copied.st_mode & S_IFMT == type,
            type != S_IFREG || item.st_size == copied.st_size
        else { throw removalError(EBUSY, at: url) }
        if type == S_IFDIR {
            let children = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)
            for child in children {
                try removeSourceItem(
                    child, copiedTo: copy.appendingPathComponent(child.lastPathComponent))
            }
            guard rmdir(url.path) == 0 else { throw removalError(errno, at: url) }
        } else {
            guard unlink(url.path) == 0 else { throw removalError(errno, at: url) }
        }
    }

    private static func removalError(_ code: Int32, at url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey: "\(String(cString: strerror(code))): \(url.path)",
            ])
    }

    private static func incompleteMove(from source: URL, to dest: URL, cause: Error)
        -> MoveIncompleteError
    {
        var items = [source]
        if let children = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: nil)
        {
            for case let child as URL in children { items.append(child) }
        }
        return MoveIncompleteError(
            destination: dest, remainingSourceItems: items,
            cleanupFailure: cause.localizedDescription)
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

    /// Whether `url` is an iCloud (or other file-provider) item. Such items need coordinated access;
    /// raw FileManager moves/removes on them don't reliably reach the provider.
    static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    /// A destination item normally does not exist yet, so it cannot report file-provider metadata.
    /// Inspect its containing folder as well or a local-to-iCloud move will incorrectly bypass the
    /// coordinated path.
    static func requiresCoordinatedMove(from source: URL, to destination: URL) -> Bool {
        isUbiquitous(source)
            || isUbiquitous(destination)
            || isUbiquitous(destination.deletingLastPathComponent())
    }

    /// Move a file-provider (iCloud) item through NSFileCoordinator so the provider actually releases
    /// the source, then verify it's gone. Reading the source during the copy materializes an
    /// online-only item on demand, so the destination lands with real content. If the source survives
    /// (iCloud reported success without releasing it), surface it instead of leaving a silent duplicate.
    static func coordinatedMove(
        from source: URL, to dest: URL, onBytes: @escaping (Int64) -> Void,
        shouldCancel: @escaping () -> Bool,
        publish: (URL, URL) throws -> Void = { from, to in
            try FileManager.default.moveItem(at: from, to: to)
        }
    ) throws {
        var coordError: NSError?
        var opError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: source, options: .forMoving, writingItemAt: dest, options: .forReplacing,
            error: &coordError
        ) { coordinatedSource, coordinatedDest in
            do {
                try moveItem(
                    from: coordinatedSource, to: coordinatedDest, onBytes: onBytes,
                    shouldCancel: shouldCancel, publish: publish)
            } catch { opError = error }
        }
        if let opError { throw opError }
        if let coordError { throw coordError }
        var sourceInfo = stat()
        if lstat(source.path, &sourceInfo) == 0 {
            throw incompleteMove(from: source, to: dest, cause: removalError(EBUSY, at: source))
        }
    }

    /// Reverse a set of performed operations: moves go back to their source,
    /// copies go to the Trash. Used to implement undo.
    @discardableResult
    public static func undo(_ performed: [Performed]) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        var blockedDestinations = Set<String>()
        // Later Replace operations may have displaced an earlier member of this
        // very batch. Unwind in reverse or we move/trash the later member's bytes
        // as though they belonged to the earlier member.
        for op in performed.reversed() {
            let destinationPath = op.destination.standardizedFileURL.path
            guard !blockedDestinations.contains(destinationPath) else {
                outcome.failures.append(
                    Failure(
                        name: op.destination.lastPathComponent,
                        reason: "a later operation at this destination couldn’t be undone"))
                continue
            }
            do {
                switch op.action {
                case .moved:
                    guard !fm.fileExists(atPath: op.source.path) else {
                        blockedDestinations.insert(destinationPath)
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
                        try fm.moveItem(at: trashed, to: op.replacedOriginal ?? op.destination)
                    } catch {
                        blockedDestinations.insert(destinationPath)
                        outcome.failures.append(
                            Failure(
                                name: op.destination.lastPathComponent,
                                reason:
                                    "couldn't restore the replaced file: \(error.localizedDescription)"
                            ))
                    }
                }
                outcome.performed.append(op)
            } catch {
                blockedDestinations.insert(destinationPath)
                outcome.failures.append(
                    Failure(
                        name: op.destination.lastPathComponent, reason: error.localizedDescription))
            }
        }
        // Callers feed these successful inverses to redo(), which must replay
        // the original forward order, not our reverse execution order.
        outcome.performed.reverse()
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
            var replacedTrash: URL?
            let original = op.replacedOriginal ?? op.destination
            do {
                // Undo of a Replace restored the overwritten original to the destination. Redo must
                // displace it again (to a fresh trash location), or the copy/move below fails
                // "file exists" and a later undo would trash the restored original by mistake.
                if op.replacedOriginalTrashed != nil, itemExists(at: original) {
                    var landed: NSURL?
                    try fm.trashItem(at: original, resultingItemURL: &landed)
                    replacedTrash = landed as URL?
                }
                switch op.action {
                case .moved: try fm.moveItem(at: op.source, to: op.destination)
                case .copied:
                    if let kind = op.linkKind {
                        try createLink(from: op.source, at: op.destination, kind: kind)
                    } else {
                        try fm.copyItem(at: op.source, to: op.destination)
                    }
                }
                outcome.performed.append(
                    Performed(
                        action: op.action, source: op.source, destination: op.destination,
                        replacedOriginalTrashed: replacedTrash,
                        replacedOriginal: op.replacedOriginal, linkKind: op.linkKind))
            } catch {
                let transferError = error
                if let trashed = replacedTrash {
                    do {
                        try fm.moveItem(at: trashed, to: original)
                    } catch {
                        outcome.failures.append(
                            Failure(
                                name: op.destination.lastPathComponent,
                                reason: "Redo failed: \(transferError.localizedDescription). "
                                    + "The replaced file couldn’t be restored and remains at \(trashed.path): "
                                    + error.localizedDescription))
                        continue
                    }
                }
                outcome.failures.append(
                    Failure(
                        name: op.destination.lastPathComponent,
                        reason: transferError.localizedDescription))
            }
        }
        return outcome
    }

    // MARK: Core

    private static func apply(
        _ sources: [URL], into destination: URL,
        action: Action, onConflict: ConflictResolution,
        shouldCancel: @escaping () -> Bool, report: @escaping (Progress) -> Void,
        _ op: (URL, URL, _ onItemBytes: @escaping (Int64) -> Void, PublishMove) throws -> Void
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
            var replacedOriginal: URL?
            var published = false
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
                    outcome.failures.append(
                        Failure(name: name, reason: "A folder can’t be moved inside itself."))
                    continue
                }
                var replacing = false
                var destinationInfo = stat()
                if lstat(to.path, &destinationInfo) == 0 {
                    switch onConflict {
                    case .skip:
                        outcome.skipped.append(name)
                        continue
                    case .replace:
                        replacing = true
                        replacedOriginal = actualDirectoryEntry(to, matching: destinationInfo)
                    case .keepBoth:
                        to = uniqueDestination(to)
                    }
                }
                do {
                    try op(
                        from, to,
                        { copiedInItem in
                            // Live intra-file progress: cap at the item's own size so a slightly
                            // ahead-of-itself count never pushes the bar past this item.
                            progress.completedBytes = base + min(copiedInItem, itemBytes)
                            report(progress)
                        },
                        { ready, final in
                            if replacing {
                                var current = stat()
                                guard lstat(final.path, &current) == 0,
                                    current.st_dev == destinationInfo.st_dev,
                                    current.st_ino == destinationInfo.st_ino
                                else { throw removalError(EBUSY, at: final) }
                                var landed: NSURL?
                                try fm.trashItem(
                                    at: replacedOriginal ?? final, resultingItemURL: &landed)
                                replacedTrash = landed as URL?
                            }
                            try fm.moveItem(at: ready, to: final)
                            published = true
                        })
                } catch {
                    // Restore only if the replacement never landed. Cleanup failures after
                    // publication leave the full copy in place and do not create an undo entry.
                    if !published, let trashed = replacedTrash {
                        do {
                            try fm.moveItem(at: trashed, to: replacedOriginal ?? to)
                        } catch {
                            // The op failed AND the overwritten original couldn't be put back: it's
                            // stranded in the Trash. Say so explicitly, with its location, instead of
                            // a bare "failed" that hides where the file went.
                            outcome.failures.append(
                                Failure(
                                    name: name,
                                    reason:
                                        "Couldn’t \(action == .moved ? "move" : "copy") the item here, and the file it "
                                        + "replaced was moved to the Trash and couldn’t be restored. It’s at \(trashed.path)"
                                ))
                            continue
                        }
                    }
                    throw error
                }
                outcome.performed.append(
                    Performed(
                        action: action, source: from, destination: to,
                        replacedOriginalTrashed: replacedTrash, replacedOriginal: replacedOriginal))
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
                let retry: AdminFileRequest?
                if !published, replacedOriginal == nil, !(error is MoveIncompleteError),
                    AdminFileRequest.isPermissionFailure(error)
                {
                    retry = AdminFileRequest(
                        operation: action == .moved ? .move : .copy, source: from.path,
                        destination: to.path)
                } else {
                    retry = nil
                }
                outcome.failures.append(
                    Failure(
                        name: name, reason: error.localizedDescription,
                        incompleteMove: error as? MoveIncompleteError, adminRetry: retry))
            }
            progress.completedItems = index + 1
            report(progress)
        }
        return outcome
    }

    private static func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func actualDirectoryEntry(_ requested: URL, matching info: stat) -> URL {
        let directory = requested.deletingLastPathComponent()
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return requested }
        if let exact = entries.first(where: {
            $0.lastPathComponent.utf8.elementsEqual(requested.lastPathComponent.utf8)
        }) {
            return exact
        }
        return entries.first {
            guard
                $0.lastPathComponent.caseInsensitiveCompare(requested.lastPathComponent)
                    == .orderedSame
            else { return false }
            var candidate = stat()
            return lstat($0.path, &candidate) == 0
                && candidate.st_dev == info.st_dev && candidate.st_ino == info.st_ino
        } ?? requested
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
        let idA = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier
        let idB = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier
        if let idA = idA as? NSObject, let idB = idB as? NSObject { return idA.isEqual(idB) }
        return a.resolvingSymlinksInPath().standardizedFileURL.path
            .compare(
                b.resolvingSymlinksInPath().standardizedFileURL.path, options: .caseInsensitive)
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
        var outcome = Outcome()
        for url in urls {
            let link = suffixedName(url, suffix: kind.rawValue)
            do {
                try createLink(from: url, at: link, kind: kind)
                outcome.performed.append(
                    Performed(action: .copied, source: url, destination: link, linkKind: kind))
            } catch {
                outcome.failures.append(
                    Failure(name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return outcome
    }

    private static func createLink(from source: URL, at link: URL, kind: LinkKind) throws {
        let fm = FileManager.default
        switch kind {
        case .symlink: try fm.createSymbolicLink(at: link, withDestinationURL: source)
        case .hardlink: try fm.linkItem(at: source, to: link)
        case .alias:
            let data = try source.bookmarkData(
                options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil,
                relativeTo: nil)
            try URL.writeBookmarkData(data, to: link)
        }
    }

    /// A non-colliding "<base> <suffix>[.ext]" next to `url` (e.g. "report symlink.pdf").
    static func suffixedName(_ url: URL, suffix: String) -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        func candidate(_ n: Int?) -> URL {
            let extra = n.map { " \($0)" } ?? ""
            let name =
                ext.isEmpty ? "\(base) \(suffix)\(extra)" : "\(base) \(suffix)\(extra).\(ext)"
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
