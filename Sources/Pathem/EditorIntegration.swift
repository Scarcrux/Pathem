import AppKit

/// Shared failure for a per-editor integration. Its data dir is missing only when the editor has
/// never been launched, so the fix is to open it once.
enum EditorIntegrationError: LocalizedError {
    case editorDataMissing(editor: String)
    var errorDescription: String? {
        switch self {
        case .editorDataMissing(let editor):
            return String(
                format: L("integrations.editorNoData", "%@’s settings folder wasn’t found. Open %@ once, then try again."),
                editor, editor)
        }
    }
}

/// A reversible editor integration shown in Settings ▸ Integrations. Every one writes only into a
/// folder Pathem fully owns (never merging into the user's own config), so Remove is a clean delete.
/// Each entry just forwards to a concrete integration (`SublimeIntegration`, `TextMateIntegration`),
/// so the settings pane can drive them all through one loop.
struct EditorIntegration: Sendable {
    let id: String
    let name: String
    let isEditorInstalled: @Sendable () -> Bool
    let isEditorRunning: @Sendable () -> Bool
    let isInstalled: @Sendable () -> Bool
    let previewFiles: @Sendable () -> [(path: String, contents: String)]
    let install: @Sendable () throws -> Void
    let remove: @Sendable () throws -> Void

    /// Every integration Pathem can wire, in display order.
    static let all: [EditorIntegration] = [sublime, textMate, jetBrains]

    static let sublime = EditorIntegration(
        id: "sublime", name: SublimeIntegration.name,
        isEditorInstalled: { SublimeIntegration.isEditorInstalled() },
        isEditorRunning: { SublimeIntegration.isEditorRunning() },
        isInstalled: { SublimeIntegration.isInstalled() },
        previewFiles: {
            let base = SublimeIntegration.packageDirectory()
            return SublimeIntegration.files().map { (base?.appendingPathComponent($0.name).path ?? $0.name, $0.contents) }
        },
        install: { try SublimeIntegration.install() },
        remove: { try SublimeIntegration.remove() })

    static let textMate = EditorIntegration(
        id: "textmate", name: TextMateIntegration.name,
        isEditorInstalled: { TextMateIntegration.isEditorInstalled() },
        isEditorRunning: { TextMateIntegration.isEditorRunning() },
        isInstalled: { TextMateIntegration.isInstalled() },
        previewFiles: {
            let base = TextMateIntegration.ownedDirectory()
            return TextMateIntegration.files().map { (base?.appendingPathComponent($0.name).path ?? $0.name, $0.contents) }
        },
        install: { try TextMateIntegration.install() },
        remove: { try TextMateIntegration.remove() })

    static let jetBrains = EditorIntegration(
        id: "jetbrains", name: JetBrainsIntegration.name,
        isEditorInstalled: { JetBrainsIntegration.isEditorInstalled() },
        isEditorRunning: { JetBrainsIntegration.isEditorRunning() },
        isInstalled: { JetBrainsIntegration.isInstalled() },
        previewFiles: { JetBrainsIntegration.plannedFiles() },
        install: { try JetBrainsIntegration.install() },
        remove: { try JetBrainsIntegration.remove() })
}
