import Foundation

/// Mounting disk images, out-of-process via `hdiutil` (so untrusted-image parsing stays
/// out of the Full-Disk-Access process, like archives). Ejecting a volume is a Workspace
/// call in the app layer; this is just the attach side. The plist parser is pure/tested.
public enum DiskImage {
    public enum DiskImageError: Error, Sendable {
        case tool(code: Int32, message: String)
        case noMountPoint
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
