import Foundation

/// A named, saved Spotlight search defined by simple criteria. Config-as-data
/// (searches.json); the query builder is pure and unit-tested. Extends the Recents/
/// tag smart locations to arbitrary filename/size/date/kind filters.
public struct SavedSearch: Codable, Sendable, Equatable {
    public var name: String
    public var nameContains: String?
    public var fileExtension: String?
    public var minSizeBytes: Int64?
    public var modifiedWithinDays: Int?
    public var contentType: String?  // a UTI tree, e.g. "public.image"

    public init(
        name: String, nameContains: String? = nil, fileExtension: String? = nil,
        minSizeBytes: Int64? = nil, modifiedWithinDays: Int? = nil, contentType: String? = nil
    ) {
        self.name = name
        self.nameContains = nameContains
        self.fileExtension = fileExtension
        self.minSizeBytes = minSizeBytes
        self.modifiedWithinDays = modifiedWithinDays
        self.contentType = contentType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nameContains = try c.decodeIfPresent(String.self, forKey: .nameContains)
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension)
        minSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .minSizeBytes)
        modifiedWithinDays = try c.decodeIfPresent(Int.self, forKey: .modifiedWithinDays)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
    }

    private enum CodingKeys: String, CodingKey {
        case name, nameContains, fileExtension, minSizeBytes, modifiedWithinDays, contentType
    }

    /// The mdfind predicate for these criteria (empty if no criteria are set).
    public func mdfindQuery() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var clauses: [String] = []
        if let nameContains, !nameContains.isEmpty {
            clauses.append("kMDItemFSName == \"*\(esc(nameContains))*\"c")
        }
        if let fileExtension, !fileExtension.isEmpty {
            clauses.append("kMDItemFSName == \"*.\(esc(fileExtension))\"c")
        }
        if let minSizeBytes { clauses.append("kMDItemFSSize > \(minSizeBytes)") }
        if let modifiedWithinDays {
            clauses.append("kMDItemFSContentChangeDate >= $time.now(-\(modifiedWithinDays * 86_400))")
        }
        if let contentType, !contentType.isEmpty {
            clauses.append("kMDItemContentTypeTree == \"\(esc(contentType))\"")
        }
        return clauses.joined(separator: " && ")
    }
}

public struct SavedSearches: Codable, Sendable, Equatable {
    public var searches: [SavedSearch]

    public init(searches: [SavedSearch]) { self.searches = searches }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searches = try c.decodeIfPresent([SavedSearch].self, forKey: .searches) ?? []
    }

    private enum CodingKeys: String, CodingKey { case searches }

    /// Useful starter searches; users add their own in searches.json.
    public static let `default` = SavedSearches(searches: [
        SavedSearch(name: "Large Files (> 100 MB)", minSizeBytes: 100_000_000),
        SavedSearch(name: "Recent Images (7 days)", modifiedWithinDays: 7, contentType: "public.image"),
        SavedSearch(name: "Screenshots", nameContains: "Screenshot"),
        SavedSearch(name: "Recent Documents (7 days)", modifiedWithinDays: 7, contentType: "public.content"),
    ])
}
