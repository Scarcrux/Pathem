import Foundation

/// How a folder is displayed: sort key and direction, whether hidden files show,
/// and whether folders sort first. Codable so it can be saved per folder and
/// shared (config-as-data, DESIGN.md section 10). Later this grows columns and a
/// view mode; the sort logic lives here so it is unit-testable.
public struct ViewFormat: Codable, Sendable, Equatable {
    public enum SortKey: String, Codable, Sendable, CaseIterable {
        case name, kind, dateAccessed, dateAdded, date, dateCreated, size, tags
    }
    /// How the list view groups rows under section headers (`none` = flat, the default).
    public enum GroupKey: String, Codable, Sendable, CaseIterable {
        case none, name, kind, application, dateAccessed, dateAdded, dateModified, dateCreated,
            size, tag
    }
    /// How the listing is drawn. `list` is the dense table; `icon`/`gallery` are
    /// grid views (gallery uses larger thumbnails); `column` is miller columns.
    public enum ViewMode: String, Codable, Sendable, CaseIterable {
        case list, icon, gallery, column, tree
    }

    public var sortKey: SortKey
    public var ascending: Bool
    public var showHidden: Bool
    /// An explicit per-folder decision to show (true) or hide (false) dotfiles, set by the eye
    /// toggle; nil means follow `showHidden` / the app-wide default. Needed because `showHidden`
    /// can only ADD to a global "show by default": with that on, a plain Bool could never hide.
    public var hiddenOverride: Bool?
    public var foldersFirst: Bool
    public var viewMode: ViewMode
    public var groupKey: GroupKey
    public var options: FolderViewOptions

    public init(
        sortKey: SortKey = .name, ascending: Bool = true,
        showHidden: Bool = false, hiddenOverride: Bool? = nil, foldersFirst: Bool = true,
        viewMode: ViewMode = .list, groupKey: GroupKey = .none,
        options: FolderViewOptions = FolderViewOptions()
    ) {
        self.sortKey = sortKey
        self.ascending = ascending
        self.showHidden = showHidden
        self.hiddenOverride = hiddenOverride
        self.foldersFirst = foldersFirst
        self.viewMode = viewMode
        self.groupKey = groupKey
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case sortKey, ascending, showHidden, hiddenOverride, foldersFirst, viewMode, groupKey,
            options
    }

    // Decode each key if present so older formats.json (without viewMode, etc.)
    // still loads instead of resetting every saved format.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` (not decodeIfPresent) for enums: an unknown raw value (a newer
        // schema or a typo) falls back to the default instead of failing the file.
        sortKey = (try? c.decode(SortKey.self, forKey: .sortKey)) ?? .name
        ascending = try c.decodeIfPresent(Bool.self, forKey: .ascending) ?? true
        showHidden = try c.decodeIfPresent(Bool.self, forKey: .showHidden) ?? false
        hiddenOverride = try c.decodeIfPresent(Bool.self, forKey: .hiddenOverride)
        foldersFirst = try c.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? true
        viewMode = (try? c.decode(ViewMode.self, forKey: .viewMode)) ?? .list
        groupKey = (try? c.decode(GroupKey.self, forKey: .groupKey)) ?? .none
        options =
            (try? c.decode(FolderViewOptions.self, forKey: .options))?.normalized
            ?? FolderViewOptions()
    }

    public static let `default` = ViewFormat()

    /// Only request metadata needed by the chosen sort/group. Name, size and
    /// enumerated dates require no additional filesystem or Spotlight work.
    public var metadataRequirements: FileViewMetadata.Requirements {
        var result: FileViewMetadata.Requirements = []
        switch sortKey {
        case .kind: result.insert(.kind)
        case .dateAccessed: result.insert(.lastOpened)
        case .dateAdded: result.insert(.dateAdded)
        case .tags: result.insert(.tags)
        case .name, .date, .dateCreated, .size: break
        }
        switch groupKey {
        case .kind: result.insert(.kind)
        case .application: result.insert(.application)
        case .dateAccessed: result.insert(.lastOpened)
        case .dateAdded: result.insert(.dateAdded)
        case .tag: result.insert(.tags)
        case .none, .name, .dateModified, .dateCreated, .size: break
        }
        return result
    }

    /// Sort entries per this format. Folders-first (when set) is independent of
    /// the sort direction; ties fall back to a stable localized name compare.
    public func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if foldersFirst, a.isDirectory != b.isDirectory { return a.isDirectory }

            let ordered: Bool
            switch sortKey {
            case .name:
                let cmp = a.name.localizedStandardCompare(b.name)
                if cmp == .orderedSame { return false }
                ordered = cmp == .orderedAscending
            case .size:
                if a.size == b.size { return nameAscending(a, b) }
                ordered = a.size < b.size
            case .date:
                let da = a.modificationDate ?? .distantPast
                let db = b.modificationDate ?? .distantPast
                if da == db { return nameAscending(a, b) }
                ordered = da < db
            case .dateCreated:
                let da = a.creationDate ?? .distantPast
                let db = b.creationDate ?? .distantPast
                if da == db { return nameAscending(a, b) }
                ordered = da < db
            case .dateAccessed:
                // Legacy callers may supply accessDate without enrichment. Once
                // gathered, an absent Spotlight last-open date stays unknown;
                // filesystem access (e.g. indexing) is not a user opening it.
                let da = lastOpened(a) ?? .distantPast
                let db = lastOpened(b) ?? .distantPast
                if da == db { return nameAscending(a, b) }
                ordered = da < db
            case .dateAdded:
                let da = a.viewMetadata?.dateAdded ?? .distantPast
                let db = b.viewMetadata?.dateAdded ?? .distantPast
                if da == db { return nameAscending(a, b) }
                ordered = da < db
            case .kind:
                let comparison = (a.viewMetadata?.kind ?? "").localizedStandardCompare(
                    b.viewMetadata?.kind ?? "")
                if comparison == .orderedSame { return nameAscending(a, b) }
                ordered = comparison == .orderedAscending
            case .tags:
                let comparison = compareTags(
                    a.viewMetadata?.tagNames ?? [], b.viewMetadata?.tagNames ?? [])
                if comparison == .orderedSame { return nameAscending(a, b) }
                ordered = comparison == .orderedAscending
            }
            return ascending ? ordered : !ordered
        }
    }

    private func nameAscending(_ a: FileEntry, _ b: FileEntry) -> Bool {
        let comparison = a.name.localizedStandardCompare(b.name)
        return comparison == .orderedSame ? a.name < b.name : comparison == .orderedAscending
    }

    private func lastOpened(_ entry: FileEntry) -> Date? {
        if let metadata = entry.viewMetadata { return metadata.lastOpenedDate }
        return entry.accessDate
    }

    private func compareTags(_ a: [String], _ b: [String]) -> ComparisonResult {
        for (left, right) in zip(a, b) {
            let comparison = left.localizedStandardCompare(right)
            if comparison != .orderedSame { return comparison }
        }
        if a.count == b.count { return .orderedSame }
        return a.count < b.count ? .orderedAscending : .orderedDescending
    }
}
