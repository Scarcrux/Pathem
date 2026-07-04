import Foundation

/// A Hazel-style automation rule: when a file in a watched folder matches the criteria,
/// an action runs automatically. The matching and the action are pure engine logic (unit
/// tested); the app owns the folder watchers that fire it. Reuses OrganizePlanner's fact
/// gathering and extension classification so behavior stays consistent with the organizer.
public struct AutomationRule: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case image, video, audio, document, archive
    }
    public enum Action: String, Codable, Sendable, CaseIterable { case move, trash, tag }

    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// The folder this rule watches.
    public var folderPath: String

    // Criteria: every one that is set must match.
    public var nameContains: String?
    public var ext: String?
    public var kind: Kind?
    public var olderThanDays: Int?
    public var fromHostContains: String?

    // Action.
    public var action: Action
    public var destinationPath: String?  // for .move
    public var tag: String?  // for .tag

    public init(
        id: UUID = UUID(), name: String = "", enabled: Bool = true, folderPath: String = "",
        nameContains: String? = nil, ext: String? = nil, kind: Kind? = nil, olderThanDays: Int? = nil,
        fromHostContains: String? = nil, action: Action = .move, destinationPath: String? = nil,
        tag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.folderPath = folderPath
        self.nameContains = nameContains
        self.ext = ext
        self.kind = kind
        self.olderThanDays = olderThanDays
        self.fromHostContains = fromHostContains
        self.action = action
        self.destinationPath = destinationPath
        self.tag = tag
    }
}

public enum AutomationEngine {
    public struct Outcome: Sendable, Equatable {
        public var ruleName: String
        public var file: String
        public var action: String
        public var success: Bool
    }

    /// Whether `rule` matches `file`. Rules act on files, not folders.
    public static func matches(_ rule: AutomationRule, file: URL, now: Date = Date()) -> Bool {
        guard rule.enabled, let facts = OrganizePlanner.gatherFacts(file, now: now), !facts.isDirectory
        else { return false }
        if let sub = rule.nameContains, !sub.isEmpty, !facts.name.localizedCaseInsensitiveContains(sub) {
            return false
        }
        if let ext = rule.ext, !ext.isEmpty, facts.ext != ext.lowercased() { return false }
        if let kind = rule.kind, kindOf(facts.ext) != kind { return false }
        if let days = rule.olderThanDays, facts.ageDays < days { return false }
        if let host = rule.fromHostContains, !host.isEmpty {
            guard let from = facts.whereFromHost, from.localizedCaseInsensitiveContains(host) else {
                return false
            }
        }
        return true
    }

    /// Run the rule's action on a matching file.
    public static func apply(_ rule: AutomationRule, to file: URL) -> Outcome {
        func outcome(_ success: Bool) -> Outcome {
            Outcome(ruleName: rule.name, file: file.lastPathComponent, action: rule.action.rawValue, success: success)
        }
        switch rule.action {
        case .move:
            guard let destination = rule.destinationPath, !destination.isEmpty else { return outcome(false) }
            let dir = URL(fileURLWithPath: destination)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return outcome(!FileOperations.move(urls: [file], into: dir, onConflict: .keepBoth).performed.isEmpty)
        case .trash:
            return outcome(!FileOperations.trash(urls: [file]).trashed.isEmpty)
        case .tag:
            guard let tag = rule.tag, !tag.isEmpty else { return outcome(false) }
            var tags = FileTags.tags(of: file)
            if !tags.contains(where: { $0.name.caseInsensitiveCompare(tag) == .orderedSame }) {
                tags.append(FileTag(name: tag, color: .none))
            }
            return outcome((try? FileTags.setTags(tags, on: file)) != nil)
        }
    }

    /// Apply every enabled rule for `folder` to the files currently in it (the first
    /// matching rule per file wins). Used by "Run Now" and by the folder watcher.
    @discardableResult
    public static func run(_ rules: [AutomationRule], in folder: URL, now: Date = Date()) -> [Outcome] {
        let forFolder = rules.filter {
            $0.enabled && URL(fileURLWithPath: $0.folderPath).standardizedFileURL == folder.standardizedFileURL
        }
        guard !forFolder.isEmpty,
            let entries = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [])
        else { return [] }
        var outcomes: [Outcome] = []
        for file in entries {
            if let rule = forFolder.first(where: { matches($0, file: file, now: now) }) {
                outcomes.append(apply(rule, to: file))
            }
        }
        return outcomes
    }

    static func kindOf(_ ext: String) -> AutomationRule.Kind? {
        if OrganizePlanner.imageExts.contains(ext) { return .image }
        if OrganizePlanner.videoExts.contains(ext) { return .video }
        if OrganizePlanner.audioExts.contains(ext) { return .audio }
        if ext == "pdf" || OrganizePlanner.documentExts.contains(ext) { return .document }
        if OrganizePlanner.archiveExts.contains(ext) { return .archive }
        return nil
    }
}
