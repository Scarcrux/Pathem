import AppKit

/// Wires "Reveal in Pathem" into VS Code / Cursor. Unlike the other editors, their
/// Reveal target is locked and can't be redirected by a config edit, so Pathem ships
/// a tiny extension and installs it through the editor's own CLI. That CLI path is
/// the only reliable one: a folder dropped into `~/.vscode/extensions` is ignored by
/// modern VS Code (it trusts `extensions.json`). Install / Remove / Installed all go
/// through `<editor> --install-extension <vsix>` / `--uninstall-extension`, using the
/// CLI bundled *inside* the editor app so nothing has to be on PATH. Reversible.
enum VSCodeIntegration {
    static let extensionID = "scarcrux.pathem-reveal"
    /// Base name of the `.vsix` shipped in the app's resource bundle (see
    /// `scripts/build-vscode-extension.sh`).
    static let vsixName = "pathem-reveal-0.1.0"

    /// A VS Code-family editor (VS Code, Cursor). They share the extension model and
    /// CLI flags, differing only in identity and install locations.
    struct Flavor: Sendable {
        let name: String
        let bundleIDs: [String]
        let appPaths: [String]  // fallback locations if the bundle id lookup misses
        let cliName: String  // Contents/Resources/app/bin/<cliName>
        let extensionsSubpath: String  // home-relative extensions dir
    }

    static let vscode = Flavor(
        name: "VS Code",
        bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
        appPaths: ["/Applications/Visual Studio Code.app"],
        cliName: "code",
        extensionsSubpath: ".vscode/extensions")

    static let cursor = Flavor(
        name: "Cursor",
        bundleIDs: ["com.todesktop.230313mzl4w4u92"],
        appPaths: ["/Applications/Cursor.app"],
        cliName: "cursor",
        extensionsSubpath: ".cursor/extensions")

    // MARK: Locating the editor

    static func appURL(_ flavor: Flavor) -> URL? {
        for id in flavor.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        for path in flavor.appPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// The editor's bundled command-line tool (so no `code`/`cursor` need be on PATH).
    static func cliURL(_ flavor: Flavor) -> URL? {
        guard let app = appURL(flavor) else { return nil }
        let cli = app.appendingPathComponent("Contents/Resources/app/bin/\(flavor.cliName)")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }

    static func isEditorInstalled(_ flavor: Flavor) -> Bool { appURL(flavor) != nil }

    static func isEditorRunning(_ flavor: Flavor) -> Bool {
        flavor.bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    // MARK: Install state (filesystem check, so row refreshes stay cheap)

    private static func extensionsDirectory(_ flavor: Flavor) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(flavor.extensionsSubpath)
    }

    /// Installed when a `scarcrux.pathem-reveal-*` folder exists (the CLI creates one).
    /// Checking the folder avoids spawning `--list-extensions` on every panel redraw.
    static func isInstalled(_ flavor: Flavor) -> Bool {
        let dir = extensionsDirectory(flavor)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return entries.contains { $0.hasPrefix(extensionID + "-") }
    }

    static func bundledVSIX() -> URL? {
        pathemResourceBundle.url(forResource: vsixName, withExtension: "vsix")
    }

    // MARK: Actions

    static func install(_ flavor: Flavor) throws {
        guard let cli = cliURL(flavor) else { throw EditorIntegrationError.editorDataMissing(editor: flavor.name) }
        guard let vsix = bundledVSIX() else { throw VSCodeError.vsixMissing }
        try runCLI(cli, ["--install-extension", vsix.path, "--force"], editor: flavor.name)
    }

    static func remove(_ flavor: Flavor) throws {
        guard let cli = cliURL(flavor) else { return }  // editor is gone; nothing to remove
        try runCLI(cli, ["--uninstall-extension", extensionID], editor: flavor.name)
    }

    /// What the panel's Preview shows: a plain description, not the extension source,
    /// so this never has to stay byte-identical to the shipped `.vsix`.
    static func previewFiles(_ flavor: Flavor) -> [(path: String, contents: String)] {
        [(
            "\(extensionID) (\(flavor.name) extension)",
            String(
                format: L(
                    "integrations.vscodePreview",
                    "Installs the “Reveal in Pathem” extension into %@ via its command line:\n  %@ --install-extension %@.vsix\n\nAdds “Reveal in Pathem” to the Explorer, the editor tab menu, and the command palette. Remove uninstalls it cleanly."),
                flavor.name, flavor.cliName, vsixName)
        )]
    }

    private static func runCLI(_ cli: URL, _ arguments: [String], editor: String) throws {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw VSCodeError.cliFailed(editor: editor, output: error.localizedDescription)
        }
        // The CLI's output is small (a line or two), so reading after exit won't deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw VSCodeError.cliFailed(editor: editor, output: output)
        }
    }

    enum VSCodeError: LocalizedError {
        case vsixMissing
        case cliFailed(editor: String, output: String)
        var errorDescription: String? {
            switch self {
            case .vsixMissing:
                return L("integrations.vscodeVsixMissing", "The bundled extension isn’t available in this build.")
            case .cliFailed(let editor, let output):
                let base = String(format: L("integrations.vscodeCliFailed", "%@ couldn’t update the extension."), editor)
                return output.isEmpty ? base : "\(base)\n\n\(output)"
            }
        }
    }
}
