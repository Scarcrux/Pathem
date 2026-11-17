import Foundation

/// Pure logic behind the `pathem` command-line tool (Foundation only, so it is unit-testable):
/// argument parsing, the open-vs-reveal choice, path resolution, and parsing of
/// `git status --porcelain -z` output. The executable only wires these to the filesystem, `git`
/// and Launch Services.
public enum PathemCLI {
    public static let usage = """
        usage: pathem [--print] <path>              open a folder, or reveal a file, in Pathem
               pathem [--print] open <folder>       navigate into a folder
               pathem [--print] reveal <path>       select an item in its parent folder
               pathem [--print] preview <file>      show a file in the read-only viewer
               pathem [--print] changed [dir]       reveal the newest uncommitted change in the
                                                    git repo containing dir (default: current
                                                    directory) and list the other changed paths,
                                                    relative to the repo root, one per line
               pathem --help

        Relative paths resolve against the current directory and must exist.
        --print shows the pathem:// URL instead of opening it.
        """

    public enum Invocation: Equatable, Sendable {
        case help
        /// `verb == nil` means choose automatically: open a folder, reveal anything else.
        case act(verb: PathemURLContract.Verb?, path: String, printOnly: Bool)
        case changed(directory: String?, printOnly: Bool)
    }

    /// `arguments` excludes the program name. Returns nil when the arguments are not valid usage.
    public static func parse(_ arguments: [String]) -> Invocation? {
        var printOnly = false
        var positional: [String] = []
        for argument in arguments {
            switch argument {
            case "-h", "--help": return .help
            case "--print": printOnly = true
            default:
                if argument.hasPrefix("-") && argument.count > 1 { return nil }
                positional.append(argument)
            }
        }
        guard let first = positional.first else { return nil }
        if first == "changed" {
            guard positional.count <= 2 else { return nil }
            return .changed(directory: positional.dropFirst().first, printOnly: printOnly)
        }
        if let verb = PathemURLContract.Verb(rawValue: first) {
            guard positional.count == 2 else { return nil }
            return .act(verb: verb, path: positional[1], printOnly: printOnly)
        }
        guard positional.count == 1 else { return nil }
        return .act(verb: nil, path: first, printOnly: printOnly)
    }

    /// The verb for a bare `pathem <path>`: folders open, everything else is revealed.
    public static func automaticVerb(isDirectory: Bool) -> PathemURLContract.Verb {
        isDirectory ? .open : .reveal
    }

    /// Absolute, standardized path for `raw`, resolving relative paths against `directory`.
    public static func resolve(_ raw: String, against directory: String) -> String {
        let absolute = (raw as NSString).isAbsolutePath ? raw : directory + "/" + raw
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    /// Paths (relative to the repo root) from `git status --porcelain -z` output. For a rename or
    /// copy the new name is returned and the source entry that follows is skipped. Deleted entries
    /// are returned too; the caller drops paths that no longer exist.
    public static func parsePorcelainZ(_ output: Data) -> [String] {
        var paths: [String] = []
        let fields = output.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        var index = 0
        while index < fields.count {
            let entry = fields[index]
            index += 1
            let scalars = Array(entry.unicodeScalars)
            guard scalars.count >= 4 else { continue }
            let status = scalars[0..<2]
            if status.contains("R") || status.contains("C") { index += 1 }
            paths.append(String(String.UnicodeScalarView(scalars[3...])))
        }
        return paths
    }
}
