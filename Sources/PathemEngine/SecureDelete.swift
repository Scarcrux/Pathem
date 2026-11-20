import Foundation
import Security

/// Best-effort secure erase: unlink a name first, then overwrite the open file if no
/// other hard links share its inode. On APFS/SSD, copy-on-write and wear leveling may
/// retain older blocks. Unlike Move to Trash, this operation is irreversible.
public enum SecureDelete {
    public struct Result: Sendable, Equatable {
        public var deleted: [String] = []
        public var sharedLinksUnlinked: [String] = []
        public var failures: [FileOperations.Failure] = []
        public init() {}
    }

    /// Folders recurse; symlinks and other nonregular files are only unlinked.
    public static func shred(_ urls: [URL], passes: Int = 1) -> Result {
        var result = Result()
        for url in urls { shredItem(url, passes: max(1, passes), into: &result) }
        return result
    }

    private static func shredItem(_ url: URL, passes: Int, into result: inout Result) {
        let name = url.lastPathComponent
        do {
            var item = stat()
            guard lstat(url.path, &item) == 0 else { throw posixError(errno) }
            let type = item.st_mode & S_IFMT
            if type == S_IFDIR {
                let children = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil)
                for child in children { shredItem(child, passes: passes, into: &result) }
                guard rmdir(url.path) == 0 else { throw posixError(errno) }
                result.deleted.append(name)
                return
            }

            if type != S_IFREG || item.st_nlink > 1 {
                guard unlink(url.path) == 0 else { throw posixError(errno) }
                result.deleted.append(name)
                if type == S_IFREG { result.sharedLinksUnlinked.append(name) }
                return
            }

            // The descriptor stays open after unlink and O_NOFOLLOW protects against a path
            // being swapped to a symlink. Unlink is the authoritative permission/ACL check.
            let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw posixError(errno) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var opened = stat()
            guard fstat(fd, &opened) == 0 else { throw posixError(errno) }
            var current = stat()
            guard lstat(url.path, &current) == 0 else { throw posixError(errno) }
            guard opened.st_mode & S_IFMT == S_IFREG,
                current.st_dev == opened.st_dev, current.st_ino == opened.st_ino,
                item.st_dev == opened.st_dev, item.st_ino == opened.st_ino
            else { throw posixError(EBUSY) }

            guard unlink(url.path) == 0 else { throw posixError(errno) }
            result.deleted.append(name)
            guard fstat(fd, &opened) == 0 else { throw posixError(errno) }
            if opened.st_nlink != 0 {
                result.sharedLinksUnlinked.append(name)
                return
            }
            try overwrite(handle, size: opened.st_size, passes: passes)
        } catch {
            result.failures.append(.init(name: name, reason: error.localizedDescription))
        }
    }

    /// Overwrite a file's existing bytes with cryptographically random data.
    static func overwrite(_ url: URL, passes: Int) throws {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try overwrite(handle, size: off_t(size), passes: passes)
    }

    private static func overwrite(_ handle: FileHandle, size: off_t, passes: Int) throws {
        guard size > 0 else { return }
        let chunkSize = 1 << 16
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        for _ in 0..<passes {
            try handle.seek(toOffset: 0)
            var remaining = size
            while remaining > 0 {
                let n = Int(min(off_t(chunkSize), remaining))
                let status = SecRandomCopyBytes(kSecRandomDefault, n, &buffer)
                guard status == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                }
                try handle.write(contentsOf: Data(buffer[0..<n]))
                remaining -= off_t(n)
            }
            try handle.synchronize()
        }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }
}
