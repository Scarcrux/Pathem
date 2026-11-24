import Foundation
import ImageIO

public enum CommunityThemeError: LocalizedError {
    case invalidListing, invalidScreenshot, invalidTransition, oversizedFile

    public var errorDescription: String? {
        switch self {
        case .invalidListing: return "The listing or attribution fields are invalid."
        case .invalidScreenshot:
            return
                "Use one to three PNG or JPEG screenshots, each up to 2 MiB and 2400 pixels per side. Published previews must fit within 300 KiB each."
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

    public init(
        id: String, version: Int, title: String, summary: String, creator: String,
        license: String, source: String?, tags: [String], package: Data, screenshots: [Data]
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.summary = summary
        self.creator = creator
        self.license = license
        self.source = source
        self.tags = tags
        self.package = package
        self.screenshots = screenshots
    }

    public var reference: Reference { Reference(id: id, version: version) }

    public func theme() throws -> ThemePreset {
        var preset = try ThemePackage.decode(package)
        preset.name = title
        preset.styles = preset.styles ?? .system
        return preset
    }

    public func validate() throws {
        try validate(screenshotLimit: 2 * 1024 * 1024)
    }

    static let publishedScreenshotLimit = 300 * 1024

    /// The formats a published screenshot is encoded in, in order of preference. The first one
    /// this Mac can encode and that fits the budget wins; PNG and JPEG follow as fallbacks.
    static let preferredScreenshotTypes = ["public.heic"]
    static let preferredScreenshotQuality = 0.82

    func validate(screenshotLimit: Int) throws {
        guard (1...64).contains(id.utf8.count),
            id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
            version > 0, Self.validText(title, limit: 80), Self.validText(summary, limit: 600),
            Self.validText(creator, limit: 120), Self.validText(license, limit: 160),
            tags.count <= 8, tags.allSatisfy({ Self.validText($0, limit: 40) }),
            source.map({ Self.validText($0, limit: 300) }) ?? true
        else { throw CommunityThemeError.invalidListing }
        _ = try theme()
        guard (1...3).contains(screenshots.count),
            screenshots.allSatisfy({
                $0.count <= screenshotLimit && Self.screenshotSource($0) != nil
            })
        else { throw CommunityThemeError.invalidScreenshot }
    }

    fileprivate static func validText(_ text: String, limit: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= limit
            && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
            && text.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func screenshotSource(_ data: Data) -> CGImageSource? {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard data.count <= 2 * 1024 * 1024,
            let image = CGImageSourceCreateWithData(data as CFData, noCache),
            let type = CGImageSourceGetType(image) as String?,
            (["public.png", "public.jpeg"] + preferredScreenshotTypes).contains(type),
            CGImageSourceGetCount(image) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, noCache)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...2400).contains(width), (1...2400).contains(height),
            CGImageSourceGetStatus(image) == .statusComplete,
            CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete
        else { return nil }
        return image
    }

    fileprivate func sanitizingScreenshots() throws -> Self {
        try validate()
        let clean = try screenshots.map(Self.sanitizeScreenshot)
        return Self(
            id: id, version: version, title: title, summary: summary, creator: creator,
            license: license, source: source, tags: tags, package: package, screenshots: clean)
    }

    private static func sanitizeScreenshot(_ data: Data) throws -> Data {
        guard let source = screenshotSource(data) else {
            throw CommunityThemeError.invalidScreenshot
        }
        var previousSize: (Int, Int)?
        for maximumDimension in [2400, 1800, 1200, 900] {
            // Skip sizes that cannot reduce the image tried at the previous step.
            if let (width, height) = previousSize, max(width, height) <= maximumDimension {
                continue
            }
            guard
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary)
            else { break }
            previousSize = (image.width, image.height)
            if let encoded = encodeScreenshot(image) { return encoded }
        }
        throw CommunityThemeError.invalidScreenshot
    }

    private static func encodeScreenshot(_ image: CGImage) -> Data? {
        // Add only decoded pixels. Copying the source would retain metadata or trailing bytes.
        // A Mac without a preferred encoder gets no destination and falls through to the next.
        let preferred: [(String, Double?)] = preferredScreenshotTypes.map {
            ($0, preferredScreenshotQuality)
        }
        for (type, quality) in preferred + [
            ("public.png", nil), ("public.jpeg", 0.82), ("public.jpeg", 0.55),
        ] {
            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output, type as CFString, 1, nil)
            else { continue }
            let options = quality.map {
                [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary
            }
            CGImageDestinationAddImage(destination, image, options)
            if CGImageDestinationFinalize(destination), output.length <= publishedScreenshotLimit {
                return output as Data
            }
        }
        return nil
    }

}

/// Local review history and installed snapshots, persisted together in an atomic write.
public struct CommunityThemeGallery: Codable, Sendable {
    public struct Review: Codable, Sendable {
        public enum Outcome: String, Codable, Sendable { case approved, rejected, changesRequested }
        public let outcome: Outcome
        public let reviewer: String
        public let note: String
    }

    public struct Withdrawal: Codable, Sendable {
        public let reviewer: String
        public let note: String
    }

    public struct Entry: Codable, Sendable {
        public let revision: CommunityThemeRevision
        public fileprivate(set) var review: Review?
        fileprivate var retainedOnly: Bool? = nil
    }

    public private(set) var entries: [Entry] = []
    public private(set) var installed: [String: CommunityThemeRevision] = [:]
    public private(set) var withdrawn: Set<String> = []
    public private(set) var withdrawalReviews: [String: Withdrawal]? = nil

    public init() {}

    public func discover(_ query: String = "") -> [CommunityThemeRevision] {
        var latest: [String: CommunityThemeRevision] = [:]
        for entry in entries where entry.retainedOnly != true && entry.review?.outcome == .approved
        {
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

    public mutating func withdraw(_ id: String, reviewer: String, note: String) throws {
        guard CommunityThemeRevision.validText(reviewer, limit: 120),
            CommunityThemeRevision.validText(note, limit: 600)
        else { throw CommunityThemeError.invalidListing }
        try withdraw(id)
        var reviews = withdrawalReviews ?? [:]
        reviews[id] = Withdrawal(reviewer: reviewer, note: note)
        withdrawalReviews = reviews
    }

    public mutating func withdraw(_ id: String) throws {
        guard entries.contains(where: { $0.revision.id == id }), withdrawn.insert(id).inserted
        else { throw CommunityThemeError.invalidTransition }
    }

    /// Replace remote discovery results while keeping separately installed snapshots.
    /// This store is reserved for a shared catalog and never accepts local review operations.
    public mutating func synchronize(_ catalog: SharedThemeCatalog) {
        let published = Review(outcome: .approved, reviewer: "Shared catalog", note: "Published")
        let visible = Set(catalog.themes.map(\.id))
        withdrawn = Set(installed.keys).subtracting(visible)
        let retained = installed.values.filter { !catalog.themes.contains($0) }
        entries = catalog.themes.map { Entry(revision: $0, review: published) }
        entries += retained.map { Entry(revision: $0, review: published, retainedOnly: true) }
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

    private static let submissionLimit = 9 * 1024 * 1024

    public static func encodeSubmission(_ revision: CommunityThemeRevision) throws -> Data {
        let sanitized = try revision.sanitizingScreenshots()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sanitized)
        guard data.count <= submissionLimit else { throw CommunityThemeError.oversizedFile }
        return data
    }

    public static func readSubmissionScreenshot(at url: URL) throws -> Data {
        try read(url, limit: 2 * 1024 * 1024)
    }

    public static func submission(at url: URL) throws -> CommunityThemeRevision {
        let revision = try JSONDecoder().decode(
            CommunityThemeRevision.self, from: read(url, limit: submissionLimit))
        return try revision.sanitizingScreenshots()
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
