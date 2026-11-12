import Foundation

/// Known places where reclaimable space collects (build output, package and model caches,
/// simulator data), each with what deleting it costs. Sizing a few dozen known folders
/// answers "what can I safely delete" in seconds, where a walk of the whole disk takes
/// minutes and macOS Storage files all of this under "Documents" or "System Data".
public enum ReclaimCatalog {
    /// What deleting a place costs the user.
    public enum Consequence: String, Sendable, Codable {
        /// Recreated by the tool the next time it runs; nothing to fetch.
        case rebuilds
        /// Fetched again from the network when next needed.
        case redownloads
        /// May hold things that exist nowhere else; look before deleting.
        case review
    }

    public struct Place: Sendable, Equatable {
        public let id: String
        public let name: String
        /// Path relative to the home folder.
        public let relativePath: String
        public let consequence: Consequence
        public init(id: String, name: String, relativePath: String, consequence: Consequence) {
            self.id = id
            self.name = name
            self.relativePath = relativePath
            self.consequence = consequence
        }
    }

    /// A catalog place that exists on this disk.
    public struct Candidate: Sendable, Equatable {
        public let place: Place
        public let url: URL
    }

    private static func place(
        _ id: String, _ name: String, _ path: String, _ consequence: Consequence
    ) -> Place { Place(id: id, name: name, relativePath: path, consequence: consequence) }

    public static let places: [Place] = [
        // Build output: recreated by the next build.
        place(
            "xcode-deriveddata", "Xcode DerivedData", "Library/Developer/Xcode/DerivedData",
            .rebuilds),
        place(
            "xcode-previews", "Xcode Previews", "Library/Developer/Xcode/UserData/Previews",
            .rebuilds),
        place(
            "xcode-devicesupport", "iOS DeviceSupport", "Library/Developer/Xcode/iOS DeviceSupport",
            .rebuilds),
        place(
            "simulator-caches", "Simulator caches", "Library/Developer/CoreSimulator/Caches",
            .rebuilds),
        place("rust-targets", "Rust build output", "Library/Caches/cargo-targets", .rebuilds),
        place("go-build", "Go build cache", "Library/Caches/go-build", .rebuilds),
        place("jetbrains-caches", "JetBrains caches", "Library/Caches/JetBrains", .rebuilds),
        place("chrome-cache", "Chrome cache", "Library/Caches/Google", .rebuilds),
        place("vscode-cache", "VS Code cache", "Library/Application Support/Code/Cache", .rebuilds),
        place(
            "vscode-cacheddata", "VS Code cached data",
            "Library/Application Support/Code/CachedData", .rebuilds),
        // Download caches: fetched again when needed.
        place(
            "swiftpm-cache", "Swift packages cache", "Library/Caches/org.swift.swiftpm",
            .redownloads),
        place("npm-cache", "npm cache", ".npm/_cacache", .redownloads),
        place("yarn-cache", "Yarn cache", "Library/Caches/Yarn", .redownloads),
        place("pnpm-store", "pnpm store", "Library/pnpm/store", .redownloads),
        place("bun-cache", "Bun cache", ".bun/install/cache", .redownloads),
        place("pip-cache", "pip cache", "Library/Caches/pip", .redownloads),
        place("homebrew-cache", "Homebrew downloads", "Library/Caches/Homebrew", .redownloads),
        place("cocoapods-cache", "CocoaPods cache", "Library/Caches/CocoaPods", .redownloads),
        place(
            "carthage-cache", "Carthage cache", "Library/Caches/org.carthage.CarthageKit",
            .redownloads),
        place("gradle-caches", "Gradle caches", ".gradle/caches", .redownloads),
        place("maven-repo", "Maven repository", ".m2/repository", .redownloads),
        place("cargo-registry", "Rust crate downloads", ".cargo/registry", .redownloads),
        place(
            "playwright-browsers", "Playwright browsers", "Library/Caches/ms-playwright",
            .redownloads),
        place("huggingface", "Hugging Face models", ".cache/huggingface", .redownloads),
        place("ollama-models", "Ollama models", ".ollama/models", .redownloads),
        // Things that may exist nowhere else.
        place("xcode-archives", "Xcode Archives", "Library/Developer/Xcode/Archives", .review),
        place(
            "simulator-devices", "iOS Simulator devices", "Library/Developer/CoreSimulator/Devices",
            .review),
        place("docker-data", "Docker data", "Library/Containers/com.docker.docker/Data", .review),
        place(
            "ios-backups", "iPhone and iPad backups",
            "Library/Application Support/MobileSync/Backup", .review),
        place("downloads", "Downloads", "Downloads", .review),
    ]

    /// Cache roots whose uncatalogued children are offered for review (a tool this catalog
    /// doesn't know about still shows up, with its real folder name).
    static let cacheRoots = ["Library/Caches", ".cache"]

    /// Catalog places that exist under `home`, plus each uncatalogued child of the cache roots
    /// as a review item. Nothing is sized here; existence only, so this is instant.
    public static func candidates(home: URL) -> [Candidate] {
        let fm = FileManager.default
        var found: [Candidate] = []
        var isDirectory: ObjCBool = false
        for place in places {
            let url = home.appendingPathComponent(place.relativePath)
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                found.append(Candidate(place: place, url: url))
            }
        }
        let known = Set(places.map(\.relativePath))
        for root in cacheRoots {
            let rootURL = home.appendingPathComponent(root)
            let children =
                (try? fm.contentsOfDirectory(
                    at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? []
            for child in children {
                let relative = root + "/" + child.lastPathComponent
                guard !known.contains(relative),
                    (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                found.append(
                    Candidate(
                        place: Place(
                            id: "other:" + relative, name: child.lastPathComponent,
                            relativePath: relative, consequence: .review),
                        url: child))
            }
        }
        return found
    }

    /// Whether `path` is one of the candidate places, inside one, or contains one. The deep
    /// scan drops such items so nothing is listed twice.
    public static func overlaps(_ path: String, with candidates: [Candidate]) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidates.contains { candidate in
            let place = candidate.url.standardizedFileURL.path
            return target == place || target.hasPrefix(place + "/") || place.hasPrefix(target + "/")
        }
    }

    public enum DeleteError: Error, Equatable { case notAllowed(String) }

    /// Permanently delete a place's contents, skipping the Trash. Allowed only for a catalog
    /// place in the `rebuilds` tier that resolves inside `home`: everything else must go
    /// through the Trash, where it can be put back. The folder itself is kept, so a running
    /// tool finds its cache directory where it expects it.
    public static func deleteNow(_ candidate: Candidate, home: URL) throws {
        guard candidate.place.consequence == .rebuilds,
            let listed = places.first(where: { $0.id == candidate.place.id }),
            listed == candidate.place
        else { throw DeleteError.notAllowed(candidate.place.id) }
        let fm = FileManager.default
        let root = home.resolvingSymlinksInPath().path
        let expected = home.appendingPathComponent(listed.relativePath)
        let resolved = candidate.url.resolvingSymlinksInPath().path
        guard candidate.url.standardizedFileURL.path == expected.standardizedFileURL.path,
            resolved.hasPrefix(root + "/")
        else { throw DeleteError.notAllowed(candidate.url.path) }
        for child in try fm.contentsOfDirectory(at: candidate.url, includingPropertiesForKeys: nil)
        {
            try fm.removeItem(at: child)
        }
    }
}
