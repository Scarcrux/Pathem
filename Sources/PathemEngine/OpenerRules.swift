import Foundation

/// User-chosen default applications for opening files, scoped by individual file,
/// by folder subtree, by exact filename (for names with no extension, such as `.env` or
/// `Makefile`, which the system cannot express as a type), or by file extension. Persisted as config-as-data
/// (openers.json). "Session" scope is intentionally not stored here; the app
/// keeps that in memory and checks it first. App values are application paths.
public struct OpenerRules: Codable, Sendable, Equatable {
    public var byFile: [String: String]
    public var byFolder: [String: String]
    public var byType: [String: String]  // lowercased extension -> app path
    public var byName: [String: String]  // lowercased filename -> app path

    public init(
        byFile: [String: String] = [:], byFolder: [String: String] = [:],
        byType: [String: String] = [:], byName: [String: String] = [:]
    ) {
        self.byFile = byFile
        self.byFolder = byFolder
        self.byType = byType
        self.byName = byName
    }

    // Tolerant: an older openers.json missing one of the maps loads it as empty
    // instead of failing the whole file and dropping every opener rule.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        byFile = try c.decodeIfPresent([String: String].self, forKey: .byFile) ?? [:]
        byFolder = try c.decodeIfPresent([String: String].self, forKey: .byFolder) ?? [:]
        byType = try c.decodeIfPresent([String: String].self, forKey: .byType) ?? [:]
        byName = try c.decodeIfPresent([String: String].self, forKey: .byName) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case byFile, byFolder, byType, byName }

    public mutating func setFile(_ path: String, app: String) { byFile[path] = app }
    public mutating func setFolder(_ path: String, app: String) { byFolder[path] = app }
    public mutating func setType(_ ext: String, app: String) { byType[ext.lowercased()] = app }
    public mutating func setName(_ name: String, app: String) { byName[name.lowercased()] = app }
    /// Drop any per-extension rule so the system default becomes authoritative for that kind.
    public mutating func clearType(_ ext: String) { byType[ext.lowercased()] = nil }

    /// The persisted default app for a file at `path`, by precedence: the file's
    /// own rule, then the most specific (longest) enclosing folder rule, then its
    /// extension rule. nil means "no rule".
    public func app(forPath path: String, ext: String) -> String? {
        appByFileOrFolder(path: path) ?? byType[ext.lowercased()]
    }

    /// Only the file/folder rules (no extension fallback), so a caller can layer a
    /// session-by-type override between folder and type precedence.
    public func appByFileOrFolder(path: String) -> String? {
        if let app = byFile[path] { return app }
        var best: (length: Int, app: String)?
        for (folder, app) in byFolder where Self.isUnder(path, folder) {
            if best == nil || folder.count > best!.length { best = (folder.count, app) }
        }
        return best?.app
    }

    /// The extension rule only.
    public func app(forType ext: String) -> String? { byType[ext.lowercased()] }

    /// The exact-filename rule only.
    public func app(forName name: String) -> String? { byName[name.lowercased()] }

    /// The key that identifies a file's "kind" for session and per-kind choices: its
    /// extension, or for a name with no extension, the whole name. Without the name,
    /// every extension-less file would share the empty key.
    public static func kindKey(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "name:" + name.lowercased() : ext
    }

    static func isUnder(_ path: String, _ prefix: String) -> Bool {
        var base = prefix
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        if path == base { return true }
        if base == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(base + "/")
    }
}
