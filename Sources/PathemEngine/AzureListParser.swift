import Foundation

/// Parses Azure Blob "List Blobs" and "List Containers" XML responses into
/// FileEntry rows. With `delimiter=/`, `Blob` elements are files and `BlobPrefix`
/// elements are folders; blob names are made relative to the requested prefix.
/// Containers list as top-level folders. Also returns the `NextMarker` so the
/// provider can page. Pure, so it's unit-tested.
public enum AzureListParser {
    public struct Result: Sendable, Equatable {
        public let entries: [FileEntry]
        public let nextMarker: String?
    }

    /// Parse a "List Blobs" (delimiter=/) response, names relative to `prefix`.
    public static func parseBlobs(_ data: Data, prefix: String) -> Result {
        let delegate = Delegate(mode: .blobs, prefix: prefix)
        parse(delegate, data)
        return Result(entries: delegate.entries, nextMarker: delegate.nextMarker)
    }

    /// Parse a "List Containers" response (each container is a top-level folder).
    public static func parseContainers(_ data: Data) -> Result {
        let delegate = Delegate(mode: .containers, prefix: "")
        parse(delegate, data)
        return Result(entries: delegate.entries, nextMarker: delegate.nextMarker)
    }

    private static func parse(_ delegate: Delegate, _ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
    }

    /// "prefix/sub/name" -> "name" (relative to the listed prefix, last segment only).
    static func relativeName(_ name: String, prefix: String) -> String {
        var rest = name
        if rest.hasPrefix(prefix) { rest.removeFirst(prefix.count) }
        if rest.hasSuffix("/") { rest.removeLast() }
        return String(rest.split(separator: "/").last ?? Substring(rest))
    }

    private static let rfc1123: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    static func date(_ s: String) -> Date? { rfc1123.date(from: s) }

    final class Delegate: NSObject, XMLParserDelegate {
        enum Mode { case blobs, containers }
        var entries: [FileEntry] = []
        var nextMarker: String?
        private let mode: Mode
        private let prefix: String

        private var text = ""
        private var inBlob = false
        private var inBlobPrefix = false
        private var inContainer = false
        private var name = ""
        private var size: Int64 = 0
        private var modified: Date?

        init(mode: Mode, prefix: String) {
            self.mode = mode
            self.prefix = prefix
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes: [String: String]
        ) {
            text = ""
            switch elementName {
            case "Blob": inBlob = true; name = ""; size = 0; modified = nil
            case "BlobPrefix": inBlobPrefix = true; name = ""
            case "Container": inContainer = true; name = ""; modified = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "Name" where inBlob || inBlobPrefix || inContainer: name = value
            case "Content-Length" where inBlob: size = Int64(value) ?? 0
            case "Last-Modified" where inBlob || inContainer: modified = AzureListParser.date(value)
            case "NextMarker": nextMarker = value.isEmpty ? nil : value
            case "Blob":
                inBlob = false
                // Skip the folder-marker blob whose name is exactly the prefix.
                if name != prefix {
                    entries.append(
                        FileEntry(
                            name: AzureListParser.relativeName(name, prefix: prefix),
                            isDirectory: false, size: size, modificationDate: modified))
                }
            case "BlobPrefix":
                inBlobPrefix = false
                let display = AzureListParser.relativeName(name, prefix: prefix)
                if !display.isEmpty {
                    entries.append(
                        FileEntry(name: display, isDirectory: true, size: 0, modificationDate: nil))
                }
            case "Container":
                inContainer = false
                if !name.isEmpty {
                    entries.append(
                        FileEntry(name: name, isDirectory: true, size: 0, modificationDate: modified))
                }
            default: break
            }
            text = ""
        }
    }
}
