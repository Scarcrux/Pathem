import Foundation

/// The set of folders the organizer may file items into: sensible per-user defaults
/// plus any "designated personal folders" the user adds. Persisted as JSON by the app,
/// but pure Foundation here so the planner and its tests need no app or disk-config
/// dependency. This is also the seam the behavior model (a later phase) uses to route
/// files to a destination by learned habit.
public struct FilingDestinations: Codable, Sendable, Equatable {
    public struct Destination: Codable, Sendable, Equatable {
        public var name: String
        public var url: URL
        /// SF Symbol name for the row, matching the sidebar's iconography.
        public var systemImage: String?

        public init(name: String, url: URL, systemImage: String? = nil) {
            self.name = name
            self.url = url
            self.systemImage = systemImage
        }
    }

    public var destinations: [Destination]

    public init(destinations: [Destination] = []) {
        self.destinations = destinations
    }

    /// The first destination whose name matches (case-insensitively), if any.
    public func named(_ name: String) -> Destination? {
        destinations.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Standard home folders, seeded so the organizer works before the user configures
    /// anything. A Screenshots subfolder of Pictures is included because screenshots are
    /// the most common thing people file.
    public static func defaults(home: URL) -> FilingDestinations {
        func dest(_ name: String, _ relative: String, _ image: String) -> Destination {
            Destination(name: name, url: home.appendingPathComponent(relative), systemImage: image)
        }
        return FilingDestinations(destinations: [
            dest("Documents", "Documents", "doc"),
            dest("Pictures", "Pictures", "photo"),
            dest("Screenshots", "Pictures/Screenshots", "camera.viewfinder"),
            dest("Movies", "Movies", "film"),
            dest("Music", "Music", "music.note"),
            dest("Desktop", "Desktop", "menubar.dock.rectangle"),
        ])
    }

    // Tolerant decode: a partial or older file shouldn't wipe the set (matches how
    // RemoteConnection decodes, so one bad entry doesn't lose the rest).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destinations = (try? container.decode([Destination].self, forKey: .destinations)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case destinations }
}
