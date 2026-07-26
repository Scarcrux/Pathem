import AppKit

/// Wires "Reveal in Pathem" into the JetBrains IDEs (IntelliJ, PyCharm, WebStorm, GoLand, … and
/// Android Studio) as an External Tools entry. Safe like the other editors: JetBrains reads every
/// `*.xml` in a profile's `tools/` folder as its own tool group, so Pathem writes a group it fully
/// owns -- `tools/Pathem.xml` -- into each installed profile, never merging into or touching the
/// user's own `External Tools.xml`. Remove deletes only those Pathem.xml files.
///
/// The tool runs the bundled `pathem-cli` with the raw file path, so the (tested) Swift CLI does the
/// URL encoding -- JetBrains External Tools split arguments themselves and can't percent-encode.
enum JetBrainsIntegration {
    static let name = "JetBrains IDEs"

    /// Bundle IDs used only for the "is it running" restart nudge.
    static let bundleIDs = [
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce", "com.jetbrains.WebStorm", "com.jetbrains.goland",
        "com.jetbrains.PhpStorm", "com.jetbrains.rubymine", "com.jetbrains.CLion",
        "com.jetbrains.datagrip", "com.jetbrains.rider", "com.jetbrains.rustrover",
        "com.google.android.studio",
    ]

    /// Every installed IDE profile's config dir. JetBrains profiles live under
    /// `~/Library/Application Support/JetBrains/<Product><version>`; Android Studio under
    /// `~/Library/Application Support/Google/AndroidStudio<version>`. Version-bearing names are the
    /// products; non-product dirs (Toolbox, consentOptions) are skipped.
    static func productDirectories() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        var dirs: [URL] = []
        func subdirs(of root: URL, keep: (String) -> Bool) {
            guard let subs = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return }
            for sub in subs where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if keep(sub.lastPathComponent) { dirs.append(sub) }
            }
        }
        subdirs(of: support.appendingPathComponent("JetBrains")) {
            $0.rangeOfCharacter(from: .decimalDigits) != nil  // a versioned product dir
        }
        subdirs(of: support.appendingPathComponent("Google")) { $0.hasPrefix("AndroidStudio") }
        return dirs
    }

    /// The Pathem-owned tool file inside a profile.
    static func toolFile(in profile: URL) -> URL {
        profile.appendingPathComponent("tools/Pathem.xml")
    }

    static func isEditorInstalled() -> Bool { !productDirectories().isEmpty }

    static func isEditorRunning() -> Bool {
        bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// Installed if any profile already has our tool file.
    static func isInstalled() -> Bool {
        productDirectories().contains { FileManager.default.fileExists(atPath: toolFile(in: $0).path) }
    }

    /// The absolute path to the bundled CLI the tool invokes (resolved from the running app, so it's
    /// correct wherever Pathem is installed; moving the app later means re-integrating).
    static func cliPath() -> String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pathem-cli").path
    }

    /// The (profile path, contents) we'll write -- one per installed IDE profile. Used for preview,
    /// install, and (as the set to delete) remove.
    static func plannedFiles() -> [(path: String, contents: String)] {
        let xml = toolXML(cliPath: cliPath())
        return productDirectories().map { (toolFile(in: $0).path, xml) }
    }

    static func install() throws { try install(into: productDirectories()) }

    /// Write `tools/Pathem.xml` into each given profile (atomically; creating `tools/` as needed).
    static func install(into profiles: [URL]) throws {
        guard !profiles.isEmpty else { throw EditorIntegrationError.editorDataMissing(editor: name) }
        let xml = toolXML(cliPath: cliPath())
        for profile in profiles {
            let file = toolFile(in: profile)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.data(using: .utf8)!.write(to: file, options: .atomic)
        }
    }

    static func remove() throws { try remove(from: productDirectories()) }

    /// Delete only our Pathem.xml from each profile; leaves `tools/` and the user's own tools intact.
    static func remove(from profiles: [URL]) throws {
        for profile in profiles {
            let file = toolFile(in: profile)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    /// A one-tool "Pathem" External Tools group: run `pathem-cli reveal "<file>"` on the current file.
    /// `$FilePath$` is quoted so a path with spaces stays a single argument (JetBrains parses the
    /// parameter string quote-aware after macro expansion).
    static func toolXML(cliPath: String) -> String {
        """
        <toolSet name="Pathem">
          <tool name="Reveal in Pathem" description="Select the current file in Pathem" showInMainMenu="false" showInEditor="true" showInProject="true" showInSearchPopup="false" disabled="false" useConsole="false" synchronizeAfterRun="true">
            <exec>
              <option name="COMMAND" value="\(xmlEscape(cliPath))" />
              <option name="PARAMETERS" value="reveal &quot;$FilePath$&quot;" />
              <option name="WORKING_DIRECTORY" value="$ProjectFileDir$" />
            </exec>
          </tool>
        </toolSet>
        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
