import Foundation

/// Maps a torrent's flat piece/byte space onto its files. A multi-file torrent concatenates its
/// files into one linear space that pieces are cut from, so a verified piece often spans a file
/// boundary and must be split into per-file writes. Pure geometry; the disk writes live in the
/// storage layer.
public struct FileLayout: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public let index: Int
        public let path: String     // "/"-joined relative path within the download folder
        public let length: Int64
        public let offset: Int64     // start offset in the global byte space
    }

    /// A contiguous run of bytes that lands in a single file.
    public struct Segment: Equatable, Sendable {
        public let fileIndex: Int
        public let path: String
        public let fileOffset: Int64  // where the bytes start within that file
        public let length: Int64
    }

    public let files: [File]
    public let totalLength: Int64

    public init(entries: [TorrentFile.Entry]) {
        var files: [File] = []
        var offset: Int64 = 0
        for (i, e) in entries.enumerated() {
            files.append(File(index: i, path: e.path, length: e.length, offset: offset))
            offset += e.length
        }
        self.files = files
        self.totalLength = offset
    }

    public init(torrent: TorrentFile) { self.init(entries: torrent.files) }

    /// Split a global byte range `[start, start + length)` into the per-file segments it covers.
    public func segments(at start: Int64, length: Int64) -> [Segment] {
        guard length > 0 else { return [] }
        let end = start + length
        var out: [Segment] = []
        for file in files {
            let fileEnd = file.offset + file.length
            if fileEnd <= start || file.offset >= end { continue }  // no overlap
            let segStart = max(start, file.offset)
            let segEnd = min(end, fileEnd)
            out.append(
                Segment(
                    fileIndex: file.index, path: file.path,
                    fileOffset: segStart - file.offset, length: segEnd - segStart))
        }
        return out
    }

    /// The per-file segments covered by piece `index` of the given size.
    public func segments(forPiece index: Int, pieceLength: Int, pieceSize: Int) -> [Segment] {
        segments(at: Int64(index) * Int64(pieceLength), length: Int64(pieceSize))
    }
}
