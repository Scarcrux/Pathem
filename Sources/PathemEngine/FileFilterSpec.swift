import Foundation

/// A reusable description of "which files": include and exclude globs, kinds, size and date
/// ranges, and how to walk and place the matches. It drives Copy Matching, Move Matching and
/// Trash Matching. Pure, Codable (so the last-used filter and named presets persist as data)
/// and AppKit-free; the walk lives in `FileFilterEnumerator`.
public struct FileFilterSpec: Codable, Equatable, Sendable {
    /// Globs a name (or, when the glob has a `/`, a relative path) must match; empty = anything.
    public var includePatterns: [String]
    /// Globs that rule an item out. An excluded folder is not entered.
    public var excludePatterns: [String]
    /// Kinds to keep (any of); empty = every kind. `.folder` makes folders match as items.
    public var kinds: Set<FileFilter.Kind>
    public var minBytes: Int64?
    public var maxBytes: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    /// Walk into selected folders (otherwise a selected folder is tested as a single item).
    public var recurse: Bool
    /// Rebuild the matches' folders at the destination (copy and move; only for matched files).
    public var keepStructure: Bool
    public var includeHidden: Bool

    public init(
        includePatterns: [String] = [], excludePatterns: [String] = [],
        kinds: Set<FileFilter.Kind> = [], minBytes: Int64? = nil, maxBytes: Int64? = nil,
        modifiedAfter: Date? = nil, modifiedBefore: Date? = nil,
        recurse: Bool = true, keepStructure: Bool = true, includeHidden: Bool = false
    ) {
        self.includePatterns = includePatterns
        self.excludePatterns = excludePatterns
        self.kinds = kinds
        self.minBytes = minBytes
        self.maxBytes = maxBytes
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.recurse = recurse
        self.keepStructure = keepStructure
        self.includeHidden = includeHidden
    }

    // Older saved filters decode with defaults for anything added later.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FileFilterSpec()
        includePatterns =
            try c.decodeIfPresent([String].self, forKey: .includePatterns) ?? d.includePatterns
        excludePatterns =
            try c.decodeIfPresent([String].self, forKey: .excludePatterns) ?? d.excludePatterns
        kinds = try c.decodeIfPresent(Set<FileFilter.Kind>.self, forKey: .kinds) ?? d.kinds
        minBytes = try c.decodeIfPresent(Int64.self, forKey: .minBytes)
        maxBytes = try c.decodeIfPresent(Int64.self, forKey: .maxBytes)
        modifiedAfter = try c.decodeIfPresent(Date.self, forKey: .modifiedAfter)
        modifiedBefore = try c.decodeIfPresent(Date.self, forKey: .modifiedBefore)
        recurse = try c.decodeIfPresent(Bool.self, forKey: .recurse) ?? d.recurse
        keepStructure = try c.decodeIfPresent(Bool.self, forKey: .keepStructure) ?? d.keepStructure
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? d.includeHidden
    }

    /// True when nothing narrows the selection (every file would match).
    public var matchesEverything: Bool {
        includePatterns.isEmpty && excludePatterns.isEmpty && kinds.isEmpty && minBytes == nil
            && maxBytes == nil && modifiedAfter == nil && modifiedBefore == nil
    }

    // MARK: Patterns

    /// Split a typed pattern list on semicolons and newlines, trimming blanks.
    public static func splitPatterns(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Case-insensitive shell glob (`*`, `?`, `[a-c]`). A glob with a `/` is matched against the
    /// relative path, any other against the name alone.
    public static func glob(_ pattern: String, matches name: String, path: String) -> Bool {
        let subject = pattern.contains("/") ? path : name
        return fnmatch(pattern, subject, FNM_CASEFOLD) == 0
    }

    // MARK: Matching

    /// Whether an item passes every rule. `size` and the dates apply to files; a folder is
    /// judged on its name, kind and (when the spec has date bounds) modification date.
    public func matches(
        name: String, relativePath: String, isDirectory: Bool, size: Int64, modified: Date?
    ) -> Bool {
        if isExcluded(name: name, relativePath: relativePath) { return false }
        if !includePatterns.isEmpty,
            !includePatterns.contains(where: {
                Self.glob($0, matches: name, path: relativePath)
            })
        {
            return false
        }
        if !kinds.isEmpty,
            !kinds.contains(where: { Self.kind($0, name: name, isDirectory: isDirectory) })
        {
            return false
        }
        if !isDirectory {
            if let minBytes, size < minBytes { return false }
            if let maxBytes, size > maxBytes { return false }
        }
        if modifiedAfter != nil || modifiedBefore != nil {
            guard let modified else { return false }
            if let modifiedAfter, modified < modifiedAfter { return false }
            if let modifiedBefore, modified > modifiedBefore { return false }
        }
        return true
    }

    public func isExcluded(name: String, relativePath: String) -> Bool {
        excludePatterns.contains { Self.glob($0, matches: name, path: relativePath) }
    }

    static func kind(_ kind: FileFilter.Kind, name: String, isDirectory: Bool) -> Bool {
        switch kind {
        case .folder: return isDirectory
        case .file: return !isDirectory
        default:
            return !isDirectory
                && kind.extensions.contains((name as NSString).pathExtension.lowercased())
        }
    }
}

/// Walks selected items and lists what a `FileFilterSpec` matches. Bounded (a visit cap and a
/// match cap, each reported as `truncated`) and cancellable, so a live preview can run it on a
/// huge tree and abandon it when the user keeps typing.
public enum FileFilterEnumerator {
    public struct Match: Equatable, Sendable {
        public let url: URL
        /// Path from the selected item's parent: `Photos/2024/a.jpg` for a file found under a
        /// selected `Photos` folder, or just the name for a selected file.
        public let relativePath: String
        public let size: Int64
        public let isDirectory: Bool
    }

    public struct Result: Sendable {
        public var matches: [Match] = []
        /// Bytes in matched files (matched folders add nothing; see `folderCount`).
        public var totalBytes: Int64 = 0
        public var folderCount = 0
        public var visited = 0
        /// Stopped at `maxVisited` or `maxMatches`; the list is a prefix of the full answer.
        public var truncated = false
        public var cancelled = false
        public var fileCount: Int { matches.count - folderCount }
    }

    public static func run(
        _ spec: FileFilterSpec, sources: [URL], maxVisited: Int = 500_000,
        maxMatches: Int = 200_000, isCancelled: () -> Bool = { false }
    ) -> Result {
        var result = Result()
        let fm = FileManager.default
        var seen = Set<String>()
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey,
            .isSymbolicLinkKey,
        ]

        func consider(_ url: URL, relativePath: String, isDirectory: Bool) -> Bool {
            // Returns false to stop the whole walk.
            result.visited += 1
            if result.visited > maxVisited {
                result.truncated = true
                return false
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            guard
                spec.matches(
                    name: url.lastPathComponent, relativePath: relativePath,
                    isDirectory: isDirectory, size: size, modified: values?.contentModificationDate)
            else { return true }
            if result.matches.count >= maxMatches {
                result.truncated = true
                return false
            }
            result.matches.append(
                Match(url: url, relativePath: relativePath, size: size, isDirectory: isDirectory))
            if isDirectory { result.folderCount += 1 } else { result.totalBytes += size }
            return true
        }

        for source in sources {
            if isCancelled() {
                result.cancelled = true
                return result
            }
            guard seen.insert(source.standardizedFileURL.path).inserted else { continue }
            let values = try? source.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
            let top = source.lastPathComponent
            guard isDirectory, spec.recurse else {
                if !consider(source, relativePath: top, isDirectory: isDirectory) { return result }
                continue
            }
            // A selected folder: walk it. Hidden entries are skipped unless asked for.
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !spec.includeHidden { options.insert(.skipsHiddenFiles) }
            guard
                let walker = fm.enumerator(
                    at: source, includingPropertiesForKeys: keys, options: options)
            else { continue }
            let rootPath = source.standardizedFileURL.path
            for case let url as URL in walker {
                if isCancelled() {
                    result.cancelled = true
                    return result
                }
                let rel = Self.relative(url, rootPath: rootPath, top: top)
                let v = try? url.resourceValues(forKeys: Set(keys))
                let isDir = v?.isDirectory == true && v?.isSymbolicLink != true
                if isDir {
                    // An excluded folder is not entered; a folder only matches as an item
                    // when the spec asks for folders (then it is taken whole).
                    if spec.isExcluded(name: url.lastPathComponent, relativePath: rel) {
                        walker.skipDescendants()
                        continue
                    }
                    if spec.kinds.contains(.folder) {
                        let before = result.matches.count
                        if !consider(url, relativePath: rel, isDirectory: true) { return result }
                        if result.matches.count > before { walker.skipDescendants() }
                    } else {
                        result.visited += 1
                        if result.visited > maxVisited {
                            result.truncated = true
                            return result
                        }
                    }
                    continue
                }
                if !consider(url, relativePath: rel, isDirectory: false) { return result }
            }
        }
        return result
    }

    static func relative(_ url: URL, rootPath: String, top: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return top + "/" + url.lastPathComponent }
        return top + "/" + path.dropFirst(rootPath.count + 1)
    }
}

/// Where each match goes. Groups are ordered; each is one `FileOperations.copy/move(urls:into:)`
/// call into one folder, so only matched files cause folders to be created.
public enum FileFilterPlan {
    public struct Group: Equatable, Sendable {
        public let directory: URL
        public let urls: [URL]
        /// Later layers of same-named files in a flat copy: run with Keep Both so a name clash
        /// inside the batch renames the newcomer instead of skipping or replacing its sibling.
        public let keepBoth: Bool
    }

    public static func groups(
        for matches: [FileFilterEnumerator.Match], into destination: URL, keepStructure: Bool
    ) -> [Group] {
        if keepStructure {
            var order: [String] = []
            var byDirectory: [String: [URL]] = [:]
            for match in matches {
                let parent = (match.relativePath as NSString).deletingLastPathComponent
                if byDirectory[parent] == nil { order.append(parent) }
                byDirectory[parent, default: []].append(match.url)
            }
            return order.map { parent in
                Group(
                    directory: parent.isEmpty
                        ? destination
                        : destination.appendingPathComponent(parent, isDirectory: true),
                    urls: byDirectory[parent] ?? [], keepBoth: false)
            }
        }
        // Flat: the n-th file called "a.txt" goes to layer n.
        var layers: [[URL]] = []
        var counts: [String: Int] = [:]
        for match in matches {
            let key = match.url.lastPathComponent.lowercased()
            let layer = counts[key, default: 0]
            counts[key] = layer + 1
            if layers.count <= layer { layers.append([]) }
            layers[layer].append(match.url)
        }
        return layers.enumerated().map { index, urls in
            Group(directory: destination, urls: urls, keepBoth: index > 0)
        }
    }
}

/// The last-used filter and the user's named presets, as one Codable file.
public struct FileFilterPresets: Codable, Equatable, Sendable {
    public struct Named: Codable, Equatable, Sendable {
        public var name: String
        public var spec: FileFilterSpec
        public init(name: String, spec: FileFilterSpec) {
            self.name = name
            self.spec = spec
        }
    }
    public var last: FileFilterSpec?
    public var presets: [Named]
    public init(last: FileFilterSpec? = nil, presets: [Named] = []) {
        self.last = last
        self.presets = presets
    }

    /// Save or replace the preset called `name` (case-insensitive), keeping the list order.
    public mutating func save(_ spec: FileFilterSpec, as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let index = presets.firstIndex(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            presets[index] = Named(name: trimmed, spec: spec)
        } else {
            presets.append(Named(name: trimmed, spec: spec))
        }
    }

    public mutating func remove(_ name: String) {
        presets.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
