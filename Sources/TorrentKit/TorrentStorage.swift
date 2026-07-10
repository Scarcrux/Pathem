import Foundation

/// Writes verified pieces to the torrent's files on disk and reads bytes back (for resume checks
/// and seeding). Uses the FileLayout to split each piece across file boundaries. Files are created
/// lazily and written sparsely, so unfinished files still take only the space actually downloaded.
public final class TorrentStorage {
    public enum StorageError: Error, Equatable {
        case unsafePath(String)   // a torrent path tried to escape the download folder
        case openFailed(String)
    }

    private let root: URL
    private let layout: FileLayout
    private var handles: [Int: FileHandle] = [:]
    private var closed = false  // once closed, refuse to reopen (prevents post-delete file resurrection)

    /// `root` is the download folder (the torrent's own name is already part of each file path for
    /// multi-file torrents). Validates every file path up front so nothing can be written outside.
    public init(root: URL, layout: FileLayout) throws {
        self.root = root.standardizedFileURL
        self.layout = layout
        for file in layout.files { _ = try Self.safeURL(for: file.path, under: self.root) }
    }

    /// Resolve a torrent-relative path under `root`, rejecting absolute paths and `..` traversal.
    static func safeURL(for path: String, under root: URL) throws -> URL {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty,
            !components.contains(".."),
            !components.contains(where: { $0.hasPrefix("/") }),
            !path.hasPrefix("/")
        else { throw StorageError.unsafePath(path) }
        let url = components.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        // Defence in depth: the resolved path must still sit inside root.
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw StorageError.unsafePath(path)
        }
        return url
    }

    private func handle(for index: Int) throws -> FileHandle {
        if closed { throw StorageError.openFailed("storage closed") }
        if let h = handles[index] { return h }
        let file = layout.files[index]
        let url = try Self.safeURL(for: file.path, under: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forUpdating: url) else {
            throw StorageError.openFailed(file.path)
        }
        handles[index] = h
        return h
    }

    /// Write a verified piece's bytes to the files it spans.
    public func write(pieceIndex: Int, pieceLength: Int, pieceSize: Int, data: Data) throws {
        let segments = layout.segments(forPiece: pieceIndex, pieceLength: pieceLength, pieceSize: pieceSize)
        var dataOffset = 0
        for seg in segments {
            let h = try handle(for: seg.fileIndex)
            try h.seek(toOffset: UInt64(seg.fileOffset))
            let end = dataOffset + Int(seg.length)
            try h.write(contentsOf: data.subdata(in: dataOffset..<end))
            dataOffset = end
        }
    }

    /// Read a global byte range back (used to serve a `piece` to a peer, or to verify on resume).
    public func read(at start: Int64, length: Int) throws -> Data {
        var out = Data()
        for seg in layout.segments(at: start, length: Int64(length)) {
            let h = try handle(for: seg.fileIndex)
            try h.seek(toOffset: UInt64(seg.fileOffset))
            out.append(try h.read(upToCount: Int(seg.length)) ?? Data())
        }
        return out
    }

    /// Flush and close all open file handles. After this, writes/reads are refused (no reopen), so
    /// a straggling write after the torrent was removed can't resurrect a deleted file.
    public func close() {
        closed = true
        for h in handles.values { try? h.close() }
        handles.removeAll()
    }

    deinit { close() }
}
