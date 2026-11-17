import Foundation
import Testing

@testable import PathemEngine

@Suite struct DiskImageTests {
    @Test func recognizesImageExtensions() {
        #expect(DiskImage.isDiskImage(URL(fileURLWithPath: "/x/App.dmg")))
        #expect(DiskImage.isDiskImage(URL(fileURLWithPath: "/x/backup.sparsebundle")))
        #expect(!DiskImage.isDiskImage(URL(fileURLWithPath: "/x/notes.txt")))
    }

    @Test func parsesMountPointFromHdiutilPlist() {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>system-entities</key>
              <array>
                <dict>
                  <key>content-hint</key><string>GUID_partition_scheme</string>
                  <key>dev-entry</key><string>/dev/disk4</string>
                </dict>
                <dict>
                  <key>dev-entry</key><string>/dev/disk4s1</string>
                  <key>mount-point</key><string>/Volumes/My App</string>
                </dict>
              </array>
            </dict>
            </plist>
            """
        let url = DiskImage.parseMountPoint(Data(xml.utf8))
        #expect(url?.path == "/Volumes/My App")
    }

    @Test func returnsNilWhenNoMountPoint() {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>system-entities</key><array>
            <dict><key>dev-entry</key><string>/dev/disk9</string></dict>
            </array></dict></plist>
            """
        #expect(DiskImage.parseMountPoint(Data(xml.utf8)) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func createsEncryptedImage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-dmg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("secret.txt")
        try Data("classified".utf8).write(to: file)

        let dmg = try await DiskImage.createEncrypted(
            from: [file], volumeName: "Vault", password: "hunter2", in: dir)
        #expect(FileManager.default.fileExists(atPath: dmg.path))
        #expect(dmg.lastPathComponent == "Vault.dmg")

        // hdiutil confirms the image is encrypted.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        check.arguments = ["isencrypted", dmg.path]
        let pipe = Pipe()
        let errors = Pipe()
        check.standardOutput = pipe
        check.standardError = errors
        try check.run()
        check.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // This failed once under heavy load (2026-11-16 and 11-17, 17 s instead of 4 s) with the
        // cause unknown; report what hdiutil said so the next failure names it.
        let stderr = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(
            output.contains("YES"),
            "hdiutil isencrypted exit=\(check.terminationStatus) stdout=\(output) stderr=\(stderr)")
    }
}
