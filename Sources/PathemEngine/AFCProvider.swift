import Foundation

/// iOS device backend. Detection works (the device appears in the sidebar via
/// libimobiledevice's `idevice_id`), but file browsing is intentionally NOT wired to a CLI:
/// pymobiledevice3's `afc` CLI can't give a typed directory listing or create/rename, and
/// `ifuse` needs the macFUSE kernel extension we've ruled out. A proper iOS browser will be
/// a dedicated out-of-process pure-Swift AFC client (usbmux + AFC), tracked separately. Until
/// then every operation reports "detected but not browsable yet" so nothing is half-built.
public struct AFCProvider: RemoteProvider {
    public init() {}
    public func list(_ connection: RemoteConnection, path: String, password: String) async throws -> [FileEntry] {
        throw RemoteError.deviceUnsupported
    }
    public func download(_ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String) async throws {
        throw RemoteError.deviceUnsupported
    }
    public func upload(_ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String) async throws {
        throw RemoteError.deviceUnsupported
    }
    public func makeDirectory(_ connection: RemoteConnection, path: String, password: String) async throws {
        throw RemoteError.deviceUnsupported
    }
    public func remove(_ connection: RemoteConnection, path: String, isDirectory: Bool, password: String) async throws {
        throw RemoteError.deviceUnsupported
    }
    public func rename(_ connection: RemoteConnection, from: String, to: String, password: String) async throws {
        throw RemoteError.deviceUnsupported
    }
}
