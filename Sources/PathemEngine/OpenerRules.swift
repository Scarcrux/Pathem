import Foundation

/// User-chosen default applications for opening files, scoped by individual file,
/// by folder subtree, or by file extension. Persisted as config-as-data
/// (openers.json). "Session" scope is intentionally not stored here; the app
/// keeps that in memory and checks it first. App values are application paths.
public struct OpenerRules: Codable, Sendable, Equatable {
    public var byFile: [String: String]
    public var byFolder: [String: String]
    public var byType: [String: String]  // lowercased extension -> app path

    public init(
        byFile: [String: String] = [:], byFolder: [String: String] = [:],
        byType: [String: String] = [:]
    ) {
        self.byFile = byFile
        self.byFolder = byFolder
        self.byType = byType
    }

    public mutating func setFile(_ path: String, app: String) { byFile[path] = app }
    public mutating func setFolder(_ path: String, app: String) { byFolder[path] = app }
    public mutating func setType(_ ext: String, app: String) { byType[ext.lowercased()] = app }

    /// The persisted default app for a file at `path`, by precedence: the file's
    /// own rule, then the most specific (longest) enclosing folder rule, then its
    /// extension rule. nil means "no rule; use the session override or the system
    /// default" (the caller layers session scope on top).
    public func app(forPath path: String, ext: String) -> String? {
        if let app = byFile[path] { return app }
        var best: (length: Int, app: String)?
        for (folder, app) in byFolder where Self.isUnder(path, folder) {
            if best == nil || folder.count > best!.length { best = (folder.count, app) }
        }
        if let best { return best.app }
        return byType[ext.lowercased()]
    }

    static func isUnder(_ path: String, _ prefix: String) -> Bool {
        var base = prefix
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        if path == base { return true }
        if base == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(base + "/")
    }
}
