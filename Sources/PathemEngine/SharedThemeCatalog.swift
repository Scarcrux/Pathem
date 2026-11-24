import Foundation

/// Published snapshots contain only approved, current revisions and no private review notes.
public struct SharedThemeCatalog: Codable, Sendable {
    public static let maximumBytes = 24 * 1024 * 1024
    public let schemaVersion: Int
    public let themes: [CommunityThemeRevision]

    public init(reviewed gallery: CommunityThemeGallery) {
        schemaVersion = 1
        themes = gallery.discover()
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CommunityThemeError.oversizedFile }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1,
            Set(catalog.themes.map(\.id)).count == catalog.themes.count
        else { throw CommunityThemeError.invalidListing }
        for theme in catalog.themes { try theme.validate() }
        return catalog
    }

    public static func fetch(_ endpoint: String) async throws -> Self {
        guard let url = URL(string: endpoint), url.host != nil, url.user == nil,
            url.password == nil,
            url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1")
        else { throw URLError(.unsupportedURL) }
        // A review can publish twice in the same second. Filesystem Last-Modified dates
        // have only second precision, so a cached conditional response can hide the update.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.expectedContentLength <= SharedThemeCatalog.maximumBytes,
            let finalURL = response.url, finalURL.host == url.host, finalURL.scheme == url.scheme
        else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < SharedThemeCatalog.maximumBytes
            else { throw CommunityThemeError.oversizedFile }
            data.append(byte)
        }
        return try decode(data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw CommunityThemeError.oversizedFile }
        return data
    }
}
