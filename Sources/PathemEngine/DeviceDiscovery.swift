import Foundation

/// Discovers USB-attached phones and models each as a `RemoteConnection` (proto .adb/.afc,
/// serial/UDID in `host`) so the existing provider seam browses them. Android uses `adb`
/// (when installed); iOS uses our own usbmux client (no third-party tool). The friendly iOS
/// name is resolved separately/out-of-process by the app. The output parser is pure-tested.
public enum DeviceDiscovery {
    /// Attached Android devices via `adb devices -l` (empty when adb isn't installed).
    public static func androidDevices() async -> [RemoteConnection] {
        guard let adb = DeviceTools.adb,
            let (data, status, _) = try? await RemoteRunner.run(adb, ["devices", "-l"]), status == 0
        else { return [] }
        return parseADBDevices(String(decoding: data, as: UTF8.self)).map { serial, model in
            RemoteConnection(name: model ?? serial, proto: .adb, host: serial, path: "/sdcard")
        }
    }

    /// UDIDs of USB-attached iOS devices, via our native usbmux client (no third-party tool).
    public static func iosUDIDs() -> [String] {
        guard let devices = try? USBMux.listDevices() else { return [] }
        return devices.filter { $0.connectionType == "USB" }.map(\.udid)
    }

    /// Parse `adb devices -l`: skip the header, keep only lines whose state is "device"
    /// (not "unauthorized"/"offline"), pulling the serial and the model:... tag.
    static func parseADBDevices(_ output: String) -> [(serial: String, model: String?)] {
        var devices: [(String, String?)] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2, fields[1] == "device" else { continue }
            let model = fields.first { $0.hasPrefix("model:") }?
                .dropFirst("model:".count).replacingOccurrences(of: "_", with: " ")
            devices.append((fields[0], model.flatMap { $0.isEmpty ? nil : String($0) }))
        }
        return devices
    }
}
