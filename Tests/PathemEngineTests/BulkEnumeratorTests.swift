import Darwin
import Foundation
import Testing

@testable import PathemEngine

/// The BulkEnumerator (getattrlistbulk) must agree with the FoundationEnumerator
/// reference implementation. This is the "contract / probe test" CONVENTIONS
/// asks for around a load-bearing system API: if Apple changes the buffer
/// layout, or our offset/attr-walk math is wrong, these fail loudly.
///
/// The fixtures deliberately include the cases that distinguish the two code
/// paths and that an adversarial review found hidden behind the happy path:
/// short-named directories (which omit ATTR_FILE_DATALENGTH), UF_HIDDEN files,
/// and symlinks.
@Suite struct BulkEnumeratorTests {
    /// A stable, comparable signature of an entry set: name|isDir|size, sorted.
    /// (Modification time is intentionally excluded — sub-second precision can
    /// differ between the two APIs.)
    private func fingerprint(_ entries: [FileEntry]) -> [String] {
        entries.map { "\($0.name)|\($0.isDirectory)|\($0.size)" }.sorted()
    }

    private func names(_ entries: [FileEntry]) -> Set<String> {
        Set(entries.map(\.name))
    }

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-bulk-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try body(dir)
    }

    /// Full-equality parity on a rich fixture: files of various sizes, plus
    /// short-named, empty, nested, and dotted-name directories. The short-named
    /// directories ("a", "bb") are the case that triggered the out-of-bounds
    /// read in the original fixed-offset parser.
    @Test func matchesFoundationOnRichDir() throws {
        try withTempDir { dir in
            let fm = FileManager.default
            try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
            try Data().write(to: dir.appendingPathComponent("zero.bin"))
            try Data(repeating: 0, count: 4096).write(to: dir.appendingPathComponent("big.dat"))
            try fm.createDirectory(at: dir.appendingPathComponent("a"), withIntermediateDirectories: false)
            try fm.createDirectory(at: dir.appendingPathComponent("bb"), withIntermediateDirectories: false)
            try Data("x".utf8).write(to: dir.appendingPathComponent("bb/child.txt"))
            try fm.createDirectory(at: dir.appendingPathComponent("empty"), withIntermediateDirectories: false)
            // A dotted (but not hidden) directory name.
            try fm.createDirectory(at: dir.appendingPathComponent("My.app"), withIntermediateDirectories: false)

            for includingHidden in [true, false] {
                let bulk = try BulkEnumerator().entries(of: dir, includingHidden: includingHidden)
                let found = try FoundationEnumerator().entries(of: dir, includingHidden: includingHidden)
                #expect(fingerprint(bulk) == fingerprint(found), "mismatch (includingHidden=\(includingHidden))")
            }
        }
    }

    @Test func skipsDotfilesWhenRequested() throws {
        try withTempDir { dir in
            try Data().write(to: dir.appendingPathComponent("visible.txt"))
            try Data().write(to: dir.appendingPathComponent(".hidden"))

            let visible = try BulkEnumerator().entries(of: dir, includingHidden: false)
            let all = try BulkEnumerator().entries(of: dir, includingHidden: true)

            #expect(!visible.contains { $0.name == ".hidden" })
            #expect(all.contains { $0.name == ".hidden" })
        }
    }

    /// Parity for chflags-hidden (UF_HIDDEN) files, which do NOT start with a
    /// dot. FileManager's .skipsHiddenFiles hides them; BulkEnumerator must too
    /// (via ATTR_CMN_FLAGS), or the two paths silently disagree.
    @Test func matchesFoundationOnUFHiddenFiles() throws {
        try withTempDir { dir in
            try Data().write(to: dir.appendingPathComponent("visible.txt"))
            let secret = dir.appendingPathComponent("secret.txt")
            try Data().write(to: secret)
            let rc = secret.path.withCString { chflags($0, UInt32(UF_HIDDEN)) }
            try #require(rc == 0, "chflags failed: \(errno)")

            for includingHidden in [true, false] {
                let bulk = try BulkEnumerator().entries(of: dir, includingHidden: includingHidden)
                let found = try FoundationEnumerator().entries(of: dir, includingHidden: includingHidden)
                #expect(names(bulk) == names(found), "mismatch (includingHidden=\(includingHidden))")
            }
            let visible = try BulkEnumerator().entries(of: dir, includingHidden: false)
            #expect(!visible.contains { $0.name == "secret.txt" })
        }
    }

    /// Symlinks (including a dangling one) must at least be enumerated by the
    /// same names as FileManager. (Type/size semantics for symlinks are not
    /// asserted here — they legitimately differ between the APIs.)
    @Test func enumeratesSymlinksByName() throws {
        try withTempDir { dir in
            let fm = FileManager.default
            let target = dir.appendingPathComponent("target.txt")
            try Data("hi".utf8).write(to: target)
            try fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: target)
            try fm.createSymbolicLink(
                at: dir.appendingPathComponent("dangling"),
                withDestinationURL: dir.appendingPathComponent("nope.txt"))

            let bulk = try BulkEnumerator().entries(of: dir, includingHidden: true)
            let found = try FoundationEnumerator().entries(of: dir, includingHidden: true)
            #expect(names(bulk) == names(found))
        }
    }

    /// At scale, against a real system directory: the two enumerators must
    /// return the exact same set of names. (`/usr/bin` was the verified
    /// benchmark — ~924 entries in a single syscall.)
    @Test func matchesFoundationAtScaleOnUsrBin() throws {
        let dir = URL(fileURLWithPath: "/usr/bin", isDirectory: true)
        let bulk = names(try BulkEnumerator().entries(of: dir, includingHidden: true))
        let found = names(try FoundationEnumerator().entries(of: dir, includingHidden: true))
        #expect(bulk == found)
        #expect(bulk.count > 100)
    }

    @Test func throwsOnNonexistentDirectory() throws {
        let missing = URL(fileURLWithPath: "/no/such/pathem/dir-\(UUID().uuidString)")
        #expect(throws: BulkEnumerator.EnumerationError.self) {
            _ = try BulkEnumerator().entries(of: missing, includingHidden: true)
        }
    }
}
