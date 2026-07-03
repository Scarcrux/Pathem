import Foundation

/// Split a large file into fixed-size parts ("<name>.001", "<name>.002", …) and merge the
/// parts back into the whole, for moving big files across size-limited transports. Streams
/// in chunks so memory stays flat regardless of file size. Pure Foundation, round-trip
/// unit-tested.
public enum FileSplitter {
    public enum SplitError: Error, Equatable { case invalidSize, notAPart, noParts }

    /// Split `file` into parts of `partSize` bytes in `directory` (default: the file's own
    /// folder). Returns the created part URLs, in order.
    @discardableResult
    public static func split(_ file: URL, partSize: Int64, into directory: URL? = nil) throws -> [URL] {
        guard partSize > 0 else { throw SplitError.invalidSize }
        let fm = FileManager.default
        let dir = directory ?? file.deletingLastPathComponent()
        let base = file.lastPathComponent
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let chunkSize = 1 << 20  // 1 MB read granularity
        var parts: [URL] = []
        var index = 1
        while true {
            let part = dir.appendingPathComponent(String(format: "%@.%03d", base, index))
            fm.createFile(atPath: part.path, contents: nil)
            let output = try FileHandle(forWritingTo: part)
            var written: Int64 = 0
            while written < partSize {
                let want = Int(min(Int64(chunkSize), partSize - written))
                let data = try input.read(upToCount: want) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data)
                written += Int64(data.count)
            }
            try? output.close()
            if written == 0 {  // hit EOF exactly on a boundary: drop the empty trailing part
                try? fm.removeItem(at: part)
                break
            }
            parts.append(part)
            if written < partSize { break }  // short read means this was the last part
            index += 1
        }
        return parts
    }

    /// Merge the sequential parts starting at `firstPart` ("<name>.001") back into "<name>"
    /// in the same folder (uniquified if it exists). Returns the merged file's URL.
    @discardableResult
    public static func merge(firstPart: URL, into output: URL? = nil) throws -> URL {
        let name = firstPart.lastPathComponent
        // Require a trailing ".<digits>" suffix and recover the base name.
        guard let dot = name.range(of: ".", options: .backwards),
            !name[dot.upperBound...].isEmpty,
            name[dot.upperBound...].allSatisfy(\.isNumber)
        else { throw SplitError.notAPart }
        let base = String(name[..<dot.lowerBound])
        let dir = firstPart.deletingLastPathComponent()
        let fm = FileManager.default
        let outURL = output ?? unique(dir.appendingPathComponent(base))
        fm.createFile(atPath: outURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        defer { try? out.close() }
        var index = 1
        while true {
            let part = dir.appendingPathComponent(String(format: "%@.%03d", base, index))
            guard fm.fileExists(atPath: part.path) else { break }
            let handle = try FileHandle(forReadingFrom: part)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try? handle.close()
            index += 1
        }
        guard index > 1 else { throw SplitError.noParts }
        return outURL
    }

    private static func unique(_ url: URL) -> URL {
        FileManager.default.fileExists(atPath: url.path)
            ? FileOperations.suffixedName(url, suffix: "merged") : url
    }
}
