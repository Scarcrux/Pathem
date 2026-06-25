import Foundation

/// Parses an S3 ListObjectsV2 XML response (with `delimiter=/`) into FileEntry rows:
/// `Contents` become files, `CommonPrefixes` become folders. Keys/prefixes are made
/// relative to the requested prefix to get display names, and the folder-marker object
/// equal to the prefix itself is skipped. Also returns the continuation token so the
/// provider can page. Pure, so it's unit-tested.
public enum S3ListParser {
    public struct Result: Sendable, Equatable {
        public let entries: [FileEntry]
        public let nextToken: String?
    }

    public static func parse(_ data: Data, prefix: String) -> Result {
        let delegate = Delegate(prefix: prefix)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return Result(
            entries: delegate.entries,
            nextToken: delegate.isTruncated ? delegate.nextToken : nil)
    }

    private static func isoFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = format
        return f
    }
    private static let isoFractional = isoFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX")
    private static let isoPlain = isoFormatter("yyyy-MM-dd'T'HH:mm:ssXXXXX")

    static func date(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// "prefix/sub/name" -> "name" (relative to the listed prefix, last segment only).
    static func relativeName(_ key: String, prefix: String) -> String {
        var rest = key
        if rest.hasPrefix(prefix) { rest.removeFirst(prefix.count) }
        if rest.hasSuffix("/") { rest.removeLast() }
        return String(rest.split(separator: "/").last ?? Substring(rest))
    }

    final class Delegate: NSObject, XMLParserDelegate {
        var entries: [FileEntry] = []
        var isTruncated = false
        var nextToken: String?
        private let prefix: String

        private var text = ""
        private var inContents = false
        private var inCommonPrefixes = false
        private var key = ""
        private var size: Int64 = 0
        private var modified: Date?

        init(prefix: String) { self.prefix = prefix }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes: [String: String]
        ) {
            text = ""
            switch elementName {
            case "Contents": inContents = true; key = ""; size = 0; modified = nil
            case "CommonPrefixes": inCommonPrefixes = true; key = ""
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
            case "Key" where inContents: key = value
            case "Size" where inContents: size = Int64(value) ?? 0
            case "LastModified" where inContents: modified = S3ListParser.date(value)
            case "Prefix" where inCommonPrefixes: key = value
            case "IsTruncated": isTruncated = (value == "true")
            case "NextContinuationToken": nextToken = value
            case "Contents":
                inContents = false
                // Skip the folder-marker object whose key is exactly the prefix.
                if key != prefix {
                    entries.append(
                        FileEntry(
                            name: S3ListParser.relativeName(key, prefix: prefix), isDirectory: false,
                            size: size, modificationDate: modified))
                }
            case "CommonPrefixes":
                inCommonPrefixes = false
                let name = S3ListParser.relativeName(key, prefix: prefix)
                if !name.isEmpty {
                    entries.append(FileEntry(name: name, isDirectory: true, size: 0, modificationDate: nil))
                }
            default: break
            }
            text = ""
        }
    }
}
