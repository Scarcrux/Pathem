import Foundation

/// Apply metadata changes to a whole selection at once: modification/creation date, POSIX
/// permissions, and Finder tags. Only the fields that are set are touched. Pure Foundation,
/// unit-tested. (Get Info edits one item; this is the batch version.)
public enum BulkAttributes {
    public struct Changes: Sendable, Equatable {
        public var modificationDate: Date?
        public var creationDate: Date?
        public var posixPermissions: UInt16?  // low 12 bits, e.g. 0o644
        public var addTags: [String]
        public var removeTags: [String]

        public init(
            modificationDate: Date? = nil, creationDate: Date? = nil, posixPermissions: UInt16? = nil,
            addTags: [String] = [], removeTags: [String] = []
        ) {
            self.modificationDate = modificationDate
            self.creationDate = creationDate
            self.posixPermissions = posixPermissions
            self.addTags = addTags
            self.removeTags = removeTags
        }

        public var isEmpty: Bool {
            modificationDate == nil && creationDate == nil && posixPermissions == nil
                && addTags.isEmpty && removeTags.isEmpty
        }
    }

    public struct Result: Sendable, Equatable {
        public var changed = 0
        public var failures: [FileOperations.Failure] = []
        public init() {}
    }

    public static func apply(_ changes: Changes, to urls: [URL]) -> Result {
        var result = Result()
        guard !changes.isEmpty else { return result }
        let fm = FileManager.default
        for url in urls {
            do {
                var attributes: [FileAttributeKey: Any] = [:]
                if let date = changes.modificationDate { attributes[.modificationDate] = date }
                if let date = changes.creationDate { attributes[.creationDate] = date }
                if let mode = changes.posixPermissions { attributes[.posixPermissions] = NSNumber(value: mode) }
                if !attributes.isEmpty { try fm.setAttributes(attributes, ofItemAtPath: url.path) }

                if !changes.addTags.isEmpty || !changes.removeTags.isEmpty {
                    var tags = FileTags.tags(of: url)
                    let removing = Set(changes.removeTags.map { $0.lowercased() })
                    tags.removeAll { removing.contains($0.name.lowercased()) }
                    let present = Set(tags.map { $0.name.lowercased() })
                    for name in changes.addTags where !present.contains(name.lowercased()) {
                        tags.append(FileTag(name: name, color: .none))
                    }
                    try FileTags.setTags(tags, on: url)
                }
                result.changed += 1
            } catch {
                result.failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return result
    }
}
