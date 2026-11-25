import Foundation
import Testing

@testable import PathemEngine

@Suite(.serialized) struct ADBProviderTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "adbp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    /// The test exercises the built helper, and fails if packaging stops producing it.
    private static var helper: String? { ExtensionExecution.findExecutable("pathem-adb")?.path }

    private func stubHelper(exit code: Int32, message: String, in dir: URL) throws -> String {
        let path = dir.appendingPathComponent("stub-adb")
        try "#!/bin/sh\necho '\(message)' >&2\nexit \(code)\n".write(
            to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    private let connection = RemoteConnection(
        name: "Pixel", proto: .adb, host: "ABC123", path: "/sdcard")

    private func fakeDevice() throws -> FakeADBServer {
        let fake = try FakeADBServer()
        fake.addDirectory("/sdcard")
        fake.addDirectory("/sdcard/DCIM")
        fake.addFile("/sdcard/notes.txt", Data("hello phone".utf8), mtime: 1_700_001_000)
        fake.addFile("/sdcard/big.bin", Data(repeating: 9, count: 250_000))
        return fake
    }

    private func provider(
        _ fake: FakeADBServer, adb: String? = nil,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    )
        throws -> ADBProvider
    {
        let helper = try #require(Self.helper, "pathem-adb was not built")
        return ADBProvider(
            helper: helper,
            environment: [
                "ANDROID_ADB_SERVER_PORT": String(fake.port), "PATH": "/usr/bin:/bin",
                "HOME": NSTemporaryDirectory(),
            ], adb: adb, progress: progress)
    }

    @Test
    func listingThroughTheHelperHasSizesAndDates() async throws {
        let fake = try fakeDevice()
        defer { fake.stop() }
        let entries = try await provider(fake).list(connection, path: "/sdcard", password: "")
        let notes = try #require(entries.first { $0.name == "notes.txt" })
        #expect(notes.size == 11)
        #expect(notes.modificationDate == Date(timeIntervalSince1970: 1_700_001_000))
        #expect(entries.first { $0.name == "DCIM" }?.isDirectory == true)
        #expect(entries.count == 3)
    }

    @Test
    func downloadAndUploadStreamThroughTheHelper() async throws {
        let fake = try fakeDevice()
        defer { fake.stop() }
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = ProgressBox()
        let cli = dir.appendingPathComponent("adb")
        let receipt = dir.appendingPathComponent("shell-receipt")
        // The fake server handles binary sync. Record the separately invoked shell
        // publication to prove it only happens after a staging upload.
        try """
        #!/bin/sh
        printf '%s\\n' "$4" >> '\(receipt.path)'
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let adb = try provider(fake, adb: cli.path, progress: { seen.add($0, $1) })
        let local = dir.appendingPathComponent("big.bin")
        try await adb.download(connection, remotePath: "/sdcard/big.bin", to: local, password: "")
        #expect(try Data(contentsOf: local) == Data(repeating: 9, count: 250_000))
        #expect(seen.last?.0 == 250_000 && seen.last?.1 == 250_000)

        let source = dir.appendingPathComponent("up.txt")
        try Data("from the mac".utf8).write(to: source)
        try await adb.upload(source, to: connection, remotePath: "/sdcard/up.txt", password: "")
        #expect(fake.upload("/sdcard/up.txt") == nil)
        let send = try #require(fake.commandsSeen.first { $0.hasPrefix("SEND ") })
        let stageFile = String(try #require(send.dropFirst(5).split(separator: ",").first))
        #expect(stageFile.hasPrefix("/sdcard/.pathem-upload-"))
        #expect(fake.upload(stageFile)?.data == Data("from the mac".utf8))
        let stage = (stageFile as NSString).deletingLastPathComponent
        let commands = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n")
        #expect(
            commands == [
                "mkdir -- '\(stage)'",
                "mv -fT -- '\(stageFile)' '/sdcard/up.txt'",
                "rm -rf -- '\(stage)'",
            ])
    }

    @Test func unauthorizedPhoneGetsTheSpecificError()
        async throws
    {
        let fake = try fakeDevice()
        defer { fake.stop() }
        fake.devices = [.init(serial: "ABC123", state: "unauthorized")]
        do {
            _ = try await provider(fake).list(connection, path: "/sdcard", password: "")
            Issue.record("an unauthorized phone must not list")
        } catch RemoteError.deviceState(let issue) {
            #expect(issue == .unauthorized)
        }
    }

    @Test
    func nativeDiscoveryListsReadyAndUnauthorizedPhones() async throws {
        let fake = try fakeDevice()
        defer { fake.stop() }
        fake.devices = [
            .init(serial: "A1"), .init(serial: "B2", state: "unauthorized", model: "Pixel_6"),
            .init(serial: "C3", state: "offline"),
        ]
        let helper = try #require(Self.helper)
        let found = await DeviceDiscovery.nativeAndroidDevices(
            helper: helper,
            environment: ["ANDROID_ADB_SERVER_PORT": String(fake.port), "PATH": "/usr/bin:/bin"])
        #expect(found?.map(\.host) == ["A1", "B2"])
        #expect(found?.map(\.name) == ["Pixel 8", "Pixel 6"])
    }

    @Test func definitiveHelperAnswersAreNotRetriedThroughTheCLI() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(Int32, DeviceIssue)] = [
            (ADBError.exitCodeUnauthorized, .unauthorized), (ADBError.exitCodeOffline, .offline),
            (ADBError.exitCodeMissing, .adbMissing),
        ]
        for (code, issue) in cases {
            let stub = try stubHelper(exit: code, message: "x", in: dir)
            let adb = ADBProvider(helper: stub, environment: nil)
            do {
                _ = try await adb.list(connection, path: "/sdcard", password: "")
                Issue.record("expected an error for exit \(code)")
            } catch RemoteError.deviceState(let got) {
                #expect(got == issue)
            }
        }
    }

    @Test func aBrokenProtocolConversationFallsBackToTheCLIPath() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = try stubHelper(exit: ADBError.exitCodeProtocol, message: "garbled", in: dir)
        let cli = dir.appendingPathComponent("adb")
        try """
        #!/bin/sh
        printf 'readme.txt\\nphotos/\\n'
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let adb = ADBProvider(helper: stub, environment: nil, adb: cli.path)
        let entries = try await adb.list(connection, path: "/sdcard", password: "")
        #expect(entries.map(\.name) == ["readme.txt", "photos"])
        #expect(entries.last?.isDirectory == true)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int64, Int64)] = []
    func add(_ done: Int64, _ total: Int64) {
        lock.lock()
        values.append((done, total))
        lock.unlock()
    }
    var last: (Int64, Int64)? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}
