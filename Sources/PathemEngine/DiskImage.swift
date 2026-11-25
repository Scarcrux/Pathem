import Foundation

/// Mounting disk images, out-of-process via `hdiutil` (so untrusted-image parsing stays
/// out of the app, like archives). Ejecting a volume is a Workspace
/// call in the app layer; this is just the attach side. The plist parser is pure/tested.
public enum DiskImage {
    public enum DiskImageError: Error, Sendable {
        case tool(code: Int32, message: String)
        case noMountPoint
        case noItems
    }

    /// Create an AES-256 encrypted disk image containing `items`. The items are staged into
    /// a temp folder and handed to `hdiutil create` out-of-process; the password is passed
    /// on stdin (`-stdinpass`) so it never appears in the argument list (visible via `ps`).
    /// Returns the created .dmg URL, placed in `directory` under `volumeName`.
    public static func createEncrypted(
        from items: [URL], volumeName: String, password: String, in directory: URL
    ) async throws -> URL {
        guard !items.isEmpty else { throw DiskImageError.noItems }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(
            "pathem-dmg-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for item in items {
            try fm.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
        }
        let output = uniqueName(directory.appendingPathComponent("\(volumeName).dmg"))
        let (_, status, err) = try await RemoteRunner.run(
            "/usr/bin/hdiutil",
            [
                "create", "-encryption", "AES-256", "-stdinpass", "-srcfolder", staging.path,
                "-volname", volumeName, "-format", "UDZO", output.path,
            ],
            input: password)
        guard status == 0 else { throw DiskImageError.tool(code: status, message: err) }
        return output
    }

    private static func uniqueName(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Whether `url` looks like a mountable disk image.
    public static func isDiskImage(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return [".dmg", ".sparseimage", ".sparsebundle", ".img", ".iso", ".cdr"].contains {
            name.hasSuffix($0)
        }
    }

    /// Attach `image` and return the first mounted volume. `-nobrowse` keeps it out of the
    /// Finder sidebar; we navigate Pathem there ourselves.
    public static func attach(_ image: URL) async throws -> URL {
        let (data, status, err) = try await RemoteRunner.run(
            "/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", image.path])
        guard status == 0 else { throw DiskImageError.tool(code: status, message: err) }
        guard let mountPoint = parseMountPoint(data) else { throw DiskImageError.noMountPoint }
        return mountPoint
    }

    /// Pull the first `mount-point` out of `hdiutil attach -plist` output.
    static func parseMountPoint(_ plistData: Data) -> URL? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
            let root = plist as? [String: Any],
            let entities = root["system-entities"] as? [[String: Any]]
        else { return nil }
        for entity in entities {
            if let path = entity["mount-point"] as? String, !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
