import Foundation
import ImageIO

public enum CommunityThemeError: LocalizedError {
    case invalidListing, invalidScreenshot, invalidTransition, oversizedFile

    public var errorDescription: String? {
        switch self {
        case .invalidListing: return "The listing or attribution fields are invalid."
        case .invalidScreenshot:
            return
                "Include one to three PNG or JPEG screenshots, each at most 2 MiB and 2400 pixels per side."
        case .invalidTransition: return "The requested action is unavailable for this revision."
        case .oversizedFile: return "The gallery file exceeds the size limit."
        }
    }
}

public struct CommunityThemeRevision: Codable, Equatable, Sendable {
    public struct Reference: Codable, Equatable, Sendable {
        public let id: String
        public let version: Int
    }

    public let id: String
    public let version: Int
    public let title: String
    public let summary: String
    public let creator: String
    public let license: String
    public let source: String?
    public let tags: [String]
    public let package: Data
    public let screenshots: [Data]

    public var reference: Reference { Reference(id: id, version: version) }

    public func theme() throws -> ThemePreset {
        var preset = try ThemePackage.decode(package)
        preset.name = title
        preset.styles = preset.styles ?? .system
        return preset
    }

    public func validate() throws {
        guard (1...64).contains(id.utf8.count),
            id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
            version > 0, Self.validText(title, limit: 80), Self.validText(summary, limit: 600),
            Self.validText(creator, limit: 120), Self.validText(license, limit: 160),
            tags.count <= 8, tags.allSatisfy({ Self.validText($0, limit: 40) }),
            source.map({ Self.validText($0, limit: 300) }) ?? true
        else { throw CommunityThemeError.invalidListing }
        _ = try theme()
        guard (1...3).contains(screenshots.count), screenshots.allSatisfy(Self.validScreenshot)
        else { throw CommunityThemeError.invalidScreenshot }
    }

    fileprivate static func validText(_ text: String, limit: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= limit
            && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
            && text.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func validScreenshot(_ data: Data) -> Bool {
        guard data.count <= 2 * 1024 * 1024,
            let image = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(image) as String?,
            ["public.png", "public.jpeg"].contains(type), CGImageSourceGetCount(image) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...2400).contains(width), (1...2400).contains(height)
        else { return false }
        return CGImageSourceGetStatus(image) == .statusComplete
            && CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete
            && CGImageSourceCreateImageAtIndex(
                image, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
    }
}

/// Local review history and installed snapshots, persisted together in an atomic write.
public struct CommunityThemeGallery: Codable, Sendable {
    public struct Review: Codable, Sendable {
        public enum Outcome: String, Codable, Sendable { case approved, rejected }
        public let outcome: Outcome
        public let reviewer: String
        public let note: String
    }

    public struct Entry: Codable, Sendable {
        public let revision: CommunityThemeRevision
        public fileprivate(set) var review: Review?
    }

    public private(set) var entries: [Entry] = []
    public private(set) var installed: [String: CommunityThemeRevision] = [:]
    public private(set) var withdrawn: Set<String> = []

    public init() {}

    public func discover(_ query: String = "") -> [CommunityThemeRevision] {
        var latest: [String: CommunityThemeRevision] = [:]
        for entry in entries where entry.review?.outcome == .approved {
            let revision = entry.revision
            guard !withdrawn.contains(revision.id),
                revision.version > (latest[revision.id]?.version ?? 0)
            else { continue }
            latest[revision.id] = revision
        }
        let terms = query.split(whereSeparator: \.isWhitespace)
        return latest.values.filter { revision in
            let fields = [revision.title, revision.creator] + revision.tags
            return terms.allSatisfy { term in
                fields.contains { $0.localizedStandardContains(String(term)) }
            }
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }

    public mutating func submit(_ revision: CommunityThemeRevision) throws {
        try revision.validate()
        let history = entries.filter { $0.revision.id == revision.id }
        guard !withdrawn.contains(revision.id),
            history.allSatisfy({
                $0.revision.version < revision.version && $0.review != nil
            })
        else { throw CommunityThemeError.invalidTransition }
        entries.append(Entry(revision: revision))
    }

    public mutating func review(
        _ reference: CommunityThemeRevision.Reference, outcome: Review.Outcome,
        reviewer: String, note: String
    ) throws {
        guard CommunityThemeRevision.validText(reviewer, limit: 120),
            CommunityThemeRevision.validText(note, limit: 600)
        else { throw CommunityThemeError.invalidListing }
        guard !withdrawn.contains(reference.id),
            let index = entries.firstIndex(where: { $0.revision.reference == reference }),
            entries[index].review == nil
        else { throw CommunityThemeError.invalidTransition }
        entries[index].review = Review(outcome: outcome, reviewer: reviewer, note: note)
    }

    public mutating func withdraw(_ id: String) throws {
        guard entries.contains(where: { $0.revision.id == id }), withdrawn.insert(id).inserted
        else { throw CommunityThemeError.invalidTransition }
    }

    public mutating func install(_ reference: CommunityThemeRevision.Reference) throws {
        guard let revision = discover().first(where: { $0.reference == reference }),
            reference.version > (installed[reference.id]?.version ?? 0)
        else { throw CommunityThemeError.invalidTransition }
        installed[reference.id] = revision
    }

    public mutating func uninstall(_ id: String) throws {
        guard installed.removeValue(forKey: id) != nil
        else { throw CommunityThemeError.invalidTransition }
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw CommunityThemeError.invalidListing }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CommunityThemeError.oversizedFile }
        return data
    }

    public static func submission(at url: URL) throws -> CommunityThemeRevision {
        let revision = try JSONDecoder().decode(
            CommunityThemeRevision.self, from: read(url, limit: 9 * 1024 * 1024))
        try revision.validate()
        return revision
    }

    private static let storeLimit = 64 * 1024 * 1024

    public static func load(from url: URL) throws -> Self {
        do {
            let gallery = try JSONDecoder().decode(Self.self, from: read(url, limit: storeLimit))
            for entry in gallery.entries { try entry.revision.validate() }
            for (id, revision) in gallery.installed {
                guard id == revision.id,
                    gallery.entries.contains(where: {
                        $0.revision == revision && $0.review?.outcome == .approved
                    })
                else { throw CommunityThemeError.invalidListing }
            }
            return gallery
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
        {
            return Self()
        }
    }

    private func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.storeLimit else { throw CommunityThemeError.oversizedFile }
        try data.write(to: url, options: .atomic)
    }

    public static func update(
        at url: URL, _ change: (inout Self) throws -> Void
    ) throws -> Self {
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        var gallery = try load(from: url)
        try change(&gallery)
        try gallery.save(to: url)
        return gallery
    }
}
