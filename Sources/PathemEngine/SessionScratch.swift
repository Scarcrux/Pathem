import Foundation

/// An owned namespace, not a license to sweep shared or previous sessions. Opened remote
/// files can still be edited in another application after a Pathem window closes.
public struct SessionScratch: Sendable {
    public let root: URL
    public var remote: URL { root.appendingPathComponent("Remote", isDirectory: true) }
    public var archives: URL { root.appendingPathComponent("Archives", isDirectory: true) }

    public init(base: URL, session: UUID = UUID()) {
        root = base.appendingPathComponent("Pathem-Sessions", isDirectory: true)
            .appendingPathComponent(session.uuidString, isDirectory: true)
    }

    public func prepare() throws {
        for directory in [remote, archives] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }
}
