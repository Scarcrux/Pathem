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
}
