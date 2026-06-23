import Foundation

/// Parses an FTP directory listing (the raw `LIST` response) into FileEntry
/// values. Handles the common Unix `ls -l` style; pure and unit-tested so the
/// fiddly bit is verified without a live server.
public enum FTPListParser {
    public static func parse(_ text: String) -> [FileEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ line: String) -> FileEntry? {
        // Unix: "drwxr-xr-x  2 user group   4096 Jan 01 12:00 name with spaces"
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 9, let perms = parts.first, perms.count >= 10 else { return nil }
        let type = perms.first!
        let isDir = type == "d"
        let isSymlink = type == "l"
        let size = Int64(parts[4]) ?? 0
        // Name is everything from field 8 on (keeps spaces); strip the symlink target.
        var name = parts[8...].joined(separator: " ")
        if isSymlink, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        // A symlink to a directory can't be known from LIST alone; treat links as files.
        return FileEntry(name: name, isDirectory: isDir, size: isDir ? 0 : size, modificationDate: nil)
    }
}
