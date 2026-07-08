import Foundation

/// How a folder is displayed: sort key and direction, whether hidden files show,
/// and whether folders sort first. Codable so it can be saved per folder and
/// shared (config-as-data, DESIGN.md section 10). Later this grows columns and a
/// view mode; the sort logic lives here so it is unit-testable.
public struct ViewFormat: Codable, Sendable, Equatable {
    public enum SortKey: String, Codable, Sendable, CaseIterable {
        case name, size, date, dateCreated, dateAccessed
    }
    /// How the list view groups rows under section headers (`none` = flat, the default).
    public enum GroupKey: String, Codable, Sendable, CaseIterable {
        case none, kind, size, dateModified
    }
    /// How the listing is drawn. `list` is the dense table; `icon`/`gallery` are
    /// grid views (gallery uses larger thumbnails); `column` is miller columns.
    public enum ViewMode: String, Codable, Sendable, CaseIterable { case list, icon, gallery, column }

    public var sortKey: SortKey
    public var ascending: Bool
    public var showHidden: Bool
    public var foldersFirst: Bool
    public var viewMode: ViewMode
    public var groupKey: GroupKey

    public init(
        sortKey: SortKey = .name, ascending: Bool = true,
        showHidden: Bool = false, foldersFirst: Bool = true, viewMode: ViewMode = .list,
        groupKey: GroupKey = .none
    ) {
        self.sortKey = sortKey
        self.ascending = ascending
        self.showHidden = showHidden
        self.foldersFirst = foldersFirst
        self.viewMode = viewMode
        self.groupKey = groupKey
    }

    private enum CodingKeys: String, CodingKey {
        case sortKey, ascending, showHidden, foldersFirst, viewMode, groupKey
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
        foldersFirst = try c.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? true
        viewMode = (try? c.decode(ViewMode.self, forKey: .viewMode)) ?? .list
        groupKey = (try? c.decode(GroupKey.self, forKey: .groupKey)) ?? .none
    }

    public static let `default` = ViewFormat()

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
                let da = a.accessDate ?? .distantPast
                let db = b.accessDate ?? .distantPast
                if da == db { return nameAscending(a, b) }
                ordered = da < db
            }
            return ascending ? ordered : !ordered
        }
    }

    private func nameAscending(_ a: FileEntry, _ b: FileEntry) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
