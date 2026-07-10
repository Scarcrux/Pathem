import Foundation

/// GetRight-style web seeding (BEP 19): download pieces from a plain HTTP server listed in the
/// torrent's `url-list`, using HTTP range requests. A web seed is effectively a peer that has
/// everything. The URL construction is pure and unit-tested; `fetchPiece` does the range GETs.
public enum WebSeed {
    /// The URL of a file within the torrent under a web-seed base URL. For a single-file torrent a
    /// base ending in "/" gets the name appended, otherwise it is the file itself. For a multi-file
    /// torrent the torrent name and the file's path are appended (BEP 19).
    public static func fileURL(base: String, torrentName: String, filePath: String, singleFile: Bool) -> URL? {
        guard var url = URL(string: base) else { return nil }
        if singleFile {
            if base.hasSuffix("/") { url.appendPathComponent(torrentName) }
            return url
        }
        url.appendPathComponent(torrentName)
        for component in filePath.split(separator: "/") { url.appendPathComponent(String(component)) }
        return url
    }

    /// Fetch a whole piece from a web seed via range requests (one per file the piece spans).
    /// Returns the piece bytes, or nil if the server doesn't support ranges or a request fails.
    public static func fetchPiece(
        base: String, torrent: TorrentFile, layout: FileLayout, index: Int, pieceSize: Int,
        session: URLSession = .shared
    ) async -> Data? {
        let start = Int64(index) * torrent.pieceLength
        let segments = layout.segments(at: start, length: Int64(pieceSize))
        let singleFile = torrent.files.count == 1
        var out = Data()
        for segment in segments {
            guard let url = fileURL(base: base, torrentName: torrent.name, filePath: segment.path, singleFile: singleFile)
            else { return nil }
            var request = URLRequest(url: url)
            let last = segment.fileOffset + segment.length - 1
            request.setValue("bytes=\(segment.fileOffset)-\(last)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 30
            guard let (data, response) = try? await session.data(for: request),
                let http = response as? HTTPURLResponse, http.statusCode == 206,  // require range support
                data.count == Int(segment.length)
            else { return nil }
            out.append(data)
        }
        return out.count == pieceSize ? out : nil
    }
}
