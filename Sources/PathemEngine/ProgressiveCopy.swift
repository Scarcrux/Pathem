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
        // Boxed so the C callback (which can't capture) can reach it through the
        // copyfile "status context" raw pointer.
        final class Context {
            var base: Int64 = 0        // bytes from files already fully copied in this run
            var currentCopied: Int64 = 0  // bytes copied so far in the file being copied now
            var cancelled = false
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
        let callback: copyfile_callback_t = { what, stage, cbState, _, _, info in
            guard let info else { return COPYFILE_CONTINUE }
            let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            if context.shouldCancel() {
                context.cancelled = true
                return COPYFILE_QUIT
            }
            if what == COPYFILE_COPY_DATA, stage != COPYFILE_ERR {
                // PROGRESS (partial) and FINISH (final) report real bytes; skip ERR, where COPIED is
                // stale and the copy is about to fail anyway (apply() resets the item's bytes then).
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
        let result = source.withUnsafeFileSystemRepresentation { src -> Int32 in
            destination.withUnsafeFileSystemRepresentation { dst -> Int32 in
                copyfile(src, dst, state, flags)
            }
        }

        if result != 0 {
            let posix = errno
            // Never leave a partial/corrupt copy behind, whether cancelled or failed.
            try? FileManager.default.removeItem(at: destination)
            if context.cancelled { throw Cancelled() }
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(posix),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(posix))])
        }
    }
}
