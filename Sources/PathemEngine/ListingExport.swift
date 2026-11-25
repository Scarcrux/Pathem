import Foundation
import UniformTypeIdentifiers

/// One exported column. Size always writes two columns (bytes, then human readable) so a
/// spreadsheet can sort on the first and a person can read the second.
public enum ListingField: String, Sendable, CaseIterable, Equatable {
    case name, path, kind, size, modified, created, accessed

    /// Map the file list's column identifiers to export fields, in order. Columns that need
    /// per-file metadata reads (tags, owner, dimensions) are not exported.
    public static func fields(forColumnIDs ids: [String], recursive: Bool) -> [ListingField] {
        var result: [ListingField] = []
        for id in ids {
            let field: ListingField?
            switch id {
            case "name": field = .name
            case "path": field = .path
            case "kind": field = .kind
            case "size": field = .size
            case "date": field = .modified
            case "dateCreated": field = .created
            case "dateAccessed": field = .accessed
            default: field = nil
            }
            if let field, !result.contains(field) { result.append(field) }
        }
        if !result.contains(.name) { result.insert(.name, at: 0) }
        if recursive, !result.contains(.path) { result.insert(.path, at: 1) }
        return result
    }
}

/// An entry plus where it sits under the exported folder (the name itself when not recursive).
public struct ListingItem: Sendable, Equatable {
    public let entry: FileEntry
    public let relativePath: String
    public init(entry: FileEntry, relativePath: String) {
        self.entry = entry
        self.relativePath = relativePath
    }
}

/// Renders a folder listing as CSV, TSV, aligned text or HTML. Pure and testable; the app
/// supplies the entries (already in the visible sort and filter) and writes the result.
public enum ListingExport {
    public enum Format: String, Sendable, CaseIterable {
        case csv, tsv, text, html
        public var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .tsv: return "tsv"
            case .text: return "txt"
            case .html: return "html"
            }
        }
    }

    public struct Document: Sendable {
        public var title: String
        public var generated: Date
        public var fields: [ListingField]
        public var items: [ListingItem]
        public var truncated: Bool
        public init(
            title: String, generated: Date = Date(), fields: [ListingField],
            items: [ListingItem], truncated: Bool = false
        ) {
            self.title = title
            self.generated = generated
            self.fields = fields
            self.items = items
            self.truncated = truncated
        }
    }

    /// Localizable header captions; the English defaults apply when none are given.
    public struct Captions: Sendable {
        public var name = "Name"
        public var path = "Path"
        public var kind = "Kind"
        public var sizeBytes = "Size (bytes)"
        public var size = "Size"
        public var modified = "Date Modified"
        public var created = "Date Created"
        public var accessed = "Date Last Opened"
        public init() {}
    }

    // MARK: Rows

    public static func header(_ fields: [ListingField], captions: Captions = Captions())
        -> [String]
    {
        fields.flatMap { field -> [String] in
            switch field {
            case .name: return [captions.name]
            case .path: return [captions.path]
            case .kind: return [captions.kind]
            case .size: return [captions.sizeBytes, captions.size]
            case .modified: return [captions.modified]
            case .created: return [captions.created]
            case .accessed: return [captions.accessed]
            }
        }
    }

    public static func rows(
        _ document: Document, timeZone: TimeZone = .current,
        kindLabel: (FileEntry) -> String = defaultKindLabel
    ) -> [[String]] {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        func date(_ value: Date?) -> String { value.map(formatter.string(from:)) ?? "" }
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        return document.items.map { item in
            document.fields.flatMap { field -> [String] in
                let entry = item.entry
                switch field {
                case .name: return [entry.name]
                case .path: return [item.relativePath]
                case .kind: return [kindLabel(entry)]
                case .size:
                    // A folder's size is not part of a listing, so leave the cells empty
                    // rather than writing a misleading 0.
                    return entry.isDirectory
                        ? ["", ""] : [String(entry.size), bytes.string(fromByteCount: entry.size)]
                case .modified: return [date(entry.modificationDate)]
                case .created: return [date(entry.creationDate)]
                case .accessed: return [date(entry.accessDate)]
                }
            }
        }
    }

    public static func defaultKindLabel(_ entry: FileEntry) -> String {
        if entry.isDirectory { return "Folder" }
        let ext = (entry.name as NSString).pathExtension
        if !ext.isEmpty, let text = UTType(filenameExtension: ext)?.localizedDescription {
            return text
        }
        return ext.isEmpty ? "Document" : ext.uppercased() + " file"
    }

    // MARK: Writers

    public static func render(
        _ document: Document, as format: Format, captions: Captions = Captions(),
        timeZone: TimeZone = .current, accentHex: String? = nil,
        kindLabel: (FileEntry) -> String = defaultKindLabel
    ) -> String {
        let head = header(document.fields, captions: captions)
        let body = rows(document, timeZone: timeZone, kindLabel: kindLabel)
        switch format {
        case .csv: return csv([head] + body)
        case .tsv: return tsv([head] + body)
        case .text: return text(head: head, body: body, document: document)
        case .html: return html(head: head, body: body, document: document, accentHex: accentHex)
        }
    }

    /// RFC 4180: records end with CRLF; a field holding a comma, double quote, CR or LF is
    /// wrapped in double quotes, with embedded quotes doubled.
    public static func csv(_ records: [[String]]) -> String {
        func field(_ value: String) -> String {
            let needsQuotes = value.unicodeScalars.contains {
                $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n"
            }
            guard needsQuotes else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return records.map { $0.map(field).joined(separator: ",") + "\r\n" }.joined()
    }

    /// Tab-separated, one line per record. Tabs, newlines and backslashes inside a field are
    /// written as `\t`, `\n`, `\r` and `\\`, so every record stays on one line and survives a
    /// round trip.
    public static func tsv(_ records: [[String]]) -> String {
        func field(_ value: String) -> String {
            var out = ""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\\": out += "\\\\"
                case "\t": out += "\\t"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out
        }
        return records.map { $0.map(field).joined(separator: "\t") + "\n" }.joined()
    }

    /// Plain text with padded columns. Control characters in names show as escapes so a
    /// name cannot break a line.
    static func text(head: [String], body: [[String]], document: Document) -> String {
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(
                of: "\r", with: "\\r"
            ).replacingOccurrences(of: "\t", with: "\\t")
        }
        let all = ([head] + body).map { $0.map(clean) }
        var widths = [Int](repeating: 0, count: head.count)
        for row in all {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }
        func line(_ row: [String]) -> String {
            var out = ""
            for (i, cell) in row.enumerated() {
                out += cell
                if i < row.count - 1 {
                    out += String(repeating: " ", count: widths[i] - cell.count + 2)
                }
            }
            return out + "\n"
        }
        var result = line(all[0])
        result += String(repeating: "-", count: widths.reduce(0, +) + 2 * (widths.count - 1)) + "\n"
        for row in all.dropFirst() { result += line(row) }
        return result
    }

    public static func escapeHTML(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func html(
        head: [String], body: [[String]], document: Document, accentHex: String?
    ) -> String {
        // Only a plain hex color reaches the stylesheet.
        let accent =
            accentHex.flatMap {
                $0.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil ? $0 : nil
            }
            ?? "#0a6cff"
        let stamp = ISO8601DateFormatter().string(from: document.generated)
        var out = """
            <!DOCTYPE html>
            <html lang="en"><head><meta charset="utf-8">
            <title>\(escapeHTML(document.title))</title>
            <style>
            :root { color-scheme: light dark; --accent: \(accent); }
            body { font: 13px -apple-system, system-ui, sans-serif; margin: 24px; }
            h1 { font-size: 16px; margin: 0 0 2px; }
            p.meta { color: gray; margin: 0 0 14px; }
            table { border-collapse: collapse; width: 100%; }
            th { text-align: left; border-bottom: 2px solid var(--accent); padding: 4px 10px 4px 0; }
            td { border-bottom: 1px solid rgba(128,128,128,.25); padding: 3px 10px 3px 0; }
            tr:nth-child(even) td { background: rgba(128,128,128,.07); }
            td.num { text-align: right; font-variant-numeric: tabular-nums; }
            </style></head><body>
            <h1>\(escapeHTML(document.title))</h1>
            <p class="meta">\(body.count) items, \(escapeHTML(stamp))\(document.truncated ? ", list cut short" : "")</p>
            <table><thead><tr>
            """
        out += head.map { "<th>\(escapeHTML($0))</th>" }.joined()
        out += "</tr></thead><tbody>\n"
        let numeric = Set(head.indices.filter { head[$0].localizedCaseInsensitiveContains("size") })
        for row in body {
            out += "<tr>"
            for (i, cell) in row.enumerated() {
                out += "<td\(numeric.contains(i) ? " class=\"num\"" : "")>\(escapeHTML(cell))</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody></table></body></html>\n"
        return out
    }

    // MARK: Collecting

    /// Apply the export options to a listing that is already sorted and filtered the way the
    /// pane shows it. `selected` nil means every entry.
    public static func items(
        from entries: [FileEntry], selected: Set<String>?, includeHidden: Bool
    ) -> [ListingItem] {
        entries.filter { entry in
            (includeHidden || !entry.isHidden) && (selected?.contains(entry.name) ?? true)
        }.map { ListingItem(entry: $0, relativePath: $0.name) }
    }

    /// Walk `root` depth first, emitting every file and folder with a path relative to it.
    /// `topLevelNames` limits the first level to those names. Bounded by `maxItems` and `maxDepth`, and checked against `isCancelled` between folders.
    public static func collectRecursively(
        root: URL, includeHidden: Bool, topLevelNames: Set<String>? = nil,
        maxItems: Int = 100_000, maxDepth: Int = 32, isCancelled: () -> Bool = { false }
    ) -> (items: [ListingItem], truncated: Bool) {
        var out: [ListingItem] = []
        var truncated = false
        var stack: [(url: URL, prefix: String, depth: Int)] = [(root, "", 0)]
        while let (dir, prefix, depth) = stack.popLast() {
            if isCancelled() {
                truncated = true
                break
            }
            let children =
                (try? BulkEnumerator().entries(of: dir, includingHidden: includeHidden)) ?? []
            let sorted = children.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            var subdirs: [(URL, String, Int)] = []
            for child in sorted {
                // Only the chosen top-level items (and what is under them) when exporting a selection.
                if depth == 0, let topLevelNames, !topLevelNames.contains(child.name) { continue }
                if out.count >= maxItems {
                    truncated = true
                    break
                }
                let relative = prefix + child.name
                out.append(ListingItem(entry: child, relativePath: relative))
                if child.isDirectory, depth < maxDepth {
                    subdirs.append(
                        (dir.appendingPathComponent(child.name), relative + "/", depth + 1))
                }
            }
            if truncated { break }
            for entry in subdirs.reversed() { stack.append(entry) }
        }
        return (out, truncated)
    }
}
