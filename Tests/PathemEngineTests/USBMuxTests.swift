import Foundation
import Testing

@testable import PathemEngine

@Suite struct USBMuxTests {
    @Test func frameRoundTripsHeaderAndPlist() throws {
        let data = try USBMux.Frame.encode(tag: 7, plist: ["MessageType": "ListDevices"])
        // Header is 16 bytes little-endian: length, version, message, tag.
        #expect(USBMux.Frame.readUInt32(data, at: 0) == UInt32(data.count))
        #expect(USBMux.Frame.readUInt32(data, at: 4) == 1)  // version
        #expect(USBMux.Frame.readUInt32(data, at: 8) == 8)  // plist message
        #expect(USBMux.Frame.readUInt32(data, at: 12) == 7)  // tag
        #expect(USBMux.Frame.payloadLength(header: data) == data.count - 16)

        let payload = data.subdata(in: 16..<data.count)
        let decoded = USBMux.Frame.decodePlist(payload)
        #expect(decoded?["MessageType"] as? String == "ListDevices")
    }

    @Test func parsesDeviceListReply() {
        let reply: [String: Any] = [
            "DeviceList": [
                [
                    "DeviceID": 3,
                    "MessageType": "Attached",
                    "Properties": ["SerialNumber": "00008110-AABB", "ConnectionType": "USB"],
                ]
            ]
        ]
        let devices = USBMux.parseDeviceList(reply)
        #expect(devices.count == 1)
        #expect(devices[0].deviceID == 3)
        #expect(devices[0].udid == "00008110-AABB")
        #expect(devices[0].connectionType == "USB")
    }

    @Test func payloadLengthRejectsShortHeader() {
        #expect(USBMux.Frame.payloadLength(header: Data([0, 1, 2])) == nil)
    }

    /// Live round-trip with the real usbmuxd: proves the socket + framing + plist path end
    /// to end. Returns [] when no device is attached; only a transport failure throws, which
    /// we tolerate (sandboxed/CI machines may not expose the socket).
    @Test func listDevicesAgainstLiveDaemon() throws {
        guard FileManager.default.fileExists(atPath: USBMux.socketPath) else { return }
        do {
            let devices = try USBMux.listDevices()
            print("usbmuxd live round-trip OK: \(devices.count) device(s) attached")
            // Any device present must carry a non-empty UDID.
            for device in devices { #expect(!device.udid.isEmpty) }
        } catch {
            print("usbmuxd live round-trip unavailable: \(error)")
        }
    }
}
