import Darwin
import Foundation
import Network
import Testing

@testable import TorrentKit

#if canImport(Network)
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["PATHEM_TRANSMISSION_DAEMON"]?.isEmpty == false
            && ProcessInfo.processInfo.environment["PATHEM_TRANSMISSION_REMOTE"]?.isEmpty == false,
        "Requires PATHEM_TRANSMISSION_DAEMON and PATHEM_TRANSMISSION_REMOTE"))
struct ThirdPartyInteropTests {
    @Test func downloadsFromTransmissionOverLoopback() async throws {
        let env = ProcessInfo.processInfo.environment
        let daemonPath = try #require(env["PATHEM_TRANSMISSION_DAEMON"])
        let remotePath = try #require(env["PATHEM_TRANSMISSION_REMOTE"])
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "pathem-transmission-interop-\(UUID().uuidString)", isDirectory: true)
        let seed = root.appendingPathComponent("seed", isDirectory: true)
        let download = root.appendingPathComponent("download", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        for directory in [seed, download, config] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }

        let payload = Data((0..<180_000).map { UInt8(($0 &* 31) & 0xff) })
        let source = seed.appendingPathComponent("third-party-payload.bin")
        try payload.write(to: source)
        let torrentData = try TorrentCreator.create(
            contentsOf: source,
            options: .init(pieceLength: 32 * 1024, creationDate: Date(timeIntervalSince1970: 0)))
        let torrentURL = root.appendingPathComponent("fixture.torrent")
        try torrentData.write(to: torrentURL)
        let torrent = try TorrentFile.parse(torrentData)

        let peerPort = try reservePort()
        var rpcPort = try reservePort()
        while rpcPort == peerPort { rpcPort = try reservePort() }
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: daemonPath)
        daemon.arguments = [
            "--foreground", "--config-dir", config.path, "--peerport", "\(peerPort)",
            "--port", "\(rpcPort)", "--no-portmap", "--no-auth", "--log-error",
        ]
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.nullDevice
        try daemon.run()
        defer {
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }

        var rpcReady = false
        for _ in 0..<80 {
            if run(remotePath, ["127.0.0.1:\(rpcPort)", "--list"]) == 0 {
                rpcReady = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(rpcReady, "Transmission RPC did not become ready")
        #expect(
            run(
                remotePath,
                [
                    "127.0.0.1:\(rpcPort)", "--add", torrentURL.path, "--download-dir",
                    seed.path,
                ]) == 0)

        let leecher = try TorrentSession(torrent: torrent, downloadRoot: download)
        await leecher.start()
        await leecher.addPeers([.init(host: "127.0.0.1", port: Int(peerPort))])

        var finished = false
        var sawTransmission = false
        for _ in 0..<300 {
            let status = await leecher.status()
            let peers = await leecher.peers()
            sawTransmission =
                sawTransmission || peers.contains { $0.client.contains("Transmission") }
            if status.fractionComplete >= 1 {
                finished = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        await leecher.stop()

        #expect(finished)
        #expect(sawTransmission)
        #expect(
            try Data(contentsOf: download.appendingPathComponent(source.lastPathComponent))
                == payload)
    }

    private func reservePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return UInt16(bigEndian: address.sin_port)
    }

    private func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
#endif
