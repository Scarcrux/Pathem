import Foundation

/// Literal file search. Folder scopes are independent of Spotlight; whole-Mac search uses
/// the OS index rather than reading every disk. Limits and omissions travel with the results.
public enum FileSearch {
    public typealias IndexedSearch = @Sendable (Request, URL?, Int) async -> Response
    public enum Mode: Sendable { case filename, contents }
    public enum Scope: Sendable, Equatable {
        case folder(URL, recursive: Bool)
        case mac
    }
    public struct Request: Sendable {
        public let keyword: String
        public let mode: Mode
        public let scope: Scope
        public init(keyword: String, mode: Mode, scope: Scope) {
            self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            self.mode = mode
            self.scope = scope
        }
    }
    public struct Response: Sendable {
        public var urls: [URL]
        public var truncated: Bool
        public var skipped: Int
        public var error: String?
        public var indexedDocumentsUnavailable: Bool
        public init(
            urls: [URL] = [], truncated: Bool = false, skipped: Int = 0, error: String? = nil,
            indexedDocumentsUnavailable: Bool = false
        ) {
            self.urls = urls
            self.truncated = truncated
            self.skipped = skipped
            self.error = error
            self.indexedDocumentsUnavailable = indexedDocumentsUnavailable
        }
    }

    public static func search(
        _ request: Request, limit: Int = 500,
        indexedSearch: @escaping IndexedSearch = { request, scope, limit in
            await SpotlightSearch.fileSearch(request, scope: scope, limit: limit)
        }
    ) async -> Response {
        guard !request.keyword.isEmpty else { return Response() }
        switch request.scope {
        case .mac:
            var response = sorted(await indexedSearch(request, nil, limit))
            let boundedLimit = max(0, limit)
            if response.urls.count > boundedLimit {
                response.truncated = true
                response.urls = Array(response.urls.prefix(boundedLimit))
            }
            return response
        case .folder(let root, let recursive):
            let worker = Task.detached(priority: .userInitiated) {
                scan(request, root: root, recursive: recursive, limit: limit)
            }
            var response = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            // Direct text scanning covers unindexed files. Spotlight adds PDF/Office and other
            // importer-supported document contents, without reading online-only file bytes.
            if request.mode == .contents, response.error == nil, !Task.isCancelled {
                let indexed = await indexedSearch(request, root, limit)
                response.indexedDocumentsUnavailable = indexed.error != nil
                let rootPath = root.standardizedFileURL.path
                let prefix = rootPath == "/" ? "/" : rootPath + "/"
                let scoped = indexed.urls.filter { url in
                    let path = url.standardizedFileURL.path
                    guard path.hasPrefix(prefix) else { return false }
                    let relative = String(path.dropFirst(prefix.count))
                    if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                        return false
                    }
                    // An indexed document can sit *under* a package or symlink even
                    // when the leaf itself is ordinary. Match the direct traversal's
                    // boundary at every ancestor, stopping before the explicit root.
                    var ancestor = url.standardizedFileURL
                    while ancestor.path != rootPath {
                        let values = try? ancestor.resourceValues(forKeys: [
                            .isSymbolicLinkKey, .isPackageKey,
                        ])
                        if values?.isSymbolicLink == true || values?.isPackage == true {
                            return false
                        }
                        let parent = ancestor.deletingLastPathComponent()
                        guard parent.path != ancestor.path else { return false }
                        ancestor = parent
                    }
                    return recursive
                        || url.deletingLastPathComponent().standardizedFileURL.path == rootPath
                }
                response.urls = Array(Set(response.urls + scoped))
                response = sorted(response)
                response.truncated =
                    response.truncated || indexed.truncated || response.urls.count > limit
                response.urls = Array(response.urls.prefix(max(0, limit)))
            }
            return response
        }
    }

    /// Literal substring, not a glob or regex; names such as `notes[1]*.txt` stay literal.
    public static func contains(_ text: String, keyword: String) -> Bool {
        text.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func scan(_ request: Request, root: URL, recursive: Bool, limit: Int) -> Response
    {
        var response = Response()
        var folders = [root]
        var examined = 0
        while let folder = folders.popLast() {
            if Task.isCancelled { return Response() }
            let entries: [FileEntry]
            do { entries = try BulkEnumerator().entries(of: folder, includingHidden: false) } catch
            {
                if folder == root {
                    response.error = error.localizedDescription
                    return response
                }
                response.skipped += 1
                continue
            }
            for entry in entries {
                if Task.isCancelled { return Response() }
                examined += 1
                if examined > 200_000 {
                    response.truncated = true
                    return sorted(response)
                }
                let url = folder.appendingPathComponent(entry.name)
                // Never follow symlinks, package internals or online-only folders out of scope.
                let values = try? url.resourceValues(forKeys: [
                    .isSymbolicLinkKey, .isPackageKey, .isRegularFileKey,
                ])
                if recursive, entry.isDirectory, entry.isDataless { response.skipped += 1 }
                if recursive, entry.isDirectory, !entry.isDataless,
                    values?.isSymbolicLink != true, values?.isPackage != true
                {
                    folders.append(url)
                }
                let matches: Bool
                switch request.mode {
                case .filename:
                    matches = contains(entry.name, keyword: request.keyword)
                case .contents:
                    guard !entry.isDirectory, values?.isSymbolicLink != true,
                        values?.isRegularFile == true
                    else { continue }
                    if entry.isDataless {
                        response.skipped += 1
                        continue
                    }
                    do {
                        let result = try textContains(url, keyword: request.keyword)
                        matches = result.matches
                        if result.limited { response.skipped += 1 }
                    } catch {
                        response.skipped += 1
                        continue
                    }
                }
                if matches {
                    if response.urls.count >= max(0, limit) {
                        response.truncated = true
                        return sorted(response)
                    }
                    response.urls.append(url)
                }
            }
        }
        return sorted(response)
    }

    private static func sorted(_ response: Response) -> Response {
        var response = response
        response.urls.sort {
            let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        return response
    }

    // Bounded streaming UTF-8 text search, including matches crossing a read boundary.
    // Binary files are not interpreted as text. No whole-file allocation or cloud downloads.
    private static func textContains(_ url: URL, keyword: String) throws -> (
        matches: Bool, limited: Bool
    ) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let overlap = max(256, keyword.utf8.count * 4)
        var tail = Data()
        var bytes = 0
        while !Task.isCancelled {
            guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else {
                return (false, false)
            }
            if chunk.contains(0) { return (false, false) }
            bytes += chunk.count
            let combined = tail + chunk
            if contains(String(decoding: combined, as: UTF8.self), keyword: keyword) {
                return (true, false)
            }
            tail = combined.suffix(overlap)
            if bytes >= 32 * 1024 * 1024 { return (false, true) }
        }
        return (false, false)
    }
}
