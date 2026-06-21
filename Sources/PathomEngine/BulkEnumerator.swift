import Darwin
import Foundation

/// The fast directory enumerator, built on `getattrlistbulk(2)`.
///
/// `getattrlistbulk` returns *many* entries with *all requested attributes* per
/// syscall, instead of one `readdir` + a `stat` per file. On this machine it
/// returns the full contents of `/usr/bin` (924 entries) in a single call,
/// collapsing a 100k-file listing from 100k+ vnode round-trips to tens of ms
/// (DESIGN.md §3, §5).
///
/// Parsing follows the man page's canonical approach: each entry carries a
/// per-entry `attribute_set_t` (because we request `ATTR_CMN_RETURNED_ATTRS`)
/// that says which attributes are actually present, and we walk the fields
/// *conditionally* in canonical bit order. This matters because the layout is
/// NOT fixed: a directory omits `ATTR_FILE_DATALENGTH` entirely, so a
/// fixed-offset reader would run off the end of a short-named directory record.
///
/// Every read is bounds-checked against the record end (and the buffer end),
/// and the variable-length name is read using its declared length rather than
/// scanning for a NUL, so a malformed entry fails safe instead of reading
/// unrelated heap. Multi-byte reads use `loadUnaligned` because the packed
/// buffer makes no alignment guarantees.
///
/// Correctness is pinned by ``BulkEnumeratorTests`` against the
/// ``FoundationEnumerator`` oracle, including the edge cases (short-named
/// directories, UF_HIDDEN files, symlinks) that distinguish the two paths.
public struct BulkEnumerator: DirectoryEnumerating {
    public init() {}

    /// Attribute bits and vnode/flag constants, namespaced to avoid clashing
    /// with the C macros imported from Darwin.
    private enum Attr {
        static let bitMapCount: UInt16 = 5  // ATTR_BIT_MAP_COUNT

        // commonattr bits (requested in canonical ascending order)
        static let cmnReturnedAttrs: UInt32 = 0x8000_0000  // ATTR_CMN_RETURNED_ATTRS
        static let cmnName: UInt32 = 0x0000_0001  // ATTR_CMN_NAME
        static let cmnObjType: UInt32 = 0x0000_0008  // ATTR_CMN_OBJTYPE
        static let cmnModTime: UInt32 = 0x0000_0400  // ATTR_CMN_MODTIME
        static let cmnFlags: UInt32 = 0x0004_0000  // ATTR_CMN_FLAGS
        // fileattr bits
        static let fileDataLength: UInt32 = 0x0000_0200  // ATTR_FILE_DATALENGTH

        static let vdir: UInt32 = 2  // VDIR (fsobj_type_t)
        static let ufHidden: UInt32 = 0x0000_8000  // UF_HIDDEN (st_flags)
    }

    /// Bytes consumed before the variable attribute data: u_int32 record length
    /// (4) + the returned-attrs `attribute_set_t` (5 x u_int32 = 20).
    private static let headerSize = 24

    enum EnumerationError: Error, Equatable {
        case openFailed(path: String, errno: Int32)
        case syscallFailed(errno: Int32)
    }

    public func entries(of directory: URL, includingHidden: Bool) throws -> [FileEntry] {
        let fd = directory.withUnsafeFileSystemRepresentation { rep -> Int32 in
            guard let rep else { return -1 }
            return open(rep, O_RDONLY)
        }
        guard fd >= 0 else {
            throw EnumerationError.openFailed(path: directory.path, errno: errno)
        }
        defer { close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = Attr.bitMapCount
        attrList.commonattr =
            Attr.cmnReturnedAttrs | Attr.cmnName | Attr.cmnObjType | Attr.cmnModTime
            | Attr.cmnFlags
        attrList.fileattr = Attr.fileDataLength

        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        let bufLimit = UnsafeRawPointer(buf) + bufSize

        var results: [FileEntry] = []

        while true {
            var returned = getattrlistbulk(fd, &attrList, buf, bufSize, 0)
            while returned == -1 && errno == EINTR {
                returned = getattrlistbulk(fd, &attrList, buf, bufSize, 0)
            }
            if returned == -1 {
                // Some filesystems (network / FUSE) don't implement
                // getattrlistbulk; fall back to the portable enumerator.
                if errno == ENOTSUP || errno == EOPNOTSUPP {
                    return try FoundationEnumerator()
                        .entries(of: directory, includingHidden: includingHidden)
                }
                throw EnumerationError.syscallFailed(errno: errno)
            }
            if returned == 0 { break }

            var entry = UnsafeRawPointer(buf)
            entryLoop: for _ in 0..<Int(returned) {
                // Need at least the length + returned-attrs set to proceed.
                guard entry + Self.headerSize <= bufLimit else { break }
                let recordLength = entry.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                guard recordLength >= UInt32(Self.headerSize) else { break }
                let recordEnd = entry.advanced(by: Int(recordLength))
                guard recordEnd <= bufLimit else { break }

                // Per-entry returned attribute set: commonattr@+4, fileattr@+16.
                let commonReturned = entry.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                let fileReturned = entry.loadUnaligned(fromByteOffset: 16, as: UInt32.self)

                var cursor = Self.headerSize
                var name = ""
                var isDirectory = false
                var flags: UInt32 = 0
                var size: Int64 = 0
                var modificationDate: Date?

                // ATTR_CMN_NAME — attrreference_t (int32 offset relative to the
                // reference's own location, + u_int32 length incl. trailing NUL),
                // then the name bytes it points at.
                if commonReturned & Attr.cmnName != 0 {
                    guard entry + cursor + 8 <= recordEnd else { entry = recordEnd; continue entryLoop }
                    let nameOffset = entry.loadUnaligned(fromByteOffset: cursor, as: Int32.self)
                    let nameLength = entry.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self)
                    let nameBase = cursor + Int(nameOffset)
                    guard nameBase >= 0, nameLength >= 1,
                        entry + nameBase + Int(nameLength) <= recordEnd
                    else { entry = recordEnd; continue entryLoop }
                    name = String(
                        decoding: UnsafeRawBufferPointer(
                            start: entry + nameBase, count: Int(nameLength) - 1),
                        as: UTF8.self)
                    cursor += 8
                }
                // ATTR_CMN_OBJTYPE — fsobj_type_t.
                if commonReturned & Attr.cmnObjType != 0 {
                    guard entry + cursor + 4 <= recordEnd else { entry = recordEnd; continue entryLoop }
                    isDirectory = entry.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) == Attr.vdir
                    cursor += 4
                }
                // ATTR_CMN_MODTIME — struct timespec (tv_sec + tv_nsec).
                if commonReturned & Attr.cmnModTime != 0 {
                    guard entry + cursor + 16 <= recordEnd else { entry = recordEnd; continue entryLoop }
                    let seconds = entry.loadUnaligned(fromByteOffset: cursor, as: Int.self)
                    let nanos = entry.loadUnaligned(fromByteOffset: cursor + 8, as: Int.self)
                    modificationDate = Date(
                        timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
                    cursor += 16
                }
                // ATTR_CMN_FLAGS — st_flags, for UF_HIDDEN parity with
                // FileManager's .skipsHiddenFiles.
                if commonReturned & Attr.cmnFlags != 0 {
                    guard entry + cursor + 4 <= recordEnd else { entry = recordEnd; continue entryLoop }
                    flags = entry.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                    cursor += 4
                }
                // ATTR_FILE_DATALENGTH — present only for files (a directory
                // omits it, which is why this must be conditional).
                if fileReturned & Attr.fileDataLength != 0 {
                    guard entry + cursor + 8 <= recordEnd else { entry = recordEnd; continue entryLoop }
                    size = max(0, entry.loadUnaligned(fromByteOffset: cursor, as: Int64.self))
                }

                let isHidden = name.hasPrefix(".") || (flags & Attr.ufHidden != 0)
                if includingHidden || !isHidden {
                    results.append(
                        FileEntry(
                            name: name,
                            isDirectory: isDirectory,
                            size: isDirectory ? 0 : size,
                            modificationDate: modificationDate))
                }

                entry = recordEnd
            }
        }

        return results
    }
}
