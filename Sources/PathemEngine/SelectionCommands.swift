import Foundation
import UniformTypeIdentifiers

/// The coarse kind buckets used by "Select Same Kind" and the selection summary. Decided by
/// UTType conformance from the file name, so it needs no disk access.
public enum FileKindBucket: String, Sendable, CaseIterable, Hashable {
    case folder, app, image, video, audio, document, code, archive, other

    public static func of(_ entry: FileEntry) -> FileKindBucket {
        if entry.isDirectory {
            return (entry.name as NSString).pathExtension.lowercased() == "app" ? .app : .folder
        }
        let ext = (entry.name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        // Code first: source files conform to .text, which would otherwise read as a document.
        if type.conforms(to: .sourceCode) || codeExtensions.contains(ext.lowercased()) {
            return .code
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .app }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .content)
            || type.conforms(to: .compositeContent)
        {
            return .document
        }
        return .other
    }

    /// Config and markup formats that macOS types as plain text or data, not source code.
    private static let codeExtensions: Set<String> = [
        "json", "yaml", "yml", "toml", "html", "css", "sql", "sh", "swift", "py", "rb", "go", "rs",
        "js", "ts", "jsx", "tsx", "kt", "java", "c", "h", "cpp", "hpp", "m", "mm",
    ]
}

/// Pure selection logic behind Edit > Select. Each function returns the set of entry names to
/// select; the pane applies it. Names are compared the way the volume does where two folders
/// are involved.
public enum SelectionCommands {
    public enum Comparison: String, Sendable, CaseIterable { case unique, newer, different }

    public static func invert(_ entries: [FileEntry], selected: Set<String>) -> Set<String> {
        Set(entries.map(\.name)).subtracting(selected)
    }

    public static func allFiles(_ entries: [FileEntry]) -> Set<String> {
        Set(entries.lazy.filter { !$0.isDirectory }.map(\.name))
    }

    public static func allFolders(_ entries: [FileEntry]) -> Set<String> {
        Set(entries.lazy.filter(\.isDirectory).map(\.name))
    }

    /// Files sharing the focused item's extension, case-insensitively. Folders never match.
    public static func sameExtension(as focus: FileEntry, in entries: [FileEntry]) -> Set<String> {
        func ext(_ entry: FileEntry) -> String {
            (entry.name as NSString).pathExtension.lowercased()
        }
        let wanted = ext(focus)
        return Set(entries.lazy.filter { !$0.isDirectory && ext($0) == wanted }.map(\.name))
    }

    public static func sameKind(as focus: FileEntry, in entries: [FileEntry]) -> Set<String> {
        let wanted = FileKindBucket.of(focus)
        return Set(entries.lazy.filter { FileKindBucket.of($0) == wanted }.map(\.name))
    }

    /// Compare `entries` with the other pane's listing by name. Dates within one second count as
    /// equal (FAT and network volumes round times).
    public static func compare(
        _ mode: Comparison, _ entries: [FileEntry], with other: [FileEntry],
        caseSensitive: Bool = false
    ) -> Set<String> {
        var theirs: [Data: FileEntry] = [:]
        for entry in other {
            theirs[BatchRename.nameKey(entry.name, caseSensitive: caseSensitive)] = entry
        }
        var result = Set<String>()
        for entry in entries {
            let match = theirs[BatchRename.nameKey(entry.name, caseSensitive: caseSensitive)]
            switch mode {
            case .unique:
                if match == nil { result.insert(entry.name) }
            case .newer:
                if let match, dateOrder(entry.modificationDate, match.modificationDate) > 0 {
                    result.insert(entry.name)
                }
            case .different:
                if let match,
                    entry.size != match.size
                        || dateOrder(entry.modificationDate, match.modificationDate) != 0
                {
                    result.insert(entry.name)
                }
            }
        }
        return result
    }

    /// 1 when `a` is more than a second after `b`, -1 when before, 0 when equal or unknown.
    private static func dateOrder(_ a: Date?, _ b: Date?) -> Int {
        guard let a, let b else { return 0 }
        let delta = a.timeIntervalSince(b)
        return delta > 1 ? 1 : (delta < -1 ? -1 : 0)
    }
}
