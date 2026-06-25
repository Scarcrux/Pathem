import Foundation

private final class BundleToken {}

/// The SwiftPM resource bundle, located defensively. `Bundle.module` traps
/// (fatalError) if it can't find the bundle — e.g. when the app is launched mid-install
/// while package.sh is still copying it — which crashes the whole app at launch. We
/// locate the bundle ourselves and fall back to the main bundle (so `L` returns its
/// English fallback) rather than crashing.
private let resourceBundle: Bundle = {
    let bundleName = "Pathem_Pathem.bundle"
    let candidates = [
        Bundle.main.resourceURL,  // a packaged .app: Contents/Resources
        Bundle.main.bundleURL,  // a plain executable (swift run): next to the binary
        Bundle(for: BundleToken.self).resourceURL,
        Bundle(for: BundleToken.self).bundleURL,
    ]
    for case let directory? in candidates {
        if let bundle = Bundle(url: directory.appendingPathComponent(bundleName)) { return bundle }
    }
    return .main
}()

/// The bundle for the user's preferred language (the matching `.lproj` in the resource
/// bundle), resolved against `Locale.preferredLanguages` so it honors the system
/// language and an `-AppleLanguages` override. Falls back to the resource bundle.
private let localizedBundle: Bundle = {
    let available = resourceBundle.localizations
    let preferred = Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages)
    if let code = preferred.first, code != resourceBundle.developmentLocalization,
        let path = resourceBundle.path(forResource: code, ofType: "lproj"),
        let bundle = Bundle(path: path)
    {
        return bundle
    }
    return resourceBundle
}()

/// A localized UI string. Pass the English text as `fallback` so an un-translated key
/// (or a missing resource bundle) still reads well.
///
/// Migrate user-facing strings to L(key, fallback) incrementally; add the key to
/// each Resources/<lang>.lproj/Localizable.strings.
func L(_ key: String, _ fallback: String) -> String {
    localizedBundle.localizedString(forKey: key, value: fallback, table: nil)
}
