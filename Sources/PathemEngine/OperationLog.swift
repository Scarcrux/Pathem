import Foundation

/// One line of the local activity log: what a file operation did, by paths only (never contents).
public struct OperationRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case ok, failed, partial, canceled
    }

    public var id: UUID
    public var time: Date
    /// Stable key such as "copy", "move", "trash", "rename", "batchRename", "archive",
    /// "secureDelete", "create", "undo".
    public var operation: String
    public var sources: [String]
    public var destination: String?
    public var itemCount: Int
    public var bytes: Int64?
    public var outcome: Outcome
    public var error: String?
    /// Identifier of the in-memory undo entry, valid only while that entry still exists.
    public var undoToken: String?
    /// True when the operation ran with elevated rights (reserved for admin mode).
    public var admin: Bool

    public init(
        id: UUID = UUID(), time: Date = Date(), operation: String, sources: [String] = [],
        destination: String? = nil, itemCount: Int? = nil, bytes: Int64? = nil,
        outcome: Outcome = .ok, error: String? = nil, undoToken: String? = nil, admin: Bool = false
    ) {
        self.id = id
        self.time = time
        self.operation = operation
        self.sources = sources
        self.destination = destination
        self.itemCount = itemCount ?? sources.count
        self.bytes = bytes
        self.outcome = outcome
        self.error = error
        self.undoToken = undoToken
        self.admin = admin
    }

    private enum CodingKeys: String, CodingKey {
        case id, time, operation, sources, destination, itemCount, bytes, outcome, error,
            undoToken, admin
    }

    // Every key but the operation is optional on decode, so older or newer log lines still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        time = (try? c.decode(Date.self, forKey: .time)) ?? Date(timeIntervalSince1970: 0)
        operation = try c.decode(String.self, forKey: .operation)
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        destination = try c.decodeIfPresent(String.self, forKey: .destination)
        itemCount = try c.decodeIfPresent(Int.self, forKey: .itemCount) ?? sources.count
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes)
        outcome = (try? c.decode(Outcome.self, forKey: .outcome)) ?? .ok
        error = try c.decodeIfPresent(String.self, forKey: .error)
        undoToken = try c.decodeIfPresent(String.self, forKey: .undoToken)
        admin = try c.decodeIfPresent(Bool.self, forKey: .admin) ?? false
    }

    /// Case-insensitive match of every whitespace-separated term against the operation, paths
    /// and error text. An empty query matches everything.
    public func matches(_ query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let hay = ([operation, error ?? "", destination ?? "", outcome.rawValue] + sources)
            .joined(separator: "\n").lowercased()
        return terms.allSatisfy { hay.contains($0) }
    }
}

/// An append-only JSONL activity log in a directory, rotated when it passes `maxEntries` lines
/// or `maxBytes`. Rotation moves the current file to `operation-log.1.jsonl` (replacing any
/// older backup) and starts fresh, so the log is bounded to roughly twice the limits.
public final class OperationLog: @unchecked Sendable {
    public static let fileName = "operation-log.jsonl"
    public static let rotatedFileName = "operation-log.1.jsonl"

    public let directory: URL
    public let maxEntries: Int
    public let maxBytes: Int
    private let lock = NSLock()
    private var entryCount: Int?

    public init(directory: URL, maxEntries: Int = 10_000, maxBytes: Int = 5_000_000) {
        self.directory = directory
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1, maxBytes)
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    public var rotatedURL: URL { directory.appendingPathComponent(Self.rotatedFileName) }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    /// One JSON object on one line (newlines inside strings are escaped by JSON).
    public static func encodeLine(_ record: OperationRecord) throws -> Data {
        var data = try encoder().encode(record)
        data.append(0x0A)
        return data
    }

    /// Decode a JSONL blob; torn or foreign lines are skipped, never fatal.
    public static func decodeLines(_ data: Data) -> [OperationRecord] {
        let d = decoder()
        return data.split(separator: 0x0A).compactMap {
            try? d.decode(OperationRecord.self, from: Data($0))
        }
    }

    @discardableResult
    public func append(_ record: OperationRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let line = try? Self.encodeLine(record), line.count <= maxBytes else { return false }
        let fm = FileManager.default
        // ConfigStore owns the directory. A queued write must not recreate it after
        // Reset Pathem Data has removed it.
        if entryCount == nil { entryCount = Self.countLines(fileURL) }
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if (entryCount ?? 0) >= maxEntries || size + line.count > maxBytes, size > 0 {
            do {
                if fm.fileExists(atPath: rotatedURL.path) {
                    _ = try fm.replaceItemAt(rotatedURL, withItemAt: fileURL)
                } else {
                    try fm.moveItem(at: fileURL, to: rotatedURL)
                }
                entryCount = 0
            } catch {
                return false
            }
        }
        if !fm.fileExists(atPath: fileURL.path) {
            guard
                fm.createFile(
                    atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { return false }
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch { return false }
        entryCount = (entryCount ?? 0) + 1
        return true
    }

    /// Newest first. Reads the current file, then the rotated one, up to `limit` entries.
    public func entries(limit: Int = 10_000) -> [OperationRecord] {
        guard limit > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var all: [OperationRecord] = []
        for url in [fileURL, rotatedURL] {
            if let data = try? Data(contentsOf: url) {
                all.append(contentsOf: Self.decodeLines(data).reversed())
            }
            if all.count >= limit { break }
        }
        return Array(all.prefix(limit))
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: rotatedURL)
        entryCount = nil
    }

    private static func countLines(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }
}
