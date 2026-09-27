import Foundation
import PathemEngine
import TorrentKit

private enum ProbeResult {
    case pass(String)
    case skip(String)
    case fail(String)

    var exitCode: Int32 {
        switch self {
        case .pass, .skip: 0
        case .fail: 1
        }
    }

    var line: String {
        switch self {
        case .pass(let detail): "RESULT: PASS  \(detail)"
        case .skip(let detail): "RESULT: SKIP  \(detail)"
        case .fail(let detail): "RESULT: FAIL  \(detail)"
        }
    }
}

@main
private enum EnvironmentalProbe {
    static func main() async {
        let command = CommandLine.arguments.dropFirst().first ?? ""
        let result: ProbeResult
        do {
            switch command {
            case "storage": result = try await storage()
            case "remote": result = try await remote()
            case "spotlight": result = await spotlight()
            case "large-tree": result = try largeTree()
            case "provider-tree": result = try providerTree()
            case "router": result = await router()
            case "dht": result = await dht()
            case "external-tool": result = externalTool()
            default:
                result = .fail(
                    "usage: pathem-env-probe storage|remote|spotlight|large-tree|provider-tree|router|dht|external-tool"
                )
            }
        } catch {
            result = .fail(String(describing: error))
        }
        print(result.line)
        exit(result.exitCode)
    }

    private static func storage() async throws -> ProbeResult {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(
            "pathem-env-storage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        guard
            let device = run("/usr/bin/hdiutil", ["attach", "-nomount", "ram://131072"])?
                .split(whereSeparator: { $0 == "\n" || $0 == " " }).first.map(String.init),
            device.hasPrefix("/dev/disk")
        else { return .skip("host cannot create a disposable RAM disk") }
        defer { _ = run("/usr/sbin/diskutil", ["eject", device]) }

        let volumeName = "PathemEnv\(UUID().uuidString.prefix(8))"
        guard run("/usr/sbin/diskutil", ["eraseVolume", "APFS", volumeName, device]) != nil else {
            return .fail("could not format the disposable RAM disk")
        }
        let mount = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
        guard fm.fileExists(atPath: mount.path) else { return .fail("RAM disk did not mount") }

        let source = scratch.appendingPathComponent("cross-volume.bin")
        let payload = Data((0..<262_144).map { UInt8($0 % 251) })
        try payload.write(to: source)
        let moved = FileOperations.move(urls: [source], into: mount)
        let destination = mount.appendingPathComponent(source.lastPathComponent)
        guard moved.failures.isEmpty, !fm.fileExists(atPath: source.path),
            (try? Data(contentsOf: destination)) == payload
        else { return .fail("cross-volume move did not preserve bytes and remove its source") }

        let imageContents = scratch.appendingPathComponent("image-contents", isDirectory: true)
        try fm.createDirectory(at: imageContents, withIntermediateDirectories: true)
        let imageSource = imageContents.appendingPathComponent("inside.txt")
        try Data("disk-image-payload".utf8).write(to: imageSource)
        let image = scratch.appendingPathComponent("environmental.dmg")
        guard
            run(
                "/usr/bin/hdiutil",
                [
                    "create", "-srcfolder", imageContents.path, "-volname", "PathemEnvironmental",
                    "-format", "UDZO", image.path,
                ]) != nil
        else { return .fail("could not create a disposable disk image") }
        let imageMount = try await DiskImage.attach(image)
        defer { _ = run("/usr/bin/hdiutil", ["detach", imageMount.path]) }
        guard
            try Data(contentsOf: imageMount.appendingPathComponent("inside.txt"))
                == Data("disk-image-payload".utf8)
        else { return .fail("attached encrypted image did not expose the staged bytes") }

        return .pass("cross-volume move and disk-image attach/eject verified")
    }

    private static func remote() async throws -> ProbeResult {
        let env = ProcessInfo.processInfo.environment
        guard let ftpPort = Int(env["PATHEM_LOCAL_FTP_PORT"] ?? ""),
            let sftpPort = Int(env["PATHEM_LOCAL_SFTP_PORT"] ?? ""),
            let sftpUser = env["PATHEM_LOCAL_SFTP_USER"],
            let sftpKey = env["PATHEM_LOCAL_SFTP_KEY"],
            let sftpRoot = env["PATHEM_LOCAL_SFTP_ROOT"]
        else { return .skip("local FTP/SFTP fixtures were not supplied") }

        let fm = FileManager.default
        let local = fm.temporaryDirectory.appendingPathComponent(
            "pathem-env-remote-\(UUID().uuidString)")
        try Data("remote-provider-payload".utf8).write(to: local)
        defer { try? fm.removeItem(at: local) }

        let ftp = CurlFTPProvider()
        let ftpConnection = RemoteConnection(
            name: "loopback-ftp", proto: .ftp, host: "127.0.0.1", port: ftpPort,
            user: "pathem")
        let ftpName = "probe-\(UUID().uuidString).txt"
        let ftpRenamed = "renamed-\(UUID().uuidString).txt"
        try await ftp.upload(
            local, to: ftpConnection, remotePath: "/\(ftpName)", password: "fixture")
        try await ftp.rename(
            ftpConnection, from: "/\(ftpName)", to: "/\(ftpRenamed)", password: "fixture")
        let ftpDownload = local.deletingLastPathComponent().appendingPathComponent(
            "ftp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: ftpDownload) }
        try await ftp.download(
            ftpConnection, remotePath: "/\(ftpRenamed)", to: ftpDownload, password: "fixture")
        guard try Data(contentsOf: ftpDownload) == Data(contentsOf: local) else {
            return .fail("FTP download bytes differ from upload")
        }
        try await ftp.remove(
            ftpConnection, path: "/\(ftpRenamed)", isDirectory: false, password: "fixture")

        let sftp = SFTPProvider()
        let sftpConnection = RemoteConnection(
            name: "loopback-sftp", proto: .sftp, host: "127.0.0.1", port: sftpPort,
            user: sftpUser, keyFile: sftpKey)
        let sftpName = "probe-\(UUID().uuidString).txt"
        let sftpRenamed = "renamed-\(UUID().uuidString).txt"
        let remoteName = URL(fileURLWithPath: sftpRoot).appendingPathComponent(sftpName).path
        let remoteRenamed = URL(fileURLWithPath: sftpRoot).appendingPathComponent(sftpRenamed).path
        try await sftp.upload(local, to: sftpConnection, remotePath: remoteName, password: "")
        try await sftp.rename(sftpConnection, from: remoteName, to: remoteRenamed, password: "")
        let sftpDownload = local.deletingLastPathComponent().appendingPathComponent(
            "sftp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: sftpDownload) }
        try await sftp.download(
            sftpConnection, remotePath: remoteRenamed, to: sftpDownload, password: "")
        guard try Data(contentsOf: sftpDownload) == Data(contentsOf: local) else {
            return .fail("SFTP download bytes differ from upload")
        }
        try await sftp.remove(sftpConnection, path: remoteRenamed, isDirectory: false, password: "")

        return .pass("loopback FTP and SFTP upload/rename/download/delete verified")
    }

    private static func spotlight() async -> ProbeResult {
        let env = ProcessInfo.processInfo.environment
        guard env["PATHEM_SPOTLIGHT_LIVE"] == "1", let scopePath = env["PATHEM_SPOTLIGHT_SCOPE"],
            !scopePath.isEmpty
        else {
            return .skip(
                "set PATHEM_SPOTLIGHT_LIVE=1 and PATHEM_SPOTLIGHT_SCOPE to an indexed disposable folder"
            )
        }
        guard await SpotlightSearch.indexingEnabled() else {
            return .skip("Spotlight indexing is disabled")
        }
        let scope = URL(fileURLWithPath: scopePath, isDirectory: true)
        let token = "pathem-spotlight-\(UUID().uuidString)"
        let fixture = scope.appendingPathComponent("\(token).txt")
        do {
            try Data(token.utf8).write(to: fixture)
            defer { try? FileManager.default.removeItem(at: fixture) }
            _ = run("/usr/bin/mdimport", ["-i", scope.path])
            for _ in 0..<80 {
                let results = await SpotlightSearch.matching(
                    SpotlightSearch.filenameQuery(token), scope: scope, limit: 10)
                if results.contains(where: { $0.standardizedFileURL == fixture.standardizedFileURL }
                ) {
                    return .pass("Spotlight indexed and returned a disposable scoped fixture")
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return .fail("Spotlight did not return the disposable fixture within 20 seconds")
        } catch {
            return .fail("could not create the Spotlight fixture: \(error)")
        }
    }

    private static func router() async -> ProbeResult {
        guard ProcessInfo.processInfo.environment["PATHEM_ROUTER_LIVE"] == "1" else {
            return .skip("set PATHEM_ROUTER_LIVE=1 on a network where router mapping is safe")
        }
        let port = UInt16.random(in: 49_152...60_000)
        let nat = await NATPMPClient().mapTCP(port: port)
        let upnp = await UPnPClient().mapTCP(port: port, timeout: 5)
        if nat != nil || upnp {
            return .pass("router accepted \(nat != nil ? "NAT-PMP" : "UPnP") TCP mapping")
        }
        return .skip("router exposes neither NAT-PMP nor UPnP mapping on this network")
    }

    private static func largeTree() throws -> ProbeResult {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "pathem-env-large-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let count = 25_000
        for index in 0..<count {
            let path = root.appendingPathComponent(String(format: "item-%05d", index)).path
            guard fm.createFile(atPath: path, contents: Data()) else {
                return .fail("could not create large-tree fixture item \(index)")
            }
        }
        let started = ContinuousClock.now
        let entries = try BulkEnumerator().entries(of: root, includingHidden: true)
        let elapsed = started.duration(to: .now)
        guard entries.count == count, Set(entries.map(\.name)).count == count else {
            return .fail("large-tree enumeration returned \(entries.count)/\(count) unique entries")
        }
        return .pass("enumerated \(count) real files in \(elapsed)")
    }

    private static func providerTree() throws -> ProbeResult {
        guard let path = ProcessInfo.processInfo.environment["PATHEM_PROVIDER_TREE_ROOT"],
            !path.isEmpty
        else {
            return .skip("set PATHEM_PROVIDER_TREE_ROOT to a disposable provider-backed directory")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let bulk = try BulkEnumerator().entries(of: root, includingHidden: true)
        let oracle = try FoundationEnumerator().entries(of: root, includingHidden: true)
        guard Set(bulk.map(\.name)) == Set(oracle.map(\.name)) else {
            return .fail("provider-backed bulk/fallback listings disagree")
        }
        return .pass("provider-backed listing matched Foundation for \(bulk.count) entries")
    }

    private static func dht() async -> ProbeResult {
        guard ProcessInfo.processInfo.environment["PATHEM_DHT_LIVE"] == "1" else {
            return .skip("set PATHEM_DHT_LIVE=1 to query the public mainline DHT")
        }
        guard
            let hash = Magnet.parse(
                "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")?.infoHash
        else {
            return .fail("invalid built-in public-domain info hash")
        }
        let peers = await DHTClient().findPeers(infoHash: hash, maxPeers: 10, timeout: 25)
        return peers.isEmpty
            ? .fail("public DHT returned no peers for the known public-domain torrent")
            : .pass("public DHT returned \(peers.count) peer(s)")
    }

    private static func externalTool() -> ProbeResult {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(
            "pathem-env-tool-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            let file = scratch.appendingPathComponent("name with spaces.txt")
            try Data("tool-boundary".utf8).write(to: file)
            let command = ExternalCommand(
                id: "environmental", name: "Environmental",
                command: "printf 'cwd=%s\\nfile=%s\\n' \"$PWD\" %N")
            let output = ExternalCommandRunner.run(command, files: [file], directory: scratch)
            guard output.succeeded, output.text.contains("cwd="),
                output.text.contains(scratch.lastPathComponent),
                output.text.contains("file=name with spaces.txt")
            else {
                return .fail("shell working-directory or quoted-placeholder semantics diverged")
            }
            return .pass(
                "interactive-shell substrate and arbitrary external command boundary verified")
        } catch {
            return .fail(String(describing: error))
        }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
