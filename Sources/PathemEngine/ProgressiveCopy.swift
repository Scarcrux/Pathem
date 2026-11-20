import Foundation

/// A metadata-preserving copy with live byte progress and cancellation, built on
/// BSD `copyfile(3)` -- the same primitive Foundation's `copyItem` uses, so it keeps
/// permissions, timestamps, xattrs, ACLs, and resource forks, but adds two things
/// `FileManager` hides: a running byte count as the data streams, and the ability to
/// abort mid-file. `FileOperations` uses it to drive the transfer bar / speed / ETA
/// for big single-file and cross-volume transfers, where `copyItem` is a black box
/// that only "finishes" (so a 4 GB file sits at 0% then jumps to 100%).
public enum ProgressiveCopy {
    /// Thrown when `shouldCancel` returned true mid-copy. The partial destination has
    /// already been removed, so no half-written file is left behind.
    public struct Cancelled: Error {}

    /// Copy `source` to `destination` (recursively for directories), invoking `onBytes`
    /// with the cumulative bytes copied so far as the copy streams. `destination` must
    /// not already exist (the caller resolves conflicts first). On cancel or failure the
    /// partial destination is removed. Throws `Cancelled` on cancel, else an `NSError`
    /// wrapping the POSIX errno.
    public static func copy(
        from source: URL, to destination: URL,
        onBytes: @escaping (Int64) -> Void,
        shouldCancel: @escaping () -> Bool = { false }
    ) throws {
        try withStagedCopy(
            from: source, beside: destination, onBytes: onBytes, shouldCancel: shouldCancel
        ) { staged in
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    /// Keep partial data in an owned directory on the target volume. Publishing can only begin
    /// after the complete copy is verified, and deleting staging never touches the final path.
    static func withStagedCopy(
        from source: URL, beside destination: URL,
        onBytes: @escaping (Int64) -> Void, shouldCancel: @escaping () -> Bool,
        publish: (URL) throws -> Void
    ) throws {
        let parent = destination.deletingLastPathComponent()
        var template = Array(parent.appendingPathComponent(".pathem-copy.XXXXXX").path.utf8CString)
        let directory = try template.withUnsafeMutableBufferPointer { buffer in
            guard let path = mkdtemp(buffer.baseAddress!) else {
                throw posixError(errno, path: destination.path)
            }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent(destination.lastPathComponent)
        try copyContents(from: source, to: staged, onBytes: onBytes, shouldCancel: shouldCancel)
        try publish(staged)
    }

    private static func copyContents(
        from source: URL, to destination: URL,
        onBytes: @escaping (Int64) -> Void, shouldCancel: @escaping () -> Bool
    ) throws {
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0 else {
            throw posixError(errno, path: source.path)
        }

        // Boxed so the C callback (which can't capture) can reach it through the
        // copyfile "status context" raw pointer.
        final class Context {
            var base: Int64 = 0  // bytes from files already fully copied in this run
            var currentCopied: Int64 = 0  // bytes copied so far in the file being copied now
            var cancelled = false
            var failure: (code: Int32, path: String?)?
            let onBytes: (Int64) -> Void
            let shouldCancel: () -> Bool
            init(_ onBytes: @escaping (Int64) -> Void, _ shouldCancel: @escaping () -> Bool) {
                self.onBytes = onBytes
                self.shouldCancel = shouldCancel
            }
        }
        let context = Context(onBytes, shouldCancel)

        guard let state = copyfile_state_alloc() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        defer { copyfile_state_free(state) }

        // C callback: `COPYFILE_COPY_DATA` fires periodically as a file's data streams (COPIED
        // is that file's running total), and `COPYFILE_RECURSE_FILE`/FINISH marks each file in a
        // directory tree as done. We report `base + currentCopied` so the count climbs smoothly
        // within a file, and roll the finished file's bytes into `base` at its FINISH so it stays
        // cumulative across the whole tree. (Rolling in at RECURSE_FILE, not COPY_DATA, is what
        // keeps multi-file trees accurate -- COPIED does not carry across files reliably.)
        let callback: copyfile_callback_t = { what, stage, cbState, src, dst, info in
            let callbackErrno = errno
            guard let info else { return COPYFILE_CONTINUE }
            let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            if context.cancelled { return COPYFILE_QUIT }
            if stage == COPYFILE_ERR {
                context.failure = (
                    callbackErrno != 0 ? callbackErrno : EIO,
                    (dst ?? src).map { String(cString: $0) }
                )
                return COPYFILE_QUIT
            }
            if context.shouldCancel() {
                context.cancelled = true
                return COPYFILE_QUIT
            }
            if what == COPYFILE_COPY_DATA {
                // PROGRESS (partial) and FINISH (final) report real bytes.
                var copied: off_t = 0
                _ = copyfile_state_get(cbState, UInt32(COPYFILE_STATE_COPIED), &copied)
                context.currentCopied = Int64(copied)
                context.onBytes(context.base + context.currentCopied)
            } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
                // A file within the tree just finished: bank its bytes and reset for the next.
                context.base += context.currentCopied
                context.currentCopied = 0
                context.onBytes(context.base)
            }
            return COPYFILE_CONTINUE
        }

        copyfile_state_set(
            state, UInt32(COPYFILE_STATE_STATUS_CB),
            unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(
            state, UInt32(COPYFILE_STATE_STATUS_CTX),
            Unmanaged.passUnretained(context).toOpaque())

        // COPYFILE_ALL = data + metadata (stat, ACLs, xattrs); RECURSIVE walks directories;
        // NOFOLLOW copies a symlink as a symlink rather than its target.
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW)
        var copyErrno: Int32 = 0
        let result = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in
                let result = copyfile(src, dst, state, flags)
                copyErrno = errno
                return result
            }
        }

        if let failure = context.failure {
            throw posixError(failure.code, path: failure.path ?? destination.path)
        }
        if context.cancelled { throw Cancelled() }
        guard result == 0 else {
            throw posixError(copyErrno != 0 ? copyErrno : EIO, path: destination.path)
        }

        var copied = stat()
        guard lstat(destination.path, &copied) == 0 else {
            throw posixError(errno, path: destination.path)
        }
        let sourceType = sourceInfo.st_mode & S_IFMT
        guard copied.st_mode & S_IFMT == sourceType,
            sourceType != S_IFREG || copied.st_size == sourceInfo.st_size
        else { throw posixError(EIO, path: destination.path) }
    }

    private static func posixError(_ code: Int32, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: "\(String(cString: strerror(code))): \(path)",
            ])
    }
}
