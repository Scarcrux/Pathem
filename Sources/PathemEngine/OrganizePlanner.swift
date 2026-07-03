import Foundation

/// The deterministic brain of the active organizer: given a folder it PROPOSES a set
/// of explainable, reversible suggestions (file loose items into place, trash obvious
/// junk and duplicate copies) that the UI reviews and the user approves. It never
/// touches the filesystem itself; `apply` routes accepted suggestions through the
/// existing `FileOperations`, so every action is undoable and deletes go to the Trash.
/// Pure Foundation, unit-tested against real temp trees.
///
/// Phase 1 is rules-only: `Suggestion.ruleID` and `.confidence` are the seams a later
/// behavior model adjusts to personalize the ranking. Destructive or cross-folder
/// suggestions start unchecked (confidence below `autoAcceptConfidence`), so a blind
/// "Apply" never does anything surprising.
public enum OrganizePlanner {
    // MARK: Suggestion model

    public struct Suggestion: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case move(to: URL)  // absolute destination folder (created on apply if missing)
            case trash  // to the Trash, recoverable
        }
        public var file: URL
        public var kind: Kind
        /// Which rule fired: "duplicate", "screenshots", "by-kind", "incomplete"...
        public var ruleID: String
        /// One line the review UI shows: the "because ...".
        public var rationale: String
        /// 0...1. Gates the default `accepted` state via `Config.autoAcceptConfidence`.
        public var confidence: Double
        public var size: Int64
        /// The review toggle. Defaults to `confidence >= autoAcceptConfidence`.
        public var accepted: Bool

        public init(
            file: URL, kind: Kind, ruleID: String, rationale: String, confidence: Double,
            size: Int64, accepted: Bool
        ) {
            self.file = file
            self.kind = kind
            self.ruleID = ruleID
            self.rationale = rationale
            self.confidence = confidence
            self.size = size
            self.accepted = accepted
        }

        /// The move destination, or nil for a trash suggestion.
        public var destination: URL? {
            if case .move(let url) = kind { return url }
            return nil
        }
    }

    // MARK: Facts (gathered once per file; the sole input a rule reads)

    public struct Facts: Sendable, Equatable {
        public let url: URL
        public let name: String
        public let ext: String  // lowercased extension
        public let size: Int64
        public let modified: Date?
        public let age: TimeInterval  // seconds since modified (very large when unknown)
        public let isDirectory: Bool
        public let isPackage: Bool
        public let isSymlink: Bool
        public let isLocked: Bool
        public let isDataless: Bool
        /// Host of the URL the file was downloaded from (kMDItemWhereFroms), if any.
        public let whereFromHost: String?

        public var folder: URL { url.deletingLastPathComponent() }
        public var ageDays: Int { Int(age / 86_400) }
    }

    // MARK: Rules

    public struct Rule: Sendable {
        public let id: String
        public let evaluate: @Sendable (Facts, FilingDestinations) -> Suggestion?

        public init(
            id: String, evaluate: @escaping @Sendable (Facts, FilingDestinations) -> Suggestion?
        ) {
            self.id = id
            self.evaluate = evaluate
        }

        /// Priority order; the first rule that matches a file wins. `installer` precedes
        /// `byKind` so a `.dmg` is offered for removal rather than archived.
        public static let defaults: [Rule] = [incomplete, junk, screenshots, installer, byKind]
    }

    public struct Config: Sendable {
        /// Leave files touched this recently alone (you are probably still using them, and
        /// an in-progress download is fresh, so this also protects active downloads).
        public var freshnessGraceHours: Double = 24
        /// Suggestions at or above this confidence are pre-checked in the review sheet.
        public var autoAcceptConfidence: Double = 0.75
        /// Never organize inside a git working tree (git is the backup; a later phase adds
        /// the clean-vs-precious split for untracked files).
        public var skipGitRepos = true
        /// Cap on direct children examined, so a pathological folder can't stall the UI.
        public var maxItems = 5_000

        public init() {}
    }

    // MARK: Planning

    /// Propose suggestions for the direct children of `folder`. Shallow by design: it
    /// tidies one folder at a time, which keeps the review small and the blast radius
    /// bounded. Never returns anything for a folder inside a git repo (when configured).
    public static func suggestions(
        for folder: URL, destinations: FilingDestinations, rules: [Rule] = Rule.defaults,
        config: Config = Config(), memory: OrganizeFeedback = OrganizeFeedback(), now: Date = Date()
    ) -> [Suggestion] {
        let fm = FileManager.default
        if config.skipGitRepos, isInsideGitRepo(folder) { return [] }
        guard
            let raw = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(factKeys), options: [])
        else { return [] }

        // Gather facts for the direct children that survive the guards (not a directory,
        // package, symlink, locked, dataless, or too fresh).
        var facts: [Facts] = []
        for url in raw.prefix(config.maxItems) {
            guard let f = gatherFacts(url, now: now), passesGuards(f, config) else { continue }
            facts.append(f)
        }

        var out: [Suggestion] = []
        var handled = Set<URL>()

        // Duplicate pass first, so a redundant copy is trashed rather than filed twice.
        for (extra, keptName) in duplicateExtras(facts) {
            out.append(
                trashSuggestion(
                    extra, ruleID: "duplicate", rationale: "Duplicate of \(keptName)", confidence: 0.9))
            handled.insert(extra.url)
        }

        // Per-file rules for everything not already handled.
        for f in facts where !handled.contains(f.url) {
            for rule in rules {
                if let suggestion = rule.evaluate(f, destinations) {
                    out.append(suggestion)
                    break
                }
            }
        }

        // Fold in the learned behavior signal, then apply the acceptance policy centrally,
        // so every rule stays confidence-only and personalization lives in one place.
        return out.map { base in
            var s = base
            let bias = memory.confidenceBias(
                ruleID: s.ruleID, ext: s.file.pathExtension.lowercased(),
                destination: s.destination?.lastPathComponent)
            let defaultAccepted = s.confidence >= config.autoAcceptConfidence
            s.confidence = min(1, max(0, s.confidence + bias))
            s.accepted = s.confidence >= config.autoAcceptConfidence
            // When the learned signal flips the default, say so (transparency: the user
            // can always see why a suggestion is checked or not).
            if s.accepted != defaultAccepted {
                s.rationale +=
                    s.accepted
                    ? "  (learned: you usually keep these)"
                    : "  (learned: you usually skip these)"
            }
            return s
        }
    }

    /// Execute the accepted suggestions via the existing file operations and return the
    /// undo records (moves and trashes), so the caller registers undo exactly like every
    /// other local file op. Never touches an unaccepted suggestion.
    public static func apply(_ suggestions: [Suggestion]) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for s in suggestions where s.accepted {
            switch s.kind {
            case .move(let dest):
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                // keepBoth, never overwrite: filing must not clobber a same-named file.
                let result = FileOperations.move(urls: [s.file], into: dest, onConflict: .keepBoth)
                if let record = result.performed.first {
                    outcome.moved += 1
                    outcome.performed.append(record)
                } else {
                    outcome.failures.append(s.file.lastPathComponent)
                }
            case .trash:
                let result = FileOperations.trash(urls: [s.file])
                if let item = result.trashed.first {
                    outcome.trashed += 1
                    outcome.trashedItems.append(item)
                } else {
                    outcome.failures.append(s.file.lastPathComponent)
                }
            }
        }
        return outcome
    }

    public struct Outcome: Sendable, Equatable {
        public var moved = 0
        public var trashed = 0
        public var performed: [FileOperations.Performed] = []
        public var trashedItems: [FileOperations.Trashed] = []
        public var failures: [String] = []
        public init() {}
    }

    // MARK: Default rules

    static let incomplete = Rule(id: "incomplete") { facts, _ in
        guard incompleteExts.contains(facts.ext) else { return nil }
        return trashSuggestion(
            facts, ruleID: "incomplete", rationale: "Incomplete or abandoned download", confidence: 0.9)
    }

    static let junk = Rule(id: "junk") { facts, _ in
        guard junkFileNames.contains(facts.name) else { return nil }
        return trashSuggestion(facts, ruleID: "junk", rationale: "System junk file", confidence: 0.9)
    }

    static let screenshots = Rule(id: "screenshots") { facts, destinations in
        guard isScreenshot(facts) else { return nil }
        let target =
            destinations.named("Screenshots")?.url ?? facts.folder.appendingPathComponent("Screenshots")
        guard facts.folder.standardizedFileURL != target.standardizedFileURL else { return nil }
        return moveSuggestion(
            facts, to: target, ruleID: "screenshots",
            rationale: "Screenshot to \(target.lastPathComponent)", confidence: 0.85)
    }

    static let installer = Rule(id: "installer") { facts, _ in
        guard installerExts.contains(facts.ext) else { return nil }
        // Low confidence: surfaced for review, unchecked by default (could still be needed).
        return trashSuggestion(
            facts, ruleID: "installer", rationale: "Installer, safe to remove once installed",
            confidence: 0.5)
    }

    static let byKind = Rule(id: "by-kind") { facts, _ in
        guard let mapping = kindMapping(facts.ext) else { return nil }
        let target = facts.folder.appendingPathComponent(mapping.subfolder)
        guard facts.folder.standardizedFileURL != target.standardizedFileURL else { return nil }
        let from = facts.whereFromHost.map { " from \($0)" } ?? ""
        return moveSuggestion(
            facts, to: target, ruleID: "by-kind",
            rationale: "\(mapping.label)\(from) to \(mapping.subfolder)", confidence: 0.8)
    }

    // MARK: Rule helpers

    private static func moveSuggestion(
        _ facts: Facts, to destination: URL, ruleID: String, rationale: String, confidence: Double
    ) -> Suggestion {
        Suggestion(
            file: facts.url, kind: .move(to: destination), ruleID: ruleID, rationale: rationale,
            confidence: confidence, size: facts.size, accepted: false)
    }

    private static func trashSuggestion(
        _ facts: Facts, ruleID: String, rationale: String, confidence: Double
    ) -> Suggestion {
        Suggestion(
            file: facts.url, kind: .trash, ruleID: ruleID, rationale: rationale, confidence: confidence,
            size: facts.size, accepted: false)
    }

    static func isScreenshot(_ facts: Facts) -> Bool {
        guard imageExts.contains(facts.ext) else { return false }
        let lower = facts.name.lowercased()
        return lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot")
            || lower.hasPrefix("cleanshot")
    }

    /// Maps a file extension to an in-folder subfolder and a human label. Phase 1 tidies
    /// into subfolders of the scanned folder (Downloads/Images, Downloads/PDFs); routing
    /// to external designated folders by learned habit is a later phase.
    static func kindMapping(_ ext: String) -> (subfolder: String, label: String)? {
        if imageExts.contains(ext) { return ("Images", "Image") }
        if videoExts.contains(ext) { return ("Movies", "Video") }
        if audioExts.contains(ext) { return ("Audio", "Audio") }
        if ext == "pdf" { return ("PDFs", "PDF") }
        if documentExts.contains(ext) { return ("Documents", "Document") }
        if archiveExts.contains(ext) { return ("Archives", "Archive") }
        return nil
    }

    // MARK: Facts gathering

    static let factKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
        .contentModificationDateKey, .isUserImmutableKey,
    ]

    static func gatherFacts(_ url: URL, now: Date) -> Facts? {
        guard let v = try? url.resourceValues(forKeys: factKeys) else { return nil }
        let modified = v.contentModificationDate
        let age = modified.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let host = FileMetadata.whereFroms(of: url).first.flatMap { URL(string: $0)?.host }
        return Facts(
            url: url, name: url.lastPathComponent, ext: url.pathExtension.lowercased(),
            size: Int64(v.fileSize ?? 0), modified: modified, age: age,
            isDirectory: v.isDirectory ?? false, isPackage: v.isPackage ?? false,
            isSymlink: v.isSymbolicLink ?? false, isLocked: v.isUserImmutable ?? false,
            isDataless: isDataless(url), whereFromHost: host)
    }

    static func passesGuards(_ facts: Facts, _ config: Config) -> Bool {
        if facts.isDirectory || facts.isPackage || facts.isSymlink { return false }
        if facts.isLocked || facts.isDataless { return false }
        if facts.age < config.freshnessGraceHours * 3600 { return false }
        return true
    }

    /// SF_DATALESS (0x40000000) marks an online-only cloud placeholder. Read it from
    /// st_flags without materializing the file (moving/trashing a placeholder is fine,
    /// but hashing it for the duplicate pass would trigger a download).
    static func isDataless(_ url: URL) -> Bool {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return false }
        return (st.st_flags & 0x4000_0000) != 0
    }

    /// Whether `folder` is at or under a git working tree.
    static func isInsideGitRepo(_ folder: URL) -> Bool {
        let fm = FileManager.default
        var dir = folder.standardizedFileURL
        while true {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path, isDirectory: &isDir) {
                return true
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path { break }
            dir = parent
        }
        return false
    }

    /// Direct-child duplicates by content: keep the newest, return the rest as extras.
    /// Cheap-to-expensive funnel (bucket by size, hash only size collisions), reusing the
    /// same hasher as DuplicateFinder. Skips dataless placeholders (hashing downloads them).
    static func duplicateExtras(_ files: [Facts]) -> [(extra: Facts, keptName: String)] {
        var bySize: [Int64: [Facts]] = [:]
        for f in files where f.size >= 1 && !f.isDataless { bySize[f.size, default: []].append(f) }
        var result: [(Facts, String)] = []
        for (_, group) in bySize where group.count > 1 {
            var byHash: [String: [Facts]] = [:]
            for f in group {
                guard let hash = try? FileHasher.hash(f.url) else { continue }
                byHash[hash, default: []].append(f)
            }
            for (_, dups) in byHash where dups.count > 1 {
                let newestFirst = dups.sorted {
                    ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast)
                }
                let kept = newestFirst[0]
                for extra in newestFirst.dropFirst() { result.append((extra, kept.name)) }
            }
        }
        return result
    }

    // MARK: Extension sets

    static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "raw", "dng",
    ]
    static let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "aif"]
    static let documentExts: Set<String> = [
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "pages", "numbers", "key", "csv",
        "md", "odt",
    ]
    static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "7z", "rar"]
    static let installerExts: Set<String> = ["dmg", "pkg"]
    static let incompleteExts: Set<String> = ["crdownload", "part", "download", "partial"]
    static let junkFileNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini", ".localized"]
}
