import CryptoKit
import Foundation

/// Creates a .torrent from a file or folder: walks the content, hashes it into pieces, and builds
/// the bencoded metadata (with an auto-chosen piece length). The output round-trips through
/// TorrentFile.parse and carries a correct info hash. Reads files sequentially, so a piece can
/// span a file boundary just like a real torrent.
public enum TorrentCreator {
    public struct Options: Sendable {
        public var trackers: [String]
        public var isPrivate: Bool
        public var comment: String?
        public var pieceLength: Int?      // nil = auto
        public var creationDate: Date?    // nil omits the field (keeps tests deterministic)
        public var createdBy: String

        public init(
            trackers: [String] = [], isPrivate: Bool = false, comment: String? = nil,
            pieceLength: Int? = nil, creationDate: Date? = nil, createdBy: String = "Pathem"
        ) {
            self.trackers = trackers
            self.isPrivate = isPrivate
            self.comment = comment
            self.pieceLength = pieceLength
            self.creationDate = creationDate
            self.createdBy = createdBy
        }
    }

    public enum CreateError: Error, Equatable {
        case notFound
        case empty
        case readFailed(String)
    }

    private struct SourceFile {
        let url: URL
        let components: [String]  // path relative to the torrent root
        let length: Int64
    }

    /// Create .torrent bytes for the file or directory at `url`.
    public static func create(contentsOf url: URL, options: Options = Options()) throws -> Data {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw CreateError.notFound }

        let name = url.lastPathComponent
        let files = isDir.boolValue ? try collectFiles(in: url) : [singleFile(url)]
        let totalLength = files.reduce(Int64(0)) { $0 + $1.length }
        guard totalLength > 0 else { throw CreateError.empty }

        let pieceLength = options.pieceLength ?? autoPieceLength(for: totalLength)
        let pieceHashes = try hashPieces(files: files, pieceLength: pieceLength)

        // Build the info dict (Bencode.encoded sorts keys, giving canonical, standard bytes).
        var info: [(String, Bencode)] = [
            ("name", .bytes(Data(name.utf8))),
            ("piece length", .int(Int64(pieceLength))),
            ("pieces", .bytes(pieceHashes)),
        ]
        if options.isPrivate { info.append(("private", .int(1))) }
        if isDir.boolValue {
            let list = files.map { file in
                Bencode.dict([
                    ("length", .int(file.length)),
                    ("path", .list(file.components.map { .bytes(Data($0.utf8)) })),
                ])
            }
            info.append(("files", .list(list)))
        } else {
            info.append(("length", .int(totalLength)))
        }

        var top: [(String, Bencode)] = [("info", .dict(info))]
        if let first = options.trackers.first { top.append(("announce", .bytes(Data(first.utf8)))) }
        if options.trackers.count > 1 {
            top.append(("announce-list", .list(options.trackers.map { .list([.bytes(Data($0.utf8))]) })))
        }
        if let comment = options.comment { top.append(("comment", .bytes(Data(comment.utf8)))) }
        top.append(("created by", .bytes(Data(options.createdBy.utf8))))
        if let date = options.creationDate {
            top.append(("creation date", .int(Int64(date.timeIntervalSince1970))))
        }
        return Bencode.dict(top).encoded
    }

    // MARK: helpers

    private static func singleFile(_ url: URL) -> SourceFile {
        let length = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        return SourceFile(url: url, components: [url.lastPathComponent], length: length)
    }

    /// Recursively collect the regular files under `root`, sorted by path for deterministic output.
    private static func collectFiles(in root: URL) throws -> [SourceFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [])
        else { return [] }
        var files: [SourceFile] = []
        let rootComponents = root.standardizedFileURL.pathComponents
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            if fileURL.lastPathComponent == ".DS_Store" { continue }  // macOS noise
            let components = Array(fileURL.standardizedFileURL.pathComponents.dropFirst(rootComponents.count))
            files.append(SourceFile(url: fileURL, components: components, length: Int64(values.fileSize ?? 0)))
        }
        return files.sorted { $0.components.lexicographicallyPrecedes($1.components) }
    }

    /// Read every file in order and SHA-1 each `pieceLength`-sized chunk (last piece may be short).
    private static func hashPieces(files: [SourceFile], pieceLength: Int) throws -> Data {
        var hashes = Data()
        var buffer = [UInt8]()
        buffer.reserveCapacity(pieceLength)
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file.url) else {
                throw CreateError.readFailed(file.url.lastPathComponent)
            }
            defer { try? handle.close() }
            while true {
                let need = pieceLength - buffer.count
                let chunk = (try? handle.read(upToCount: need)) ?? nil
                guard let chunk, !chunk.isEmpty else { break }
                buffer.append(contentsOf: chunk)
                if buffer.count == pieceLength {
                    hashes.append(Data(Insecure.SHA1.hash(data: Data(buffer))))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        if !buffer.isEmpty { hashes.append(Data(Insecure.SHA1.hash(data: Data(buffer)))) }
        return hashes
    }

    /// Pick a piece length aiming for ~1500 pieces, a power of two clamped to [16 KiB, 8 MiB].
    public static func autoPieceLength(for totalLength: Int64) -> Int {
        let target = max(16 * 1024, min(8 * 1024 * 1024, Int(totalLength / 1500)))
        var length = 16 * 1024
        while length < target { length <<= 1 }
        return length
    }
}
