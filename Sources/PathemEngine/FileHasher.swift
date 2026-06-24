import CryptoKit
import Foundation

/// Streaming file checksums (SHA-256, SHA-1, MD5) for Get Info, "Copy SHA-256",
/// verify-a-download, and as the content-identity primitive the duplicate finder and
/// content-accurate compare build on. Reads in bounded chunks so a huge file never
/// loads into memory; callers run it off the main thread.
public enum FileHasher {
    public enum Algorithm: String, Sendable, CaseIterable {
        case sha256, sha1, md5
        public var label: String {
            switch self {
            case .sha256: return "SHA-256"
            case .sha1: return "SHA-1"
            case .md5: return "MD5"
            }
        }
    }

    /// The lowercase hex digest of the file at `url`. Throws if it can't be read.
    public static func hash(_ url: URL, algorithm: Algorithm = .sha256, bufferSize: Int = 1 << 20)
        throws -> String
    {
        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            return try digest(of: url, into: &hasher, bufferSize: bufferSize)
        case .sha1:
            var hasher = Insecure.SHA1()
            return try digest(of: url, into: &hasher, bufferSize: bufferSize)
        case .md5:
            var hasher = Insecure.MD5()
            return try digest(of: url, into: &hasher, bufferSize: bufferSize)
        }
    }

    private static func digest<H: HashFunction>(of url: URL, into hasher: inout H, bufferSize: Int)
        throws -> String
    {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
