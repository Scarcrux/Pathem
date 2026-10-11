import Foundation

/// Parses a WebDAV PROPFIND (Depth: 1) "207 Multi-Status" XML body into FileEntry
/// rows. Namespace-agnostic (uses local element names), so it copes with d:/D:/no
/// prefix. The response for the collection itself (its href matches the requested
/// path) is skipped, leaving only its children. Pure, so it's unit-tested.
public enum WebDAVListParser {
    public static func parse(_ data: Data, requestPath: String) -> [FileEntry] {
        let delegate = Delegate(requestPath: requestPath)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true  // elementName becomes the local name
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    // Configured once, read-only. Preserve the older CI SDK fallback; the verified modern
    // toolchain checks DateFormatter Sendability without an unsafe declaration.
    #if compiler(>=6.4)
    private static let httpDate = makeHTTPDateFormatter()
    #else
    private nonisolated(unsafe) static let httpDate = makeHTTPDateFormatter()
    #endif

    private static func makeHTTPDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"  // RFC 1123, e.g. getlastmodified
        return f
    }

    /// Last path segment of an href (decoded), with any trailing slash removed.
    static func name(fromHref href: String) -> String {
        var path = href
        if let url = URL(string: href),
            let p = url.path.removingPercentEncoding ?? url.path as String?
        {
            path = p  // full URL form: take just the path
        } else {
            path = href.removingPercentEncoding ?? href
        }
        if path.hasSuffix("/") { path.removeLast() }
        return String(path.split(separator: "/").last ?? "")
    }

    /// Normalized path (decoded, no trailing slash) for "is this the collection itself?".
    static func normalizedPath(_ href: String) -> String {
        var path = href
        if let url = URL(string: href), !url.path.isEmpty { path = url.path }
        path = path.removingPercentEncoding ?? path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    final class Delegate: NSObject, XMLParserDelegate {
        var entries: [FileEntry] = []
        private let requestPath: String

        private var element = ""
        private var inResourcetype = false
        private var href = ""
        private var length: Int64 = 0
        private var lastModified: Date?
        private var isCollection = false
        private var text = ""

        init(requestPath: String) {
            self.requestPath = WebDAVListParser.normalizedPath(requestPath)
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes: [String: String]
        ) {
            element = elementName
            text = ""
            switch elementName {
            case "response":
                href = ""
                length = 0
                lastModified = nil
                isCollection = false
            case "resourcetype": inResourcetype = true
            case "collection": if inResourcetype { isCollection = true }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName {
            case "href": href = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "getcontentlength":
                length = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            case "getlastmodified":
                lastModified = WebDAVListParser.httpDate.date(
                    from: text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "resourcetype": inResourcetype = false
            case "response":
                let name = WebDAVListParser.name(fromHref: href)
                // Skip the collection itself and anything without a usable name.
                if !name.isEmpty, WebDAVListParser.normalizedPath(href) != requestPath {
                    entries.append(
                        FileEntry(
                            name: name, isDirectory: isCollection, size: isCollection ? 0 : length,
                            modificationDate: lastModified))
                }
            default: break
            }
            text = ""
        }
    }
}
