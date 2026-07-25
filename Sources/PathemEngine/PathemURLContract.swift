import Foundation

/// The stable `pathem://` URL seam that every Finder-handoff integration speaks: the `pathem` CLI
/// (and any editor plugin) builds one of these, and the app parses it. Keeping the scheme, verbs,
/// and query in one place means the launch logic can change without touching any editor config.
///
///   pathem://open?path=/abs/dir     -> navigate the active pane INTO that folder (or view a file)
///   pathem://reveal?path=/abs/item  -> select the item in its PARENT folder (file or folder alike)
public enum PathemURLContract {
    public static let scheme = "pathem"

    public enum Verb: String, Sendable {
        case open
        case reveal
    }

    /// Build a `pathem://<verb>?path=<path>` URL. `path` should be an absolute filesystem path.
    public static func url(verb: Verb, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = verb.rawValue
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    /// Parse an incoming URL into its (verb, path), or nil if it isn't a well-formed `pathem://` URL.
    /// The scheme and verb are matched case-insensitively (LaunchServices may not preserve case), and
    /// only an absolute `path` is accepted -- a relative one is meaningless here (it would resolve
    /// against the app's working directory) and is rejected rather than acted on.
    public static func parse(_ url: URL) -> (verb: Verb, path: String)? {
        guard url.scheme?.lowercased() == scheme,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let verb = (components.host?.lowercased()).flatMap(Verb.init(rawValue:)),
            let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
            path.hasPrefix("/")
        else { return nil }
        return (verb, path)
    }
}
