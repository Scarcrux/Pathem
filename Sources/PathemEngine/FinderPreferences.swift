import Foundation

/// Reads the user's Finder / global preferences and maps them to the Pathem settings that have a
/// direct equivalent, for the "Match Finder" action. Non-sandboxed apps can read these domains.
/// The mapping helpers are pure so they unit-test; `fromSystem` just reads the live domains.
public enum FinderPreferences {
    /// The Pathem settings derived from Finder. A nil field means Finder has no readable opinion, so
    /// Match Finder leaves that Pathem setting untouched.
    public struct Matched: Equatable, Sendable {
        public var showHidden: Bool?
        public var foldersFirst: Bool?
        public var defaultView: ViewFormat.ViewMode?
        public init(
            showHidden: Bool? = nil, foldersFirst: Bool? = nil,
            defaultView: ViewFormat.ViewMode? = nil
        ) {
            self.showHidden = showHidden
            self.foldersFirst = foldersFirst
            self.defaultView = defaultView
        }
    }

    /// Map raw Finder/global values to Pathem settings (the testable core).
    public static func matched(showAllFiles: Any?, sortFoldersFirst: Any?, viewStyle: Any?)
        -> Matched
    {
        Matched(
            showHidden: boolValue(showAllFiles),
            foldersFirst: boolValue(sortFoldersFirst),
            defaultView: viewMode(from: viewStyle as? String))
    }

    /// Read the live Finder domain (`AppleShowAllFiles`, `_FXSortFoldersFirst`, `FXPreferredViewStyle`).
    public static func fromSystem() -> Matched {
        let finder = UserDefaults(suiteName: "com.apple.finder")
        return matched(
            showAllFiles: finder?.object(forKey: "AppleShowAllFiles"),
            sortFoldersFirst: finder?.object(forKey: "_FXSortFoldersFirst"),
            viewStyle: finder?.object(forKey: "FXPreferredViewStyle"))
    }

    /// Finder stores booleans as an NSNumber (the checkbox) or the strings "YES"/"NO"/"1"/"0"
    /// (a Terminal `defaults write`). Normalize to a Bool, or nil when the key is absent/unreadable.
    public static func boolValue(_ raw: Any?) -> Bool? {
        switch raw {
        case let n as NSNumber: return n.boolValue  // a real Bool from UserDefaults arrives as NSNumber
        case let b as Bool: return b
        case let s as String:
            let lower = s.lowercased()
            if ["1", "yes", "true"].contains(lower) { return true }
            if ["0", "no", "false"].contains(lower) { return false }
            return nil
        default: return nil
        }
    }

    /// Map Finder's `FXPreferredViewStyle` four-char code to a Pathem view mode. Tree has no Finder
    /// equivalent, so it's never produced here; an unknown code yields nil (left untouched).
    public static func viewMode(from style: String?) -> ViewFormat.ViewMode? {
        switch style {
        case "icnv": return .icon
        case "Nlsv": return .list
        case "clmv": return .column
        case "glyv": return .gallery
        default: return nil
        }
    }
}
