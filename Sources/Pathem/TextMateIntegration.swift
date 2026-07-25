import AppKit

/// Wires "Reveal in Pathem" into TextMate as a bundle command. Like the Sublime integration, it
/// writes only into a folder Pathem fully owns -- `…/TextMate/Bundles/Pathem.tmbundle/` -- so it
/// never touches the user's own bundles and Remove is a clean delete. The command drives the app
/// through the `pathem://reveal` URL scheme (encoding the path with Ruby's ERB, which macOS ships),
/// so it needs no PATH or CLI knowledge.
enum TextMateIntegration {
    static let name = "TextMate"
    static let bundleIDs = ["com.macromates.TextMate"]

    // Fixed identifiers so a reinstall updates the same bundle rather than spawning duplicates.
    private static let bundleUUID = "5E7C1A20-9D3B-4F62-8A11-A1B2C3D4E5F6"
    private static let commandUUID = "5E7C1A20-9D3B-4F62-8A11-A1B2C3D4E5F7"

    /// TextMate's data directory, or nil if it has never been set up.
    static func dataDirectory() -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TextMate")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return base
    }

    /// The Pathem-owned bundle folder (present only when TextMate's data dir exists).
    static func ownedDirectory() -> URL? {
        dataDirectory()?.appendingPathComponent("Bundles/Pathem.tmbundle")
    }

    static func isEditorInstalled() -> Bool {
        bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    static func isEditorRunning() -> Bool {
        bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    static func isInstalled() -> Bool {
        guard let dir = ownedDirectory() else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("info.plist").path)
    }

    /// The files we write, as (relative path, contents). Pure, so it can be previewed and tested.
    static func files() -> [(name: String, contents: String)] {
        [
            ("info.plist", infoPlist),
            ("Commands/Reveal in Pathem.tmCommand", revealCommand),
        ]
    }

    static func install(into directory: URL? = ownedDirectory()) throws {
        guard let directory else { throw EditorIntegrationError.editorDataMissing(editor: name) }
        for file in files() {
            let url = directory.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.data(using: .utf8)!.write(to: url, options: .atomic)
        }
    }

    static func remove(at directory: URL? = ownedDirectory()) throws {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - File contents

    private static let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>name</key>
        \t<string>Pathem</string>
        \t<key>ordering</key>
        \t<array>
        \t\t<string>\(commandUUID)</string>
        \t</array>
        \t<key>uuid</key>
        \t<string>\(bundleUUID)</string>
        </dict>
        </plist>
        """

    // A "none in / discard out" command bound to the current file. Ruby's ERB::Util.url_encode gives
    // correct percent-encoding (spaces -> %20), which the app's URLComponents parser decodes back.
    private static let revealCommand = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>command</key>
        \t<string>#!/usr/bin/ruby
        require 'erb'
        path = ENV['TM_FILEPATH']
        if path &amp;&amp; !path.empty?
          system('/usr/bin/open', "pathem://reveal?path=#{ERB::Util.url_encode(path)}")
        end
        </string>
        \t<key>input</key>
        \t<string>none</string>
        \t<key>name</key>
        \t<string>Reveal in Pathem</string>
        \t<key>outputLocation</key>
        \t<string>discard</string>
        \t<key>uuid</key>
        \t<string>\(commandUUID)</string>
        \t<key>version</key>
        \t<integer>2</integer>
        </dict>
        </plist>
        """
}
