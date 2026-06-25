import Foundation

/// Amazon S3 (and S3-compatible: MinIO, Backblaze B2, etc.) via the system `curl`'s
/// built-in SigV4 signing (`--aws-sigv4`), run out-of-process like the other backends.
/// Path-style addressing (host/bucket/key) for broad compatibility. The connection's
/// `user`/password are the access key id / secret; `region` drives signing; `host` may
/// be left empty for AWS (derived from the region). Listing uses ListObjectsV2 with a
/// "/" delimiter so prefixes read as folders.
public struct S3Provider: RemoteProvider {
    public init() {}

    public func list(_ connection: RemoteConnection, path: String, password: String) async throws
        -> [FileEntry]
    {
        try require(connection)
        let (bucket, prefix) = Self.split(path)
        guard !bucket.isEmpty else { return [] }  // no bucket yet: nothing to list
        var entries: [FileEntry] = []
        var token: String?
        repeat {
            var query = "list-type=2&delimiter=%2F&prefix=\(Self.q(prefix))"
            if let token { query += "&continuation-token=\(Self.q(token))" }
            let url = "\(Self.base(connection))/\(Self.seg(bucket))?\(query)"
            let (data, status, err) = try await run(connection, password, [url])
            guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
            let result = S3ListParser.parse(data, prefix: prefix)
            entries += result.entries
            token = result.nextToken
        } while token != nil && entries.count < 100_000
        return entries
    }

    public func download(
        _ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String
    ) async throws {
        try require(connection)
        let (_, status, err) = try await run(
            connection, password, ["-o", localFile.path, Self.objectURL(connection, remotePath)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func upload(
        _ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String
    ) async throws {
        try require(connection)
        let (_, status, err) = try await run(
            connection, password, ["-T", localFile.path, Self.objectURL(connection, remotePath)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func makeDirectory(_ connection: RemoteConnection, path: String, password: String) async throws {
        try require(connection)
        // S3 has no real folders; create a zero-byte marker object ending in "/".
        let marker = path.hasSuffix("/") ? path : path + "/"
        let (_, status, err) = try await run(
            connection, password, ["-T", "/dev/null", Self.objectURL(connection, marker)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func remove(
        _ connection: RemoteConnection, path: String, isDirectory: Bool, password: String
    ) async throws {
        try require(connection)
        // Deletes the object (or the folder marker); object listings under a prefix are
        // not recursively removed (an S3 limitation surfaced honestly).
        let target = isDirectory && !path.hasSuffix("/") ? path + "/" : path
        let (_, status, err) = try await run(
            connection, password, ["-X", "DELETE", Self.objectURL(connection, target)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func rename(_ connection: RemoteConnection, from: String, to: String, password: String) async throws {
        try require(connection)
        // S3 has no move: copy then delete the source.
        let (fromBucket, fromKey) = Self.split(from)
        let copySource = "/\(Self.seg(fromBucket))/\(Self.encodeKey(fromKey))"
        let (_, copyStatus, copyErr) = try await run(
            connection, password,
            ["-X", "PUT", "-H", "x-amz-copy-source: \(copySource)", Self.objectURL(connection, to)])
        guard copyStatus == 0 else { throw RemoteError.curl(code: copyStatus, message: copyErr) }
        let (_, delStatus, delErr) = try await run(
            connection, password, ["-X", "DELETE", Self.objectURL(connection, from)])
        guard delStatus == 0 else { throw RemoteError.curl(code: delStatus, message: delErr) }
    }

    // MARK: Helpers

    private func require(_ c: RemoteConnection) throws {
        guard c.proto == .s3 else { throw RemoteError.unsupported("S3Provider handles S3 only") }
        guard RemoteConnection.isValidHost(Self.host(c)) else {
            throw RemoteError.unsupported("Invalid S3 endpoint host")
        }
        guard Self.regionIsValid(c.region) else { throw RemoteError.unsupported("Invalid S3 region") }
    }

    static func regionIsValid(_ region: String) -> Bool {
        region.isEmpty
            || region.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }
    }

    /// Endpoint host: explicit, or AWS regional default derived from the region.
    static func host(_ c: RemoteConnection) -> String {
        if !c.host.isEmpty { return c.host }
        let region = c.region.isEmpty ? "us-east-1" : c.region
        return "s3.\(region).amazonaws.com"
    }

    static func base(_ c: RemoteConnection) -> String { "https://\(host(c)):\(c.effectivePort)" }

    /// Split "/bucket/key..." into (bucket, key); key keeps any trailing slash.
    static func split(_ path: String) -> (bucket: String, key: String) {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let slash = trimmed.firstIndex(of: "/") else { return (trimmed, "") }
        return (String(trimmed[..<slash]), String(trimmed[trimmed.index(after: slash)...]))
    }

    static func objectURL(_ c: RemoteConnection, _ path: String) -> String {
        let (bucket, key) = split(path)
        return "\(base(c))/\(seg(bucket))/\(encodeKey(key))"
    }

    /// Percent-encode a single path segment (a bucket name).
    static func seg(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
    /// Percent-encode an object key, preserving "/" separators.
    static func encodeKey(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }
    /// Percent-encode a query value (RFC 3986 unreserved plus "/").
    static func q(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func run(_ c: RemoteConnection, _ password: String, _ opArgs: [String]) async throws
        -> (Data, Int32, String)
    {
        let region = c.region.isEmpty ? "us-east-1" : c.region
        let base = [
            "-q", "-s", "--show-error", "-f", "--globoff", "--proto", "=https",
            "--connect-timeout", "20", "--aws-sigv4", "aws:amz:\(region):s3", "-K", "-",
        ]
        return try await CurlFTPProvider.runCurl(base + RemoteLimits.curlArgs + opArgs, input: Self.credentials(c, password))
    }

    /// curl config carrying the access key id / secret (the password), kept off the
    /// argument list. --aws-sigv4 uses these to sign the request.
    static func credentials(_ c: RemoteConnection, _ password: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
        }
        return "user \"\(esc(c.user)):\(esc(password))\"\n"
    }
}
