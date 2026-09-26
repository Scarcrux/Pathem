import Foundation

/// Azure Blob Storage backend, run out-of-process via the system `curl`. Auth is
/// Shared Key (HMAC-SHA256 over a canonicalized request, computed here by
/// `AzureSharedKey` and passed as an `Authorization` header) -- curl has no built-in
/// support for it, unlike S3's `--aws-sigv4`. Only the derived *signature* ever
/// reaches the argument list; the account key is never on it (nothing for `ps` to
/// leak). The connection's `user` is the storage account name and the password is
/// the account key; `host` may be left blank (derived as `<account>.blob.core.windows.net`).
///
/// Listing uses "List Blobs" with a "/" delimiter so prefixes read as folders; the
/// account root lists containers. The signer has fixed-vector unit coverage, and the
/// full provider runs against a signature-validating HTTPS fixture in product E2E.
public struct AzureBlobProvider: RemoteProvider {
    public init() {}

    public func list(_ connection: RemoteConnection, path: String, password: String) async throws
        -> [FileEntry]
    {
        try require(connection)
        let (container, prefix) = Self.split(path)
        var entries: [FileEntry] = []
        var marker: String?
        repeat {
            let req: Request
            if container.isEmpty {  // account root: list containers
                var query = [(name: "comp", value: "list")]
                if let marker { query.append((name: "marker", value: marker)) }
                req = Request(method: "GET", encodedPath: "/", query: query)
            } else {  // inside a container: list blobs + prefixes
                var query = [
                    (name: "restype", value: "container"), (name: "comp", value: "list"),
                    (name: "delimiter", value: "/"), (name: "prefix", value: prefix),
                ]
                if let marker { query.append((name: "marker", value: marker)) }
                req = Request(
                    method: "GET", encodedPath: Self.encodePath(container: container, key: ""),
                    query: query)
            }
            let (data, status, err) = try await run(connection, password, req)
            guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
            let result =
                container.isEmpty
                ? AzureListParser.parseContainers(data)
                : AzureListParser.parseBlobs(data, prefix: prefix)
            entries += result.entries
            marker = result.nextMarker
        } while marker != nil && entries.count < 100_000
        return entries
    }

    public func download(
        _ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String
    ) async throws {
        try require(connection)
        let (container, key) = Self.split(remotePath)
        let req = Request(
            method: "GET", encodedPath: Self.encodePath(container: container, key: key))
        let (_, status, err) = try await run(
            connection, password, req, extra: ["-o", localFile.path])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func upload(
        _ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String
    ) async throws {
        try require(connection)
        let (container, key) = Self.split(remotePath)
        let size =
            ((try? FileManager.default.attributesOfItem(atPath: localFile.path))?[.size]
            as? NSNumber)?
            .intValue ?? 0
        let req = Request(
            method: "PUT", encodedPath: Self.encodePath(container: container, key: key),
            xms: ["x-ms-blob-type": "BlockBlob"], contentLength: size)
        let (_, status, err) = try await run(
            connection, password, req, extra: ["-T", localFile.path])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func makeDirectory(_ connection: RemoteConnection, path: String, password: String)
        async throws
    {
        try require(connection)
        let (container, key) = Self.split(path)
        let req: Request
        var extra: [String] = []
        if key.isEmpty {  // a top-level name is a container: create it
            req = Request(
                method: "PUT", encodedPath: Self.encodePath(container: container, key: ""),
                query: [(name: "restype", value: "container")])
        } else {  // a sub-folder is a zero-byte marker blob ending in "/"
            let marker = key.hasSuffix("/") ? key : key + "/"
            req = Request(
                method: "PUT", encodedPath: Self.encodePath(container: container, key: marker),
                xms: ["x-ms-blob-type": "BlockBlob"], contentLength: 0)
            // curl treats an upload URL ending in "/" as a directory and appends the
            // local filename. An explicit empty body preserves the marker's trailing slash.
            extra = ["-H", "Content-Type:", "--data-binary", ""]
        }
        let (_, status, err) = try await run(connection, password, req, extra: extra)
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func remove(
        _ connection: RemoteConnection, path: String, isDirectory: Bool, password: String
    ) async throws {
        try require(connection)
        let (container, key) = Self.split(path)
        let req: Request
        if key.isEmpty {  // delete the container
            req = Request(
                method: "DELETE", encodedPath: Self.encodePath(container: container, key: ""),
                query: [(name: "restype", value: "container")])
        } else {
            let target = isDirectory && !key.hasSuffix("/") ? key + "/" : key
            req = Request(
                method: "DELETE", encodedPath: Self.encodePath(container: container, key: target))
        }
        let (_, status, err) = try await run(connection, password, req)
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func rename(_ connection: RemoteConnection, from: String, to: String, password: String)
        async throws
    {
        try require(connection)
        // Azure has no move: "Put Blob From URL" copies the source synchronously (so a
        // delete-after is safe), then the source is removed.
        let (fromContainer, fromKey) = Self.split(from)
        let (toContainer, toKey) = Self.split(to)
        let sourceURL =
            "\(Self.base(connection))\(Self.encodePath(container: fromContainer, key: fromKey))"
        let copy = Request(
            method: "PUT", encodedPath: Self.encodePath(container: toContainer, key: toKey),
            xms: ["x-ms-blob-type": "BlockBlob", "x-ms-copy-source": sourceURL], contentLength: 0)
        let (_, copyStatus, copyErr) = try await run(connection, password, copy)
        guard copyStatus == 0 else { throw RemoteError.curl(code: copyStatus, message: copyErr) }
        let del = Request(
            method: "DELETE", encodedPath: Self.encodePath(container: fromContainer, key: fromKey))
        let (_, delStatus, delErr) = try await run(connection, password, del)
        guard delStatus == 0 else { throw RemoteError.curl(code: delStatus, message: delErr) }
    }

    // MARK: - Request building (static + date-injected, so it's testable)

    /// Everything needed to issue one signed Azure request.
    struct Request {
        var method: String
        var encodedPath: String  // leading "/", each segment percent-encoded
        var query: [(name: String, value: String)] = []  // decoded names/values
        var xms: [String: String] = [:]  // extra x-ms-* headers beyond date/version
        var contentLength: Int = 0
        var contentType: String = ""
    }

    /// The storage account name (the connection user).
    static func account(_ c: RemoteConnection) -> String { c.user }

    /// The endpoint host: explicit, or the default `<account>.blob.core.windows.net`.
    static func host(_ c: RemoteConnection) -> String {
        c.host.isEmpty ? "\(c.user).blob.core.windows.net" : c.host
    }

    /// Keep the standard endpoint clean while honoring an explicit emulator/custom-service port.
    static func base(_ c: RemoteConnection) -> String {
        let suffix = c.effectivePort == 443 ? "" : ":\(c.effectivePort)"
        return "https://\(host(c))\(suffix)"
    }

    /// Build the request URL and curl header arguments, signing with Shared Key. Static
    /// and date-injected so a fixed date yields a fixed, checkable signature.
    static func build(_ c: RemoteConnection, _ key: String, _ req: Request, date: Date) throws
        -> (url: String, headerArgs: [String])
    {
        var headers = req.xms
        headers["x-ms-date"] = AzureSharedKey.rfc1123(date)
        headers["x-ms-version"] = AzureSharedKey.apiVersion
        let resource = AzureSharedKey.canonicalizedResource(
            account: account(c), path: req.encodedPath, query: req.query)
        let stringToSign = AzureSharedKey.stringToSign(
            verb: req.method, contentLength: req.contentLength, contentType: req.contentType,
            xmsHeaders: headers, canonicalizedResource: resource)
        guard
            let auth = AzureSharedKey.authorization(
                account: account(c), key: key, stringToSign: stringToSign)
        else {
            throw RemoteError.unsupported("Azure account key must be base64")
        }
        var headerArgs = ["-H", "Authorization: \(auth)"]
        for name in headers.keys.sorted() { headerArgs += ["-H", "\(name): \(headers[name]!)"] }
        let queryString = req.query
            .map { "\(pctQuery($0.name))=\(pctQuery($0.value))" }
            .joined(separator: "&")
        let url = "\(base(c))\(req.encodedPath)" + (queryString.isEmpty ? "" : "?\(queryString)")
        return (url, headerArgs)
    }

    // MARK: - Helpers

    private func require(_ c: RemoteConnection) throws {
        guard c.proto == .azure else {
            throw RemoteError.unsupported("AzureBlobProvider handles Azure only")
        }
        guard Self.isValidAccount(c.user) else {
            throw RemoteError.unsupported("Invalid Azure account name")
        }
        guard RemoteConnection.isValidHost(Self.host(c)) else {
            throw RemoteError.unsupported("Invalid Azure endpoint host")
        }
    }

    /// Storage account names are lowercase alphanumeric (3-24); accept up to 63 to be
    /// lenient with emulator names. Validated because it's interpolated into the host.
    static func isValidAccount(_ a: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        return a.count >= 3 && a.count <= 63 && a.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Split "/container/key..." into (container, key); key keeps any trailing slash.
    static func split(_ path: String) -> (container: String, key: String) {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let slash = trimmed.firstIndex(of: "/") else { return (trimmed, "") }
        return (String(trimmed[..<slash]), String(trimmed[trimmed.index(after: slash)...]))
    }

    /// "/container/enc(key)" with each path segment percent-encoded. The same encoded
    /// string is used in the URL and in the canonicalized resource, so they always agree.
    static func encodePath(container: String, key: String) -> String {
        var path = "/" + seg(container)
        if !key.isEmpty {
            let encodedKey = key.split(separator: "/", omittingEmptySubsequences: false)
                .map { seg(String($0)) }
                .joined(separator: "/")
            path += "/" + encodedKey
        }
        return path
    }

    private static func seg(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// Percent-encode a query name/value (RFC 3986 unreserved only, so "/" becomes %2F).
    static func pctQuery(_ s: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func run(
        _ c: RemoteConnection, _ password: String, _ req: Request, extra: [String] = []
    )
        async throws -> (Data, Int32, String)
    {
        let (url, headerArgs) = try Self.build(c, password, req, date: Date())
        // -T implies PUT; otherwise a non-GET verb needs an explicit -X.
        let hasUpload = extra.contains("-T")
        let method = (req.method != "GET" && !hasUpload) ? ["-X", req.method] : []
        let base = [
            "-q", "-s", "--show-error", "-f", "--globoff", "--proto", "=https",
            "--connect-timeout", "20",
        ]
        let args = base + RemoteLimits.curlArgs + headerArgs + method + extra + [url]
        return try await CurlFTPProvider.runCurl(args)
    }
}
