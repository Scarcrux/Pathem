import Foundation

/// WebDAV backend that shells out to the system `curl` (a separate process), mirroring
/// CurlFTPProvider. Listing is a PROPFIND (Depth: 1); transfers and directory ops use
/// the WebDAV verbs GET/PUT/MKCOL/DELETE/MOVE. HTTP errors surface via curl's `-f`.
public struct CurlWebDAVProvider: RemoteProvider {
    public init() {}

    private static let propfindBody =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        + "<propfind xmlns=\"DAV:\"><prop>"
        + "<resourcetype/><getcontentlength/><getlastmodified/><displayname/>"
        + "</prop></propfind>"

    public func list(_ connection: RemoteConnection, path: String, password: String) async throws
        -> [FileEntry]
    {
        try require(connection)
        var dir = path.isEmpty ? "/" : path
        if !dir.hasSuffix("/") { dir += "/" }  // a collection URL ends in "/"
        let (data, status, err) = try await run(
            connection, password,
            ["-X", "PROPFIND", "-H", "Depth: 1", "--data", Self.propfindBody, endpoint(connection, dir)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
        return WebDAVListParser.parse(data, requestPath: dir)
    }

    public func download(
        _ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String
    ) async throws {
        try require(connection)
        let (_, status, err) = try await run(
            connection, password, ["-o", localFile.path, endpoint(connection, remotePath)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func upload(
        _ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String
    ) async throws {
        try require(connection)
        let (_, status, err) = try await run(
            connection, password, ["-T", localFile.path, endpoint(connection, remotePath)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func makeDirectory(_ connection: RemoteConnection, path: String, password: String) async throws {
        try require(connection)
        var dir = path
        if !dir.hasSuffix("/") { dir += "/" }
        let (_, status, err) = try await run(
            connection, password, ["-X", "MKCOL", endpoint(connection, dir)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func remove(
        _ connection: RemoteConnection, path: String, isDirectory: Bool, password: String
    ) async throws {
        try require(connection)
        let target = isDirectory && !path.hasSuffix("/") ? path + "/" : path
        let (_, status, err) = try await run(
            connection, password, ["-X", "DELETE", endpoint(connection, target)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func rename(_ connection: RemoteConnection, from: String, to: String, password: String) async throws {
        try require(connection)
        // The Destination is a full, percent-encoded URL (so a name can't inject a header);
        // Overwrite: F refuses to clobber an existing item.
        let (_, status, err) = try await run(
            connection, password,
            ["-X", "MOVE", "-H", "Destination: \(endpoint(connection, to))", "-H", "Overwrite: F",
             endpoint(connection, from)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    // MARK: Helpers

    private func require(_ c: RemoteConnection) throws {
        guard c.proto.isWebDAV else {
            throw RemoteError.unsupported("CurlWebDAVProvider handles WebDAV only")
        }
        guard c.hasValidHost else { throw RemoteError.unsupported("Invalid host \"\(c.host)\"") }
    }

    func endpoint(_ c: RemoteConnection, _ path: String) -> String {
        let clean = path.hasPrefix("/") ? path : "/" + path
        let encoded = clean.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let scheme = c.proto == .webdavs ? "https" : "http"
        return "\(scheme)://\(c.host):\(c.effectivePort)\(encoded)"
    }

    private func run(_ c: RemoteConnection, _ password: String, _ opArgs: [String]) async throws
        -> (Data, Int32, String)
    {
        let base = [
            "-q", "-s", "--show-error", "-f", "--globoff", "--proto", "=http,https",
            "--connect-timeout", "20", "--anyauth", "-K", "-",
        ]
        return try await CurlFTPProvider.runCurl(base + opArgs, input: Self.credentials(c, password))
    }

    /// curl config (read via `-K -` on stdin) carrying credentials, so the password
    /// never appears in the argument list. An empty user means an unauthenticated GET.
    static func credentials(_ c: RemoteConnection, _ password: String) -> String {
        guard !c.user.isEmpty else { return "" }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\u{0B}", with: "\\v")
        }
        return "user \"\(esc(c.user)):\(esc(password))\"\n"
    }
}
