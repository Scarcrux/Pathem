import Foundation

/// Assigns local destinations for one batch before any provider begins writing.
public struct RemoteDownloadDestination {
    private let directory: URL
    private let caseSensitive: Bool
    private var reserved: Set<String> = []

    public init(in directory: URL) {
        self.directory = directory
        caseSensitive =
            (try? directory.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
            == true
    }

    public mutating func reserve(for remoteName: String) -> URL? {
        guard let name = Self.safeLocalName(remoteName) else { return nil }
        let target = Self.uniqueLocalURL(directory.appendingPathComponent(name)) {
            reserved.contains(reservationKey($0))
        }
        reserved.insert(reservationKey(target.lastPathComponent))
        return target
    }

    private func reservationKey(_ name: String) -> String {
        // Swift strings already compare canonically equivalent Unicode spellings.
        caseSensitive ? name : name.folding(options: .caseInsensitive, locale: nil)
    }

    public static func safeLocalName(_ raw: String) -> String? {
        let base = (raw.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        guard !base.isEmpty, base != ".", base != "..", !base.contains("/"),
            !base.utf8.contains(0)
        else { return nil }
        return base
    }

    public static func uniqueLocalURL(_ url: URL) -> URL {
        uniqueLocalURL(url, isReserved: { _ in false })
    }

    private static func uniqueLocalURL(_ url: URL, isReserved: (String) -> Bool) -> URL {
        func occupied(_ candidate: URL) -> Bool {
            var info = stat()
            return isReserved(candidate.lastPathComponent) || lstat(candidate.path, &info) == 0
        }
        guard occupied(url) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !occupied(candidate) { return candidate }
            n += 1
        }
    }
}
