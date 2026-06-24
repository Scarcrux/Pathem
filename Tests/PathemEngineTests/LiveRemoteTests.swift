import Foundation
import Testing

@testable import PathemEngine

/// Opt-in live integration tests against PUBLIC test servers, exercising the real
/// curl/sftp providers end to end (list, transfer, and the mutation ops). Skipped
/// unless PATHEM_LIVE_REMOTE=1, so CI never depends on the network. Run locally with:
///   PATHEM_LIVE_REMOTE=1 swift test --filter LiveRemoteTests
@Suite struct LiveRemoteTests {
    private var enabled: Bool { ProcessInfo.processInfo.environment["PATHEM_LIVE_REMOTE"] == "1" }

    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-live-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// dlptest.com is a public read-WRITE FTP server: verify the full mutation cycle
    /// (upload → rename → delete, mkdir → rmdir), which validates the new remote ops.
    @Test func ftpReadWriteCycle() async throws {
        guard enabled else { return }
        let conn = RemoteConnection(name: "dlptest", proto: .ftp, host: "ftp.dlptest.com", user: "dlpuser")
        let password = "rNrKYTX9g7z3RgJRmxWuGHbeu"
        let provider = CurlFTPProvider()

        let listing = try await provider.list(conn, path: "/", password: password)
        #expect(!listing.isEmpty)

        let local = try tempFile("pathem live remote test")
        defer { try? FileManager.default.removeItem(at: local) }
        let name = "pathem-upload-\(UUID().uuidString).txt"
        try await provider.upload(local, to: conn, remotePath: "/\(name)", password: password)
        #expect(try await provider.list(conn, path: "/", password: password).contains { $0.name == name })

        let renamed = "pathem-renamed-\(UUID().uuidString).txt"
        try await provider.rename(conn, from: "/\(name)", to: "/\(renamed)", password: password)
        let afterRename = try await provider.list(conn, path: "/", password: password)
        #expect(afterRename.contains { $0.name == renamed })
        #expect(!afterRename.contains { $0.name == name })

        try await provider.remove(conn, path: "/\(renamed)", isDirectory: false, password: password)
        #expect(!(try await provider.list(conn, path: "/", password: password)).contains { $0.name == renamed })

        let dir = "pathem-dir-\(UUID().uuidString)"
        try await provider.makeDirectory(conn, path: "/\(dir)", password: password)
        try await provider.remove(conn, path: "/\(dir)", isDirectory: true, password: password)
    }

    /// rebex.net also speaks read-only FTP: verify the curl provider's list + download
    /// against a reliable public server (the read-write cycle above needs dlptest,
    /// which is frequently throttled/down).
    @Test func ftpListAndDownload() async throws {
        guard enabled else { return }
        let conn = RemoteConnection(name: "rebex-ftp", proto: .ftp, host: "test.rebex.net", user: "demo")
        let provider = CurlFTPProvider()
        let listing = try await provider.list(conn, path: "/", password: "password")
        #expect(listing.contains { $0.name == "readme.txt" })

        let local = FileManager.default.temporaryDirectory.appendingPathComponent("rebex-ftp-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: local) }
        try await provider.download(conn, remotePath: "/readme.txt", to: local, password: "password")
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int) ?? 0
        #expect((size ?? 0) > 0)
    }

    /// rebex.net is a public read-only SFTP server: verify list + download.
    @Test func sftpListAndDownload() async throws {
        guard enabled else { return }
        let conn = RemoteConnection(name: "rebex", proto: .sftp, host: "test.rebex.net", user: "demo")
        let provider = SFTPProvider()

        let listing = try await provider.list(conn, path: "/", password: "password")
        #expect(listing.contains { $0.name == "readme.txt" })

        let local = FileManager.default.temporaryDirectory.appendingPathComponent("rebex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: local) }
        try await provider.download(conn, remotePath: "/readme.txt", to: local, password: "password")
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int) ?? 0
        #expect(size ?? 0 > 0)
    }
}
