import Foundation

/// The resource bundle resolved for the user's preferred language. SwiftPM puts the
/// per-language `.strings` in `Bundle.module`, but its automatic lookup goes through
/// CFPreferences and ignores an explicit `-AppleLanguages` override. Resolving against
/// `Locale.preferredLanguages` honors the system language *and* an override (useful for
/// testing and a future in-app language picker), then we load that `.lproj` directly.
private let localizedBundle: Bundle = {
    let available = Bundle.module.localizations
    let preferred = Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages)
    if let code = preferred.first, code != Bundle.module.developmentLocalization,
        let path = Bundle.module.path(forResource: code, ofType: "lproj"),
        let bundle = Bundle(path: path)
    {
        return bundle
    }
    return Bundle.module
}()

/// A localized UI string from the app's resource bundle. Pass the English text as
/// `fallback` so an un-translated key still reads well.
///
/// Migrate user-facing strings to L(key, fallback) incrementally; add the key to
/// each Resources/<lang>.lproj/Localizable.strings.
func L(_ key: String, _ fallback: String) -> String {
    localizedBundle.localizedString(forKey: key, value: fallback, table: nil)
}
