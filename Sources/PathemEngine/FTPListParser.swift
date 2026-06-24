import Foundation

/// Parses an FTP/SFTP directory listing (the raw `LIST` / `ls -l` response) into
/// FileEntry values. Handles the common Unix `ls -l` style; pure and unit-tested
/// so the fiddly bit is verified without a live server.
///
/// Parsing works on the raw bytes so a name that isn't valid UTF-8 keeps its exact
/// bytes (`FileEntry.rawName`) instead of being lost to a lossy decode; `name` is
/// the lossy decode for display.
public enum FTPListParser {
    public static func parse(_ text: String) -> [FileEntry] {
        parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) -> [FileEntry] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { parseLine(Array($0)) }
    }

    static func parseLine(_ bytes: [UInt8]) -> FileEntry? {
        // Unix: "drwxr-xr-x  2 user group   4096 Jan 01 12:00 name with spaces"
        let space: UInt8 = 0x20
        // Start index of each space-delimited field.
        var starts: [Int] = []
        var inField = false
        for (i, b) in bytes.enumerated() {
            if b == space {
                inField = false
            } else if !inField {
                starts.append(i)
                inField = true
            }
        }
        guard starts.count >= 9 else { return nil }

        let permsEnd = bytes[starts[0]...].firstIndex(of: space) ?? bytes.count
        guard permsEnd - starts[0] >= 10 else { return nil }
        let type = bytes[starts[0]]
        let isDir = type == UInt8(ascii: "d")
        let isSymlink = type == UInt8(ascii: "l")
        let isDevice = type == UInt8(ascii: "c") || type == UInt8(ascii: "b")

        // A char/block device lists "major, minor" where a regular file lists its
        // size. When the major ends with a comma, the minor is a separate field, so
        // the name (and the size's absence) shift one column right.
        let sizeEnd = bytes[starts[4]...].firstIndex(of: space) ?? bytes.count
        let majorHasComma = isDevice && bytes[sizeEnd - 1] == UInt8(ascii: ",")
        let nameField = majorHasComma ? 9 : 8
        guard starts.count > nameField else { return nil }
        let size: Int64 =
            isDevice ? 0 : (Int64(String(decoding: bytes[starts[4]..<sizeEnd], as: UTF8.self)) ?? 0)

        // Name is the verbatim remainder from the name field (preserves internal
        // multiple spaces); strip a symlink's " -> target".
        var nameBytes = Array(bytes[starts[nameField]...])
        if isSymlink, let arrow = Self.arrowRange(in: nameBytes) { nameBytes = Array(nameBytes[..<arrow]) }
        while let last = nameBytes.last, last == space || last == 0x0D { nameBytes.removeLast() }
        guard !nameBytes.isEmpty else { return nil }

        let raw = Data(nameBytes)
        let display = String(decoding: raw, as: UTF8.self)
        guard display != ".", display != ".." else { return nil }
        let isUTF8Clean = Array(display.utf8) == nameBytes  // only keep rawName when it differs
        return FileEntry(
            name: display, isDirectory: isDir, size: isDir ? 0 : size, modificationDate: nil,
            rawName: isUTF8Clean ? nil : raw)
    }

    /// The index of " -> " (the symlink separator) in the name bytes, if present.
    private static func arrowRange(in bytes: [UInt8]) -> Int? {
        let arrow: [UInt8] = [0x20, 0x2D, 0x3E, 0x20]  // " -> "
        guard bytes.count >= arrow.count else { return nil }
        for i in 0...(bytes.count - arrow.count) where Array(bytes[i..<(i + arrow.count)]) == arrow {
            return i
        }
        return nil
    }
}
