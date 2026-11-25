import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Snapshot of only the extra metadata needed by a Finder-style sort/group.
/// Gathering performs metadata reads, never file-content reads; comparisons use
/// these plain values and cannot hydrate cloud placeholders or query Launch Services.
public struct FileViewMetadata: Sendable, Hashable {
    public let kind: String?
    public let dateAdded: Date?
    public let lastOpenedDate: Date?
    public let tagNames: [String]
    public let applicationName: String?
    /// Media column values (dimensions, duration, ...), present only when a media sort asked.
    public let media: MediaColumns.Attributes?

    public init(
        kind: String? = nil, dateAdded: Date? = nil, lastOpenedDate: Date? = nil,
        tagNames: [String] = [], applicationName: String? = nil,
        media: MediaColumns.Attributes? = nil
    ) {
        self.media = media
        self.kind = kind
        self.dateAdded = dateAdded
        self.lastOpenedDate = lastOpenedDate
        // Named tags (not only Finder's seven colors) participate, independent
        // of the order in which a user applied them.
        self.tagNames = Array(Set(tagNames.filter { !$0.isEmpty })).sorted {
            let comparison = $0.localizedStandardCompare($1)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
        self.applicationName = applicationName
    }

    public struct Requirements: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let kind = Requirements(rawValue: 1 << 0)
        public static let dateAdded = Requirements(rawValue: 1 << 1)
        public static let lastOpened = Requirements(rawValue: 1 << 2)
        public static let tags = Requirements(rawValue: 1 << 3)
        public static let application = Requirements(rawValue: 1 << 4)
        /// Media columns (see `MediaColumns`); which fields is passed to `enrich`.
        public static let media = Requirements(rawValue: 1 << 5)
    }

    /// Call off the main thread before sorting/grouping a new listing. A nil
    /// directory permits explicit local entry locations for smart results; a
    /// remote caller must set allowEntryLocations=false to forbid local reads.
    /// The empty-requirements path returns unchanged entries without resolving
    /// URLs, types, Spotlight metadata, or default applications.
    public static func enrich(
        _ entries: [FileEntry], directory: URL?, requirements: Requirements,
        allowEntryLocations: Bool = true,
        mediaFields: MediaColumns.Fields = [],
        mediaSource: MediaColumns.Source = .spotlightThenFallback,
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        applicationName: (@Sendable (URL) -> String?)? = nil
    ) -> [FileEntry] {
        guard !requirements.isEmpty else { return entries }
        var fallbackKinds: [String: String] = [:]
        var keys: Set<URLResourceKey> = []
        if requirements.contains(.kind) { keys.insert(.localizedTypeDescriptionKey) }
        if requirements.contains(.dateAdded) { keys.insert(.addedToDirectoryDateKey) }
        if requirements.contains(.tags) { keys.insert(.tagNamesKey) }

        return entries.enumerated().map { index, entry in
            guard !Task.isCancelled else { return entry }
            defer {
                let completed = index + 1
                if completed == 1 || completed.isMultiple(of: 32) || completed == entries.count {
                    progress?(completed, entries.count)
                }
            }
            // Smart/cross-folder entries carry their actual parent. Never use
            // the pane's directory for a same-named file in another folder.
            let parent =
                (allowEntryLocations ? entry.location.map { URL(fileURLWithPath: $0) } : nil)
                ?? directory
            let url = parent?.isFileURL == true ? parent?.appendingPathComponent(entry.name) : nil
            let values = keys.isEmpty ? nil : url.flatMap { try? $0.resourceValues(forKeys: keys) }
            let previous = entry.viewMetadata
            var kind = previous?.kind
            if requirements.contains(.kind) {
                if let localized = values?.localizedTypeDescription, !localized.isEmpty {
                    kind = localized
                } else if url == nil, let known = previous?.kind {
                    kind = known
                } else if entry.isDirectory {
                    kind = "Folder"
                } else {
                    let ext = (entry.name as NSString).pathExtension.lowercased()
                    if let cached = fallbackKinds[ext] {
                        kind = cached
                    } else {
                        let description =
                            UTType(filenameExtension: ext)?.localizedDescription ?? "Document"
                        fallbackKinds[ext] = description
                        kind = description
                    }
                }
            }
            var opened = previous?.lastOpenedDate
            if requirements.contains(.lastOpened), let url {
                if let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) {
                    opened = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
                } else {
                    opened = nil
                }
            }
            let app: String?
            if requirements.contains(.application) {
                app =
                    entry.isDirectory
                    ? nil : (url.map { applicationName?($0) } ?? previous?.applicationName)
            } else {
                app = previous?.applicationName
            }
            var media = previous?.media
            if requirements.contains(.media), !mediaFields.isEmpty, !entry.isDirectory, let url,
                !Task.isCancelled
            {
                media = MediaColumns.Cache.shared.values(
                    for: url, fields: mediaFields, source: mediaSource)
            }
            var result = entry
            result.viewMetadata = FileViewMetadata(
                kind: kind,
                dateAdded: requirements.contains(.dateAdded) && url != nil
                    ? values?.addedToDirectoryDate : previous?.dateAdded,
                lastOpenedDate: opened,
                tagNames: requirements.contains(.tags) && url != nil
                    ? (values?.tagNames ?? []) : (previous?.tagNames ?? []),
                applicationName: app, media: media)
            return result
        }
    }
}
