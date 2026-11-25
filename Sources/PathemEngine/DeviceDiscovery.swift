import Foundation

/// Discovers USB-attached phones and models each as a `RemoteConnection` (proto .adb/.afc,
/// serial/UDID in `host`) so the existing provider seam browses them. Android uses `adb`
/// (when installed); iOS uses our own usbmux client (no third-party tool). The friendly iOS
/// name is resolved separately/out-of-process by the app. The output parser is pure-tested.
public enum DeviceDiscovery {
    /// Attached Android devices via `adb devices -l` (empty when adb isn't installed).
    public static func androidDevices() async -> [RemoteConnection] {
        // The native adb server client first (real model names, and phones that still need USB
        // debugging allowed are listed too, so browsing them explains what to do). A missing or
        // broken helper falls back to the adb CLI below.
        if let native = await nativeAndroidDevices() { return native }
        guard let adb = DeviceTools.adb,
            let (data, status, _) = try? await RemoteRunner.run(adb, ["devices", "-l"]), status == 0
        else { return [] }
        return parseADBDevices(String(decoding: data, as: UTF8.self)).map { serial, model in
            RemoteConnection(name: model ?? serial, proto: .adb, host: serial, path: "/sdcard")
        }
    }

    /// Devices from the `pathem-adb` helper. Ready and unauthorized phones are listed (offline
    /// ones are transient and skipped). Nil when the helper can't answer, so the caller falls
    /// back to the CLI; an empty list when no adb exists at all.
    static func nativeAndroidDevices(
        helper: String? = ADBProvider.helperPath(), environment: [String: String]? = nil
    ) async -> [RemoteConnection]? {
        guard let helper,
            let (data, status, _) = try? await RemoteRunner.run(
                helper, ["devices"], env: environment)
        else { return nil }
        if status == ADBError.exitCodeMissing { return [] }
        guard status == 0,
            let devices = try? JSONDecoder().decode([ADBDeviceRow].self, from: data)
        else { return nil }
        return devices.filter { $0.state == "device" || $0.state == "unauthorized" }.map {
            RemoteConnection(
                name: $0.model ?? $0.serial, proto: .adb, host: $0.serial, path: "/sdcard")
        }
    }

    struct ADBDeviceRow: Decodable {
        let serial: String
        let state: String
        let model: String?
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
