import Foundation

/// Values for the optional, metadata-derived list columns (dimensions, permissions, owner,
/// download source, Finder comment). Computed off the main thread and cached by the list,
/// since each touches disk. Pure Foundation, unit-tested. The set of columns the user shows
/// is config-as-data (persisted by the table), so this just supplies the values.
public enum FileColumns {
    public struct Extended: Sendable, Equatable {
        public var dimensions: String?
        public var permissions: String?
        public var owner: String?
        public var whereFrom: String?
        public var comment: String?
        public init(
            dimensions: String? = nil, permissions: String? = nil, owner: String? = nil,
            whereFrom: String? = nil, comment: String? = nil
        ) {
            self.dimensions = dimensions
            self.permissions = permissions
            self.owner = owner
            self.whereFrom = whereFrom
            self.comment = comment
        }
    }

    /// Which extended columns to compute, so a pass only does the work that is on screen.
    public struct Request: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let dimensions = Request(rawValue: 1 << 0)
        public static let permissions = Request(rawValue: 1 << 1)
        public static let owner = Request(rawValue: 1 << 2)
        public static let whereFrom = Request(rawValue: 1 << 3)
        public static let comment = Request(rawValue: 1 << 4)
    }

    public static func gather(_ url: URL, _ request: Request) -> Extended {
        var info = Extended()
        if request.contains(.dimensions) { info.dimensions = MediaMetadata.dimensionsLabel(of: url) }
        if request.contains(.permissions) || request.contains(.owner) {
            let file = FileInfo.gather(for: url)
            if request.contains(.permissions) { info.permissions = file?.permissions }
            if request.contains(.owner) { info.owner = file?.owner }
        }
        if request.contains(.whereFrom) {
            info.whereFrom = FileMetadata.whereFroms(of: url).first.flatMap { URL(string: $0)?.host }
        }
        if request.contains(.comment) { info.comment = FileMetadata.finderComment(of: url) }
        return info
    }
}
