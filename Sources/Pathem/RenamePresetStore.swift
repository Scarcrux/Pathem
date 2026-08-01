import Foundation
import PathemEngine

/// A named batch-rename rule the user saved (a find/replace + token template they reuse).
struct RenamePreset: Codable, Equatable {
    var name: String
    var rule: RenameRule
}

/// Persists batch-rename presets as JSON in Application Support (config-as-data, like the app's
/// other saved settings), so a favorite rule is one click away across launches.
@MainActor
enum RenamePresetStore {
    private static var url: URL? {
        BrowserViewController.appSupportDirectory()?.appendingPathComponent("rename-presets.json")
    }

    static func load() -> [RenamePreset] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RenamePreset].self, from: data)) ?? []
    }

    static func save(_ presets: [RenamePreset]) {
        guard let url, let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
