import Foundation

/// Persisted "virtual folders": named, durable sets of files gathered from anywhere
/// (unlike the ephemeral shelf). Config-as-data (collections.json). Pure logic so
/// add/dedup/remove is unit-tested; the app renders a collection as a cross-folder
/// list and acts on the real files.
public struct FileCollection: Codable, Sendable, Equatable {
    public var name: String
    public var paths: [String]

    public init(name: String, paths: [String] = []) {
        self.name = name
        self.paths = paths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
    }

    private enum CodingKeys: String, CodingKey { case name, paths }
}

public struct Collections: Codable, Sendable, Equatable {
    public private(set) var collections: [FileCollection]

    public init(collections: [FileCollection] = []) { self.collections = collections }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collections = try c.decodeIfPresent([FileCollection].self, forKey: .collections) ?? []
    }

    private enum CodingKeys: String, CodingKey { case collections }

    public func collection(named name: String) -> FileCollection? {
        collections.first { $0.name == name }
    }

    public var names: [String] { collections.map(\.name) }

    /// Append paths to a named collection (creating it if needed), de-duplicating.
    public mutating func add(_ paths: [String], to name: String) {
        let index = collections.firstIndex { $0.name == name } ?? {
            collections.append(FileCollection(name: name))
            return collections.count - 1
        }()
        var seen = Set(collections[index].paths)
        for path in paths where seen.insert(path).inserted { collections[index].paths.append(path) }
    }

    public mutating func remove(_ path: String, from name: String) {
        guard let index = collections.firstIndex(where: { $0.name == name }) else { return }
        collections[index].paths.removeAll { $0 == path }
    }

    public mutating func removeCollection(named name: String) {
        collections.removeAll { $0.name == name }
    }
}
