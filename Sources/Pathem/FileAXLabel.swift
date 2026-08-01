import Foundation
import PathemEngine
import UniformTypeIdentifiers

/// A spoken VoiceOver description of a file entry, shared by every view (list, icon, column, tree)
/// so a screen-reader user hears name, kind, size, and modified date instead of the bare filename.
/// Also the single home for the localized "kind" string used by the Kind column.
enum FileAXLabel {
    static func describe(_ entry: FileEntry) -> String {
        var parts = [entry.name, entry.isDirectory ? L("list.ax.folder", "folder") : kind(for: entry)]
        if !entry.isDirectory {
            parts.append(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
        }
        if let date = entry.modificationDate {
            parts.append(dateFormatter.string(from: date))
        }
        return parts.joined(separator: ", ")
    }

    /// A human-readable, localized file kind derived from the extension (no I/O).
    static func kind(for entry: FileEntry) -> String {
        if entry.isDirectory { return L("list.kindFolder", "Folder") }
        let ext = (entry.name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type.localizedDescription ?? String(format: L("list.kindExtFile", "%@ file"), ext.uppercased())
        }
        return L("list.kindDocument", "Document")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
