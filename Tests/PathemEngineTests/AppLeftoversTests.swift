import Foundation
import Testing

@testable import PathemEngine

@Suite struct AppLeftoversTests {
    @Test func findsSupportFilesByBundleIdAndName() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pathem-leftovers-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }

        // A fake app bundle with a bundle identifier.
        let app = home.appendingPathComponent("Applications/Foo.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.test.foo</string>
            </dict></plist>
            """
        try plist.data(using: .utf8)!.write(to: app.appendingPathComponent("Contents/Info.plist"))

        // Leftovers: id-based (caches, prefs) and name-based (App Support).
        let lib = home.appendingPathComponent("Library")
        try fm.createDirectory(at: lib.appendingPathComponent("Caches/com.test.foo"), withIntermediateDirectories: true)
        try Data(count: 1234).write(to: lib.appendingPathComponent("Caches/com.test.foo/blob"))
        try fm.createDirectory(at: lib.appendingPathComponent("Preferences"), withIntermediateDirectories: true)
        try Data().write(to: lib.appendingPathComponent("Preferences/com.test.foo.plist"))
        try fm.createDirectory(at: lib.appendingPathComponent("Application Support/Foo"), withIntermediateDirectories: true)

        let found = AppLeftovers.find(forApp: app, home: home).map { ($0.path as NSString).lastPathComponent }
        #expect(found.contains("com.test.foo"))  // Caches/com.test.foo
        #expect(found.contains("com.test.foo.plist"))  // Preferences
        #expect(found.contains("Foo"))  // Application Support/Foo (name-based)
    }

    @Test func noBundleIdStillMatchesByName() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("pathem-leftovers-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let app = home.appendingPathComponent("Bar.app")  // no Info.plist
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: home.appendingPathComponent("Library/Logs/Bar"), withIntermediateDirectories: true)
        let found = AppLeftovers.find(forApp: app, home: home).map { ($0.path as NSString).lastPathComponent }
        #expect(found == ["Bar"])
    }
}
