import AppKit

/// Wires "Reveal in Pathem" into Sublime Text, the safe way: everything Pathem writes lives in a
/// package folder Pathem fully owns -- `…/Sublime Text/Packages/Pathem/` -- so it never merges into
/// or clobbers the user's own config, and removal is a clean delete of that one folder. The plugin
/// drives the app through the `pathem://reveal` URL scheme, so it needs neither the `pathem` CLI on
/// PATH nor any launch-path knowledge.
enum SublimeIntegration {
    static let name = "Sublime Text"
    static let bundleIDs = ["com.sublimetext.4", "com.sublimetext.3"]

    /// Sublime's data directory, or nil if it has never been set up (so we don't fabricate a tree).
    static func dataDirectory() -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sublime Text")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return base
    }

    /// The Pathem-owned package folder. Present only when Sublime's data dir exists.
    static func packageDirectory() -> URL? {
        dataDirectory()?.appendingPathComponent("Packages/Pathem")
    }

    /// Sublime is installed if any of its bundle IDs resolves to an app on disk.
    static func isEditorInstalled() -> Bool {
        bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    /// Whether Sublime is currently running (so we can warn: it reloads packages on launch).
    static func isEditorRunning() -> Bool {
        bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// True once our plugin file is present in the owned package folder.
    static func isInstalled() -> Bool {
        guard let dir = packageDirectory() else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("pathem_reveal.py").path)
    }

    /// The files we write, as (relative name, contents). Pure, so it can be previewed and tested.
    static func files() -> [(name: String, contents: String)] {
        [
            ("pathem_reveal.py", pluginSource),
            ("Side Bar.sublime-menu", sidebarMenu),
            ("Context.sublime-menu", contextMenu),
            ("Default.sublime-commands", commandPalette),
        ]
    }

    /// Write the integration into `directory` (defaults to the real owned package folder). Atomic
    /// per file; creates the folder if needed. Only ever touches files inside `directory`.
    static func install(into directory: URL? = packageDirectory()) throws {
        guard let directory else { throw IntegrationError.editorDataMissing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files() {
            let url = directory.appendingPathComponent(file.name)
            try file.contents.data(using: .utf8)!.write(to: url, options: .atomic)
        }
    }

    /// Remove the integration by deleting the owned folder (and nothing else).
    static func remove(at directory: URL? = packageDirectory()) throws {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    enum IntegrationError: LocalizedError {
        case editorDataMissing
        var errorDescription: String? {
            L("integrations.sublime.noData", "Sublime Text’s settings folder wasn’t found. Launch Sublime Text once, then try again.")
        }
    }

    // MARK: - File contents

    /// The Sublime plugin: a "pathem reveal" command for the current file and the sidebar selection,
    /// driving Pathem via the pathem:// URL scheme (no PATH or CLI dependency).
    private static let pluginSource = """
        # Added by Pathem (Settings > Integrations). Reveals a file in Pathem via the pathem:// URL
        # scheme. Remove it from Pathem's Integrations pane, or just delete this Packages/Pathem folder.
        import sublime_plugin
        import subprocess
        import urllib.parse


        def _reveal(path):
            if not path:
                return
            url = "pathem://reveal?path=" + urllib.parse.quote(path, safe="")
            subprocess.Popen(["/usr/bin/open", url])


        class PathemRevealCommand(sublime_plugin.TextCommand):
            def run(self, edit):
                _reveal(self.view.file_name())

            def is_enabled(self):
                return bool(self.view.file_name())


        class PathemRevealSidebarCommand(sublime_plugin.WindowCommand):
            def run(self, paths):
                if paths:
                    _reveal(paths[0])

            def is_visible(self, paths):
                return len(paths) > 0
        """

    private static let sidebarMenu = """
        [
            { "caption": "Reveal in Pathem", "command": "pathem_reveal_sidebar", "args": { "paths": [] } }
        ]
        """

    private static let contextMenu = """
        [
            { "caption": "Reveal in Pathem", "command": "pathem_reveal" }
        ]
        """

    private static let commandPalette = """
        [
            { "caption": "Pathem: Reveal Current File", "command": "pathem_reveal" }
        ]
        """
}
