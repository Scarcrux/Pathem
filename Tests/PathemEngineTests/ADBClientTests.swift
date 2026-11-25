import Foundation
import Testing

@testable import PathemEngine

@Suite struct ADBWireTests {
    @Test func hostRequestIsFramedWithFourHexDigits() throws {
        #expect(
            String(decoding: ADBWire.hostRequest("host:version"), as: UTF8.self)
                == "000chost:version")
        #expect(try ADBWire.hexLength(Data("001f".utf8)) == 31)
        for invalid in ["zz!!", "-001", "+001", "fff", "fffff"] {
            #expect(throws: ADBError.self) { try ADBWire.hexLength(Data(invalid.utf8)) }
        }
    }

    @Test func syncRequestIsIdLittleEndianLengthAndPayload() {
        let data = ADBWire.syncRequest("LIST", Data("/sdcard".utf8))
        #expect(Array(data.prefix(8)) == Array("LIST".utf8) + [7, 0, 0, 0])
        #expect(data.suffix(7) == Data("/sdcard".utf8))
    }

    @Test func devicesParseStateAndModel() {
        let text = """
            ABC123\tdevice usb:1-1 product:husky model:Pixel_8 device:husky transport_id:2
            XYZ789\tunauthorized usb:1-2 transport_id:3
            OFF1\toffline
            """
        let devices = ADBWire.parseDevices(text)
        #expect(devices.map(\.serial) == ["ABC123", "XYZ789", "OFF1"])
        #expect(devices.map(\.state) == ["device", "unauthorized", "offline"])
        #expect(devices.first?.model == "Pixel 8")
        #expect(devices.first?.isReady == true && devices[1].isReady == false)
    }

    @Test func transportFailuresMapToTheClearMessages() {
        let unauthorized = ADBError.fromTransportFailure(
            "device unauthorized.\nPlease check the confirmation dialog on your device.",
            serial: "S")
        #expect(unauthorized == .unauthorized)
        #expect(unauthorized.message == "Unlock the phone and allow USB debugging for this Mac.")
        #expect(ADBError.fromTransportFailure("device offline", serial: "S") == .offline)
        #expect(
            ADBError.fromTransportFailure("device 'S' not found", serial: "S")
                == .deviceNotFound("S"))
        #expect(ADBError.adbMissing.message.contains("brew install android-platform-tools"))
    }

    @Test func onlyProtocolFailuresFallBackToTheCLI() {
        #expect(ADBError.allowsCLIFallback(exitCode: ADBError.protocolFailure("x").exitCode))
        for error in [ADBError.unauthorized, .offline, .adbMissing, .remote("x"), .cancelled] {
            #expect(!ADBError.allowsCLIFallback(exitCode: error.exitCode))
        }
    }
}

@Suite(.serialized) struct ADBClientTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "adb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func server() throws -> FakeADBServer {
        let server = try FakeADBServer()
        server.addDirectory("/sdcard")
        server.addDirectory("/sdcard/DCIM", mtime: 1_700_000_500)
        server.addFile("/sdcard/notes.txt", Data("hello phone".utf8), mtime: 1_700_001_000)
        server.addFile("/sdcard/big.bin", Data(repeating: 7, count: 300_000), mtime: 1_700_002_000)
        return server
    }

    @Test func devicesComeFromTheServerWithStates() throws {
        let fake = try server()
        defer { fake.stop() }
        fake.devices = [
            .init(serial: "ABC123"), .init(serial: "NOPE", state: "unauthorized", model: "Pixel_6"),
        ]
        let devices = try ADBClient.devices(port: fake.port)
        #expect(devices.map(\.state) == ["device", "unauthorized"])
        #expect(devices.first?.model == "Pixel 8")
    }

    @Test(arguments: [true, false]) func listingHasRealSizesAndDates(v2: Bool) throws {
        let fake = try server()
        defer { fake.stop() }
        if !v2 { fake.features = [] }
        let sync = try ADBClient.openSync(port: fake.port, serial: "ABC123")
        defer { sync.close() }
        #expect(sync.supportsLargeStat == v2)
        let entries = try sync.list("/sdcard")
        #expect(entries.map(\.name) == ["DCIM", "big.bin", "notes.txt"])  // no "." or ".."
        let notes = try #require(entries.first { $0.name == "notes.txt" })
        #expect(notes.size == 11)
        #expect(notes.modified == Date(timeIntervalSince1970: 1_700_001_000))
        #expect(!notes.isDirectory)
        #expect(entries.first { $0.name == "DCIM" }?.isDirectory == true)
        #expect(fake.commandsSeen.contains(v2 ? "LIS2 /sdcard" : "LIST /sdcard"))
    }

    @Test func sizesPastFourGigabytesSurviveWithTheV2Listing() throws {
        let fake = try server()
        defer { fake.stop() }
        fake.addFile("/sdcard/movie.mkv", Data(), declaredSize: 6_000_000_000)
        let sync = try ADBClient.openSync(port: fake.port, serial: "ABC123")
        defer { sync.close() }
        #expect(try sync.list("/sdcard").first { $0.name == "movie.mkv" }?.size == 6_000_000_000)
        #expect(try sync.stat("/sdcard/movie.mkv")?.size == 6_000_000_000)
    }

    @Test func statReportsMissingAsNil() throws {
        let fake = try server()
        defer { fake.stop() }
        let sync = try ADBClient.openSync(port: fake.port, serial: "ABC123")
        defer { sync.close() }
        #expect(try sync.stat("/sdcard/nope") == nil)
        #expect(try sync.stat("/sdcard/DCIM")?.isDirectory == true)
    }

    @Test func listingAMissingFolderIsAClearRemoteError() throws {
        let fake = try server()
        defer { fake.stop() }
        let sync = try ADBClient.openSync(port: fake.port, serial: "ABC123")
        defer { sync.close() }
        #expect(throws: ADBError.remote("No such directory")) { try sync.list("/nope") }
    }

    @Test func pullStreamsTheFileAndReportsProgress() throws {
        let fake = try server()
        defer { fake.stop() }
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sync = try ADBClient.openSync(port: fake.port, serial: "ABC123")
        defer { sync.close() }
        let destination = dir.appendingPathComponent("big.bin")
        var reports: [(Int64, Int64)] = []
        try sync.pull("/sdcard/big.bin", to: destination) { reports.append(($0, $1)) }
        #expect(try Data(contentsOf: destination) == Data(repeating: 7, count: 300_000))
        #expect(reports.first?.0 == 0 && reports.last?.0 == 300_000)
        #expect(reports.allSatisfy { $0.1 == 300_000 })
        #expect(reports.count > 3)  // chunked, not one lump
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["big.bin"])
    }

    @Test func cancelingAPullLeavesNoFileBehind() throws {
        let fake = try server()
        defer { fake.stop() }
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sync = try ADBClient.openSync(port: fake.port, serial: "ABC123")
        defer { sync.close() }
        let destination = dir.appendingPathComponent("big.bin")
        var seen: Int64 = 0
        #expect(throws: ADBError.cancelled) {
            try sync.pull(
                "/sdcard/big.bin", to: destination, progress: { done, _ in seen = done },
                isCancelled: { seen >= ADBWire.maxChunk })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func cancelingAPullPreservesExistingBytes() throws {
        let fake = try server()
        defer { fake.stop() }
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sync = try ADBClient.openSync(port: fake.port, serial: "ABC123")
        defer { sync.close() }
        let original = Data("PREEXISTING".utf8)
        let destination = dir.appendingPathComponent("big.bin")
        try original.write(to: destination)
        var seen: Int64 = 0
        #expect(throws: ADBError.cancelled) {
            try sync.pull(
                "/sdcard/big.bin", to: destination, progress: { done, _ in seen = done },
                isCancelled: { seen >= ADBWire.maxChunk })
        }
        #expect(seen >= ADBWire.maxChunk)
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["big.bin"])
    }

    @Test func pullOfAMissingFileFailsWithTheDeviceMessageAndKeepsTheOldFile() throws {
        let fake = try server()
        defer { fake.stop() }
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("keep.txt")
        try Data("old".utf8).write(to: existing)
        let sync = try ADBClient.openSync(port: fake.port, serial: "ABC123")
        defer { sync.close() }
        #expect(throws: ADBError.remote("No such file or directory")) {
            try sync.pull("/sdcard/missing", to: existing)
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["keep.txt"])
    }

    @Test func pushStreamsInChunksWithModeAndModificationTime() throws {
        let fake = try server()
        defer { fake.stop() }
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("up.bin")
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try payload.write(to: source)
        try FileManager.default.setAttributes(
            [
                .modificationDate: Date(timeIntervalSince1970: 1_650_000_000),
                .posixPermissions: 0o600,
            ],
            ofItemAtPath: source.path)
        let sync = try ADBClient.openSync(port: fake.port, serial: "ABC123")
        defer { sync.close() }
        var last: (Int64, Int64) = (0, 0)
        try sync.push(source, to: "/sdcard/up.bin") { last = ($0, $1) }
        let uploaded = try #require(fake.upload("/sdcard/up.bin"))
        #expect(uploaded.data == payload)
        #expect(uploaded.mode == 0o100600)
        #expect(uploaded.mtime == 1_650_000_000)
        #expect(last == (200_000, 200_000))
    }

    @Test func unauthorizedAndOfflineDevicesGetTheClearMessages() throws {
        let fake = try server()
        defer { fake.stop() }
        fake.devices = [
            .init(serial: "LOCKED", state: "unauthorized"), .init(serial: "GONE", state: "offline"),
        ]
        #expect(throws: ADBError.unauthorized) {
            try ADBClient.openSync(port: fake.port, serial: "LOCKED")
        }
        #expect(throws: ADBError.offline) {
            try ADBClient.openSync(port: fake.port, serial: "GONE")
        }
        #expect(throws: ADBError.deviceNotFound("MISSING")) {
            try ADBClient.openSync(port: fake.port, serial: "MISSING")
        }
    }

    @Test func serverIsStartedOnceWhenNothingListens() throws {
        let first = try server()
        let port = first.port
        first.stop()  // nothing listens now
        var starts = 0
        var revived: FakeADBServer?
        defer { revived?.stop() }
        // The starter brings a server up on the same port, like `adb start-server` would.
        try ADBServer.ensureRunning(
            port: port,
            start: {
                starts += 1
                revived = try FakeADBServer(port: port)
            })
        #expect(starts == 1)
        #expect(try ADBClient.serverVersion(port: port) == "0029")
    }

    @Test func aFailedStartIsReportedNotRetriedForever() throws {
        let first = try server()
        let port = first.port
        first.stop()
        var starts = 0
        #expect(throws: ADBError.protocolFailure("could not start")) {
            try ADBServer.ensureRunning(
                port: port,
                start: {
                    starts += 1
                    throw ADBError.protocolFailure("could not start")
                })
        }
        #expect(starts == 1)
    }

    @Test func noAdbBinaryMeansTheInstallMessage() throws {
        let fake = try server()
        let port = fake.port
        fake.stop()
        #expect(throws: ADBError.adbMissing) { try ADBServer.ensureRunning(port: port, start: nil) }
    }

    @Test func aRunningServerNeedsNoStart() throws {
        let fake = try server()
        defer { fake.stop() }
        var starts = 0
        try ADBServer.ensureRunning(port: fake.port, start: { starts += 1 })
        #expect(starts == 0)
    }

    @Test func serverPortHonorsTheEnvironment() {
        #expect(ADBClient.serverPort(environment: [:]) == 5037)
        #expect(ADBClient.serverPort(environment: ["ANDROID_ADB_SERVER_PORT": "5555"]) == 5555)
        #expect(ADBClient.serverPort(environment: ["ANDROID_ADB_SERVER_PORT": "junk"]) == 5037)
    }
}
