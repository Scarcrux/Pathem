import Foundation

/// iOS device backend. Browses a paired iPhone/iPad's media filesystem (DCIM, Downloads,
/// Books, ...) by invoking the bundled `pathem-afc` helper out-of-process, so the AFC stack
/// (usbmux + lockdown + TLS + AFC) and untrusted device data never run in the Full-Disk-Access
/// process. The connection's `host` carries the device UDID. The device must stay unlocked:
/// AFC stalls when the data partition re-encrypts on lock (the helper times out and reports it).
public struct AFCProvider: RemoteProvider {
    public init() {}

    struct Entry: Decodable {
        let name: String
        let dir: Bool
        let size: Int64
    }

    /// The device's friendly name, resolved out-of-process via the helper. nil if unavailable.
    public static func friendlyName(udid: String) async -> String? {
        guard let helper = helperPath(),
            let (data, status, _) = try? await RemoteRunner.run(helper, ["name", udid]), status == 0
        else { return nil }
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Locate the bundled helper (next to the app executable) or the dev build product.
    public static func helperPath() -> String? {
        var candidates: [String] = []
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exe.appendingPathComponent("pathem-afc").path)
        }
        candidates.append(
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("pathem-afc").path)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func list(_ connection: RemoteConnection, path: String, password: String) async throws
        -> [FileEntry]
    {
        let dir = path.isEmpty ? "/" : path
        let (data, _) = try await run(["ls", connection.host, dir])
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries.map {
            FileEntry(name: $0.name, isDirectory: $0.dir, size: $0.size, modificationDate: nil, location: dir)
        }
    }

    public func download(
        _ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String
    ) async throws {
        _ = try await run(["pull", connection.host, remotePath, localFile.path])
    }

    public func upload(
        _ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String
    ) async throws {
        _ = try await run(["push", connection.host, localFile.path, remotePath])
    }

    public func makeDirectory(_ connection: RemoteConnection, path: String, password: String) async throws {
        _ = try await run(["mkdir", connection.host, path])
    }

    public func remove(
        _ connection: RemoteConnection, path: String, isDirectory: Bool, password: String
    ) async throws {
        _ = try await run(["rm", connection.host, path])
    }

    public func rename(_ connection: RemoteConnection, from: String, to: String, password: String) async throws {
        _ = try await run(["mv", connection.host, from, to])
    }

    @discardableResult
    private func run(_ args: [String]) async throws -> (Data, String) {
        guard let helper = Self.helperPath() else {
            throw RemoteError.device(code: -1, message: "The iOS helper (pathem-afc) is missing from the app bundle.")
        }
        let (data, status, err) = try await RemoteRunner.run(helper, args)
        guard status == 0 else {
            throw RemoteError.device(code: status, message: err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (data, err)
    }
}
