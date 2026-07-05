import Foundation

/// Imports servers from FileZilla's Site Manager file (sitemanager.xml). This
/// reads the user's own data file by parsing its documented XML shape; no
/// FileZilla source is used (FileZilla is GPL). Passwords are intentionally not
/// imported.
public enum FileZillaImporter {
    /// Locate FileZilla's sitemanager.xml in the usual macOS locations.
    public static func defaultSiteManagerURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".config/filezilla/sitemanager.xml"),
            home.appendingPathComponent(".filezilla/sitemanager.xml"),
            home.appendingPathComponent("Library/Application Support/FileZilla/sitemanager.xml"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The FileZilla config folder to open a file picker in (the first that exists), so the
    /// user lands where sitemanager.xml lives instead of a random folder. nil if none exist.
    public static func defaultConfigDirectory() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [
            home.appendingPathComponent(".config/filezilla"),
            home.appendingPathComponent(".filezilla"),
            home.appendingPathComponent("Library/Application Support/FileZilla"),
        ]
        return dirs.first { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    public static func importSites(from url: URL) -> [RemoteConnection] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }

    /// Parse sitemanager.xml data into connections. Each <Server> carries the
    /// connection fields as child elements and the site name as its text content.
    public static func parse(_ data: Data) -> [RemoteConnection] {
        // Never resolve external entities: a hostile sitemanager.xml could
        // otherwise read local files into fields (XXE) inside the app process.
        guard let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
            let servers = (try? doc.nodes(forXPath: "//Server")) as? [XMLElement]
        else { return [] }
        return servers.compactMap { parseServer($0) }
    }

    private static func parseServer(_ element: XMLElement) -> RemoteConnection? {
        func child(_ name: String) -> String? {
            element.elements(forName: name).first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let host = child("Host"), !host.isEmpty else { return nil }

        let proto = mapProtocol(child("Protocol"))
        // Normalize out-of-range/invalid ports to 0 ("use the protocol default").
        let parsedPort = Int(child("Port") ?? "") ?? 0
        let port = (1...65535).contains(parsedPort) ? parsedPort : 0
        let user = child("User") ?? ""
        // RemoteDir/LocalDir are intentionally not imported (FileZilla's encoded
        // path format is brittle); connections start at "/".
        // FileZilla stores the site name as the element's own text content (mixed
        // content alongside the child elements); fall back to the host.
        let name = siteName(element) ?? host

        return RemoteConnection(name: name, proto: proto, host: host, port: port, user: user)
    }

    /// FileZilla protocol codes: 1 = SFTP; 3/4/6 = FTP over TLS (FTPS); else FTP.
    private static func mapProtocol(_ raw: String?) -> RemoteConnection.Proto {
        switch raw {
        case "1": return .sftp
        case "3", "4", "6": return .ftps
        default: return .ftp
        }
    }

    private static func siteName(_ element: XMLElement) -> String? {
        let text = (element.children ?? [])
            .filter { $0.kind == .text }
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return text
    }
}
