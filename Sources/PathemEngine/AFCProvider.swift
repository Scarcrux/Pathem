import Foundation

/// iOS device backend (placeholder, completed once the pymobiledevice3 AFC format is wired).
public struct AFCProvider: RemoteProvider {
    public init() {}
    public func list(_ connection: RemoteConnection, path: String, password: String) async throws -> [FileEntry] {
        throw RemoteError.deviceToolMissing("pymobiledevice3")
    }
    public func download(_ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String) async throws {
        throw RemoteError.deviceToolMissing("pymobiledevice3")
    }
    public func upload(_ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String) async throws {
        throw RemoteError.deviceToolMissing("pymobiledevice3")
    }
    public func makeDirectory(_ connection: RemoteConnection, path: String, password: String) async throws {
        throw RemoteError.deviceToolMissing("pymobiledevice3")
    }
    public func remove(_ connection: RemoteConnection, path: String, isDirectory: Bool, password: String) async throws {
        throw RemoteError.deviceToolMissing("pymobiledevice3")
    }
    public func rename(_ connection: RemoteConnection, from: String, to: String, password: String) async throws {
        throw RemoteError.deviceToolMissing("pymobiledevice3")
    }
}
