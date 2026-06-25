import Foundation

/// Discovers USB-attached phones by asking the installed CLI tools, and models each as a
/// `RemoteConnection` (proto .adb/.afc, serial/UDID in `host`) so the existing provider
/// seam browses them. Returns nothing when no device tools are installed. The output
/// parsers are pure and tested.
public enum DeviceDiscovery {
    public static func discover() async -> [RemoteConnection] {
        var devices: [RemoteConnection] = []
        devices.append(contentsOf: await android())
        devices.append(contentsOf: await ios())
        return devices
    }

    private static func android() async -> [RemoteConnection] {
        guard let adb = DeviceTools.adb,
            let (data, status, _) = try? await RemoteRunner.run(adb, ["devices", "-l"]), status == 0
        else { return [] }
        return parseADBDevices(String(decoding: data, as: UTF8.self)).map { serial, model in
            RemoteConnection(name: model ?? serial, proto: .adb, host: serial, path: "/sdcard")
        }
    }

    private static func ios() async -> [RemoteConnection] {
        guard let tool = DeviceTools.idevice_id,
            let (data, status, _) = try? await RemoteRunner.run(tool, ["-l"]), status == 0
        else { return [] }
        var result: [RemoteConnection] = []
        for udid in parseUDIDs(String(decoding: data, as: UTF8.self)) {
            let name = await iosName(udid) ?? "iPhone"
            result.append(RemoteConnection(name: name, proto: .afc, host: udid, path: "/"))
        }
        return result
    }

    private static func iosName(_ udid: String) async -> String? {
        guard let info = DeviceTools.ideviceinfo,
            let (data, status, _) = try? await RemoteRunner.run(info, ["-u", udid, "-k", "DeviceName"]),
            status == 0
        else { return nil }
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
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

    /// Parse `idevice_id -l`: one UDID per line (some builds append " (USB)").
    static func parseUDIDs(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .map { $0.split(separator: " ").first.map(String.init) ?? $0 }
            .filter { !$0.isEmpty }
    }
}
