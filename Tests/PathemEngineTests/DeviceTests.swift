import Foundation
import Testing

@testable import PathemEngine

@Suite struct DeviceTests {
    @Test func parsesAdbDevices() {
        let out = """
            List of devices attached
            ABCD1234\tdevice usb:1-1 product:panther model:Pixel_7 device:panther transport_id:1
            emulator-5554\tdevice product:sdk_gphone64 model:sdk_gphone64_arm64 device:emu64a transport_id:2
            9A271FFAZ\tunauthorized
            00FF\toffline
            """
        let devices = DeviceDiscovery.parseADBDevices(out)
        #expect(devices.count == 2)  // unauthorized + offline dropped
        #expect(devices[0].serial == "ABCD1234")
        #expect(devices[0].model == "Pixel 7")  // underscores become spaces
        #expect(devices[1].serial == "emulator-5554")
        #expect(devices[1].model == "sdk gphone64 arm64")
    }

    @Test func parsesUDIDs() {
        let out = "00008110-0011223344556677\n00008030-AABBCCDDEEFF0011 (USB)\n\n"
        let udids = DeviceDiscovery.parseUDIDs(out)
        #expect(udids == ["00008110-0011223344556677", "00008030-AABBCCDDEEFF0011"])
    }

    @Test func adbListParserMarksDirectoriesAndStripsCR() {
        // adb shell appends CR to each line; -p marks directories with a trailing slash.
        let out = "./\r\n../\r\nDCIM/\r\nDownload/\r\nphoto.jpg\r\nnotes.txt\r\n"
        let entries = ADBListParser.parse(out, location: "/sdcard")
        #expect(entries.count == 4)  // . and .. dropped
        #expect(entries[0].name == "DCIM")
        #expect(entries[0].isDirectory)
        #expect(entries[2].name == "photo.jpg")
        #expect(!entries[2].isDirectory)
        #expect(entries[2].location == "/sdcard")
    }

    @Test func deviceProtosAreMarkedAsDevices() {
        #expect(RemoteConnection.Proto.adb.isDevice)
        #expect(RemoteConnection.Proto.afc.isDevice)
        #expect(!RemoteConnection.Proto.sftp.isDevice)
        #expect(RemoteConnection.Proto.adb.defaultPort == 0)
    }
}
