import Foundation

/// The logic behind the pane's find-as-you-type field: which keys open it, which mode the
/// typed text means, how Find ranks names, how Go completes folder names, and how the inline
/// command mode ranks the registry. Pure and AppKit-free, so it is tested without a UI.
public enum TypeAheadMode: String, Sendable, CaseIterable, Codable {
    /// Jump the selection to the first name that starts with, then contains, the text.
    case find
    /// Live-filter the pane (the quick-filter engine, so `ext:` / `kind:` / `size:` work).
    case filter
    /// Treat the text as a path; complete folder names; Return navigates.
    case go
    /// A leading `>`: run a command from the registry, fuzzy matched with its keywords.
    case command
    /// A leading `?`: on-device semantic search over this folder.
    case semantic
}

public enum TypeAhead {
    /// What the text means: the effective mode and the query with any marker removed.
    public struct Parsed: Equatable, Sendable {
        public let mode: TypeAheadMode
        public let query: String
        public init(mode: TypeAheadMode, query: String) {
            self.mode = mode
            self.query = query
        }
    }

    /// Read the typed text. A leading `/`, `~` or exactly-`..`-then-`/` path means Go, `>` means
    /// command and `?` means semantic; anything else stays in the user's chosen `manual` mode
    /// (find or filter). Go keeps the whole text as its query (the slash is part of the path);
    /// the command and semantic markers are dropped.
    public static func parse(_ text: String, manual: TypeAheadMode) -> Parsed {
        let base: TypeAheadMode = (manual == .filter) ? .filter : .find
        if text.hasPrefix(">") { return Parsed(mode: .command, query: String(text.dropFirst())) }
        if text.hasPrefix("?") { return Parsed(mode: .semantic, query: String(text.dropFirst())) }
        if text.hasPrefix("/") || text.hasPrefix("~") || text == ".." || text.hasPrefix("../") {
            return Parsed(mode: .go, query: text)
        }
        return Parsed(mode: base, query: text)
    }

    /// Tab: Find and Filter swap; the prefix modes do not cycle (their text decides the mode).
    public static func cycled(_ mode: TypeAheadMode) -> TypeAheadMode {
        switch mode {
        case .find: return .filter
        case .filter: return .find
        default: return mode
        }
    }

    /// Whether a key event's characters may open the field: one printable character, no
    /// Command, Option or Control. Space is excluded (it is Quick Look), as are control
    /// characters and the private-use range AppKit uses for arrows and function keys.
    public static func opens(with characters: String, cmd: Bool, opt: Bool, ctrl: Bool) -> Bool {
        guard !cmd, !opt, !ctrl, characters.count == 1, let scalar = characters.unicodeScalars.first
        else { return false }
        if scalar == " " { return false }
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        return true
    }

    /// The full gate: a printable key that no keymap binding claims. A bound key (even one
    /// whose command is disabled right now) keeps its meaning; the field never steals it.
    public static func shouldOpen(typed: String, shift: Bool, keymap: Keymap) -> Bool {
        guard opens(with: typed, cmd: false, opt: false, ctrl: false) else { return false }
        let chord = KeyChord.from(
            keyCode: 0, characters: typed, cmd: false, opt: false, ctrl: false, shift: shift)
        return keymap.commandID(for: chord) == nil
    }

    // MARK: Find

    /// Indices of `names` that match `query`, names that start with it first, then names that
    /// contain it, each group in listing order. Case and diacritic insensitive. An empty
    /// query matches nothing (the field is for narrowing, not selecting everything).
    public static func matches(names: [String], query: String) -> [Int] {
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var prefix: [Int] = []
        var contains: [Int] = []
        for (index, name) in names.enumerated() {
            guard let range = name.range(of: query, options: options) else { continue }
            if range.lowerBound == name.startIndex {
                prefix.append(index)
            } else {
                contains.append(index)
            }
        }
        return prefix + contains
    }

    /// The next (or previous) position in a list of `count` matches, wrapping around.
    public static func step(from index: Int, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        return (index + (forward ? 1 : count - 1)) % count
    }

    // MARK: Go

    public struct GoCompletion: Equatable, Sendable {
        /// Folder names under the typed directory that match the typed leaf.
        public let candidates: [String]
        /// The text extended as far as is unambiguous (a unique folder gets a trailing `/`),
        /// or nil when typing more is the only way forward.
        public let completed: String?
    }

    /// Folder completion for a typed path. `base` resolves relative text (`..`, `x/`). Only
    /// folders are offered, and dot folders only once the leaf starts with a dot.
    public static func completeGo(_ text: String, base: URL, limit: Int = 200) -> GoCompletion {
        let slash = text.lastIndex(of: "/")
        let dirText = slash.map { String(text[..<text.index(after: $0)]) } ?? ""
        let leaf = slash.map { String(text[text.index(after: $0)...]) } ?? text
        // "~" or ".." alone have no slash yet: they name a directory, with nothing to complete.
        guard slash != nil else { return GoCompletion(candidates: [], completed: nil) }
        let directory = resolveDirectory(dirText.isEmpty ? "/" : dirText, base: base)
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [])) ?? []
        let showHidden = leaf.hasPrefix(".")
        var names: [String] = []
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix("."), !showHidden { continue }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            if leaf.isEmpty || name.range(of: leaf, options: [.caseInsensitive, .anchored]) != nil {
                names.append(name)
            }
        }
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        let candidates = Array(names.prefix(limit))
        guard !candidates.isEmpty else { return GoCompletion(candidates: [], completed: nil) }
        if candidates.count == 1 {
            return GoCompletion(candidates: candidates, completed: dirText + candidates[0] + "/")
        }
        let common = commonPrefix(candidates)
        let extended = common.count > leaf.count ? dirText + common : nil
        return GoCompletion(candidates: candidates, completed: extended)
    }

    private static func commonPrefix(_ names: [String]) -> String {
        guard var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            while !prefix.isEmpty,
                name.range(of: prefix, options: [.caseInsensitive, .anchored]) == nil
            {
                prefix.removeLast()
            }
        }
        // Take the casing of the first candidate (all candidates agree up to case).
        return prefix
    }

    private static func resolveDirectory(_ text: String, base: URL) -> URL {
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: true) }
        return base.appendingPathComponent(expanded, isDirectory: true)
    }

    /// Where Return in Go mode should take the user.
    public enum GoTarget: Equatable, Sendable {
        case folder(URL)
        /// A file: open its folder and select it.
        case file(URL)
        /// Nothing there; `suggestion` is the closest existing path, when one is found.
        case missing(requested: URL, suggestion: URL?)
    }

    /// Resolve typed text with the existing path resolver (tilde, relative, on-disk casing).
    public static func goTarget(_ text: String, base: URL) -> GoTarget {
        let located = PathSuggester.locate(text, base: base)
        guard let existing = located.existing else {
            return .missing(
                requested: located.requested,
                suggestion: PathSuggester.suggest(for: located.requested))
        }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: existing.path, isDirectory: &isDirectory)
        let url = existing.standardizedFileURL
        return isDirectory.boolValue ? .folder(url) : .file(url)
    }

    // MARK: Command

    public struct CommandItem: Equatable, Sendable {
        public let id: String
        public let title: String
        public let keywords: [String]
        public init(id: String, title: String, keywords: [String] = []) {
            self.id = id
            self.title = title
            self.keywords = keywords
        }
    }

    /// Rank commands the way the palette does (fuzzy on the title, aliases slightly lower).
    public static func rankCommands(_ items: [CommandItem], query: String) -> [CommandItem] {
        FuzzyMatch.rank(items, query: query, key: { $0.title }, keywords: { $0.keywords })
    }
}
