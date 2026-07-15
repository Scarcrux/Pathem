import AppKit
import UniformTypeIdentifiers

/// Orders the "Open With" apps by how well each actually fits the file's type.
///
/// LaunchServices hands back the candidate apps in an arbitrary order, so an app that only claims a
/// catch-all like `public.data` ("I open anything") -- Illustrator for a `.txt` -- can sit as high
/// as the right editor. We read each app's own document-type declarations and tier them by how well
/// they fit: an exact-type (or exact-extension) claim beats a real supertype, which beats a
/// catch-all. Within a tier, editors edge out viewers, then it is alphabetical. We deliberately do
/// NOT use LSHandlerRank: apps game it (Microsoft Word declares itself a high-rank PDF handler),
/// which would float them above the app that actually fits. The OS's chosen default is always
/// pinned first; the OS still decides which apps *can* open the file and which is default -- we only
/// order the rest sensibly. The scoring is split from the Info.plist reading so it is unit-testable.
enum OpenWithRanker {
    struct Claim {
        var types: [UTType]  // LSItemContentTypes
        var extensions: [String]  // legacy CFBundleTypeExtensions (lowercased; "*" = any)
        var editor: Bool
    }

    /// The default app first, then the rest best-fit, ties broken by name.
    static func ranked(apps: [URL], for url: URL, defaultApp: URL?) -> [URL] {
        let fileType =
            (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let ext = url.pathExtension.lowercased()
        var rest =
            apps
            .filter { $0 != defaultApp }
            .map { (app: $0, fit: score(claims(of: $0), fileType: fileType, ext: ext)) }
            .sorted {
                $0.fit != $1.fit
                    ? $0.fit > $1.fit
                    : displayName($0.app).localizedStandardCompare(displayName($1.app)) == .orderedAscending
            }
            .map(\.app)
        if let defaultApp { rest.insert(defaultApp, at: 0) }
        return rest
    }

    /// The best fit across all of an app's document-type claims. Pure, so it is unit-tested.
    /// Tier: exact type or exact extension (30) > a real supertype like public.text (20) > a
    /// catch-all / "*" (10); +1 if the claim is an Editor rather than a Viewer.
    static func score(_ claims: [Claim], fileType: UTType, ext: String) -> Int {
        let catchAlls: Set<UTType> = [.data, .item, .content, .compositeContent]
        var best = 0
        for claim in claims {
            var tier = 0
            for t in claim.types {
                if t == fileType { tier = max(tier, 30) } else if fileType.conforms(to: t) {
                    tier = max(tier, catchAlls.contains(t) ? 10 : 20)
                }
            }
            if !ext.isEmpty {
                if claim.extensions.contains(ext) {
                    tier = max(tier, 30)
                } else if claim.extensions.contains("*") {
                    tier = max(tier, 10)
                }
            }
            guard tier > 0 else { continue }
            best = max(best, tier + (claim.editor ? 1 : 0))
        }
        return best
    }

    private static func claims(of app: URL) -> [Claim] {
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
            let docs = plist["CFBundleDocumentTypes"] as? [[String: Any]]
        else { return [] }
        return docs.map { dt in
            Claim(
                types: (dt["LSItemContentTypes"] as? [String] ?? []).compactMap { UTType($0) },
                extensions: (dt["CFBundleTypeExtensions"] as? [String] ?? []).map { $0.lowercased() },
                editor: (dt["CFBundleTypeRole"] as? String)?.lowercased() == "editor")
        }
    }

    private static func displayName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path)
    }
}
