import Foundation

/// A reusable "create" template: a named set of relative entries to materialize in a
/// folder. A trailing "/" marks a folder, otherwise a file; nested paths ("src/main.swift")
/// create intermediate folders. Persisted as templates.json and bindable to a shortcut
/// (each template becomes a command). Pure (real I/O only in `instantiate`), so tested.
public struct CreateTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var entries: [String]

    public init(id: String, name: String, entries: [String]) {
        self.id = id
        self.name = name
        self.entries = entries
    }

    static func isSafe(_ relativePath: String) -> Bool {
        !relativePath.isEmpty && !relativePath.hasPrefix("/")
            && !relativePath.split(separator: "/").contains("..") && !relativePath.contains(":")
    }

    /// Create the template's entries under `directory`. Existing paths are left alone.
    /// Returns the top-level names that were newly created (so a caller can select and
    /// undo them without disturbing anything that already existed) plus any failures.
    public func instantiate(in directory: URL) -> (created: [String], failures: [FileOperations.Failure])
    {
        let fm = FileManager.default
        let preexisting = Set((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
        var touchedTopLevel = Set<String>()
        var failures: [FileOperations.Failure] = []
        for raw in entries {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            let isFolder = entry.hasSuffix("/")
            let relative = isFolder ? String(entry.dropLast()) : entry
            guard Self.isSafe(relative) else {
                failures.append(.init(name: entry, reason: "invalid path"))
                continue
            }
            let url = directory.appendingPathComponent(relative)
            let top = relative.split(separator: "/").first.map(String.init) ?? relative
            do {
                if isFolder {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fm.fileExists(atPath: url.path) {
                        guard fm.createFile(atPath: url.path, contents: nil) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    }
                }
                touchedTopLevel.insert(top)
            } catch {
                failures.append(.init(name: entry, reason: error.localizedDescription))
            }
        }
        // Only report top-level names we actually introduced, so undo never trashes
        // a folder that already held the user's files.
        let created = touchedTopLevel.subtracting(preexisting).sorted()
        return (created, failures)
    }
}
