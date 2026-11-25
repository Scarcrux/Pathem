import Darwin
import Foundation

/// Failure modes of the native adb server-protocol client. Each carries the message the user
/// sees and a stable helper exit code, so the app can tell a definitive answer (no device
/// permission, no adb) from a protocol failure where falling back to the adb CLI makes sense.
public enum ADBError: Error, Equatable, Sendable {
    /// No adb server is listening and no adb binary was found to start one.
    case adbMissing
    case serverNotListening(UInt16)
    /// The server could not be reached or spoke something unexpected. The CLI may still work.
    case protocolFailure(String)
    case unauthorized
    case offline
    case deviceNotFound(String)
    /// The server or the device refused a request (file not found, permission denied).
    case remote(String)
    case timedOut
    case cancelled

    public static let exitCodeRemote: Int32 = 1
    public static let exitCodeProtocol: Int32 = 2
    public static let exitCodeMissing: Int32 = 3
    public static let exitCodeUnauthorized: Int32 = 4
    public static let exitCodeOffline: Int32 = 5
    public static let exitCodeNotFound: Int32 = 6
    public static let exitCodeCancelled: Int32 = 7

    public var exitCode: Int32 {
        switch self {
        case .adbMissing: return Self.exitCodeMissing
        case .protocolFailure, .serverNotListening: return Self.exitCodeProtocol
        case .unauthorized: return Self.exitCodeUnauthorized
        case .offline: return Self.exitCodeOffline
        case .deviceNotFound: return Self.exitCodeNotFound
        case .remote, .timedOut: return Self.exitCodeRemote
        case .cancelled: return Self.exitCodeCancelled
        }
    }

    /// Whether the adb CLI is worth trying after this failure. Only a broken protocol
    /// conversation qualifies; a definitive answer (unauthorized, offline, not found) would be
    /// the same through the CLI.
    public static func allowsCLIFallback(exitCode: Int32) -> Bool { exitCode == exitCodeProtocol }

    public var message: String {
        switch self {
        case .adbMissing:
            return
                "Install Android platform-tools (brew install android-platform-tools) and enable USB debugging."
        case .serverNotListening(let port): return "No adb server is listening on port \(port)."
        case .protocolFailure(let detail): return "Could not talk to the adb server: \(detail)"
        case .unauthorized: return "Unlock the phone and allow USB debugging for this Mac."
        case .offline:
            return "The phone is offline. Unplug and reconnect the cable, then unlock the phone."
        case .deviceNotFound(let serial):
            return "No Android device \(serial) is connected. Check the cable and USB debugging."
        case .remote(let text): return text
        case .timedOut: return "The device stopped responding."
        case .cancelled: return "The transfer was canceled."
        }
    }

    /// Map the text of a server FAIL reply (from `host:transport`) to a specific error.
    static func fromTransportFailure(_ text: String, serial: String) -> ADBError {
        let lower = text.lowercased()
        if lower.contains("unauthorized") { return .unauthorized }
        if lower.contains("offline") { return .offline }
        if lower.contains("not found") || lower.contains("no devices")
            || lower.contains("more than one")
        {
            return .deviceNotFound(serial)
        }
        return .remote(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// One entry of `host:devices-l`.
public struct ADBDevice: Equatable, Sendable {
    public let serial: String
    /// "device", "unauthorized", "offline", ...
    public let state: String
    public let model: String?
    public var isReady: Bool { state == "device" }
}

/// A file's attributes from a sync LIST or STAT.
public struct ADBFileInfo: Equatable, Sendable {
    public var name: String
    public var mode: UInt32
    public var size: UInt64
    public var modified: Date?
    public var isDirectory: Bool { mode & 0o170000 == 0o040000 }
    public var isSymlink: Bool { mode & 0o170000 == 0o120000 }
}

/// A blocking socket to the local adb server. Used from the out-of-process helper, one
/// conversation per instance.
final class ADBSocket {
    private var fd: Int32
    var isOpen: Bool { fd >= 0 }

    init(port: UInt16, timeout: TimeInterval) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ADBError.protocolFailure("socket: \(String(cString: strerror(errno)))")
        }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(fd)
            fd = -1
            throw ADBError.protocolFailure("could not protect the socket descriptor")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            fd = -1
            if code == ECONNREFUSED { throw ADBError.serverNotListening(port) }
            throw ADBError.protocolFailure(String(cString: strerror(code)))
        }
    }

    deinit { close() }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    func write(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while offset < data.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, data.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN
                        ? ADBError.timedOut : ADBError.protocolFailure("write failed")
                }
                guard n > 0 else { throw ADBError.protocolFailure("zero-byte socket write") }
                offset += n
            }
        }
    }

    func readExact(_ count: Int) throws -> Data {
        var buffer = Data(count: count)
        var offset = 0
        try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            while offset < count {
                let n = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if n == 0 { throw ADBError.protocolFailure("the connection closed early") }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN
                        ? ADBError.timedOut : ADBError.protocolFailure("read failed")
                }
                offset += n
            }
        }
        return buffer
    }

    func readUInt32() throws -> UInt32 { try ADBWire.uint32(readExact(4), at: 0) }
}

/// Entry points of the adb server protocol (host services and the sync service).
public enum ADBClient {
    public static let defaultPort: UInt16 = 5037

    /// The server port: `ANDROID_ADB_SERVER_PORT` when set (as adb itself does), else 5037.
    public static func serverPort(
        environment: [String: String] = ProcessInfo.processInfo.environment
    )
        -> UInt16
    {
        guard let value = environment["ANDROID_ADB_SERVER_PORT"],
            let port = UInt16(value), port > 0
        else { return defaultPort }
        return port
    }

    /// One host-service request, returning the length-prefixed payload when there is one.
    static func hostQuery(port: UInt16, _ request: String, timeout: TimeInterval = 10) throws
        -> String
    {
        let socket = try ADBSocket(port: port, timeout: timeout)
        try socket.write(ADBWire.hostRequest(request))
        try expectOkay(socket)
        let length = try ADBWire.hexLength(socket.readExact(4))
        return String(decoding: try socket.readExact(length), as: UTF8.self)
    }

    static func expectOkay(_ socket: ADBSocket, serial: String = "") throws {
        let status = String(decoding: try socket.readExact(4), as: UTF8.self)
        switch status {
        case "OKAY": return
        case "FAIL":
            let length = try ADBWire.hexLength(socket.readExact(4))
            let text = String(decoding: try socket.readExact(length), as: UTF8.self)
            throw ADBError.fromTransportFailure(text, serial: serial)
        default: throw ADBError.protocolFailure("unexpected reply \(status.debugDescription)")
        }
    }

    public static func serverVersion(port: UInt16) throws -> String {
        try hostQuery(port: port, "host:version")
    }

    /// Attached devices with their state and model (`host:devices-l`).
    public static func devices(port: UInt16) throws -> [ADBDevice] {
        ADBWire.parseDevices(try hostQuery(port: port, "host:devices-l"))
    }

    /// Open a sync session with a device.
    public static func openSync(port: UInt16, serial: String, timeout: TimeInterval = 30) throws
        -> ADBSync
    {
        // Features first (own short connection), so listings can use 64-bit sizes when offered.
        guard !serial.isEmpty, serial.utf8.count <= 1_024, !serial.utf8.contains(0),
            !serial.contains(where: \.isWhitespace)
        else { throw ADBError.protocolFailure("invalid device serial") }
        let features =
            (try? hostQuery(port: port, "host-serial:\(serial):features"))
            .map { Set($0.split(separator: ",").map(String.init)) } ?? []
        let socket = try ADBSocket(port: port, timeout: timeout)
        try socket.write(ADBWire.hostRequest("host:transport:\(serial)"))
        try expectOkay(socket, serial: serial)
        try socket.write(ADBWire.hostRequest("sync:"))
        try expectOkay(socket, serial: serial)
        return ADBSync(socket: socket, features: features)
    }
}

/// Makes sure an adb server is listening, starting one once if needed.
public enum ADBServer {
    /// Check `host:version`. When nothing answers, call `start` once (normally `adb
    /// start-server`) and check again. Throws `.adbMissing` when there is no way to start one.
    public static func ensureRunning(port: UInt16, start: (() throws -> Void)?) throws {
        do {
            _ = try ADBClient.serverVersion(port: port)
            return
        } catch ADBError.serverNotListening {
            // Only a refused loopback connection authorizes starting the user's daemon.
        }
        guard let start else { throw ADBError.adbMissing }
        try start()
        var lastError: Error = ADBError.protocolFailure("the adb server did not start")
        for _ in 0..<10 {
            do {
                _ = try ADBClient.serverVersion(port: port)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        throw lastError
    }

    /// The default starter: `adb start-server` at `adbPath`, on `port`.
    public static func starter(adbPath: String, port: UInt16) -> () throws -> Void {
        {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = ["-P", String(port), "start-server"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ADBError.remote("Android platform-tools could not start the adb server.")
            }
        }
    }
}

/// A sync-service session: LIST, STAT, RECV, SEND against one device. Blocking; use from one
/// thread. Large files stream in 64 KB chunks and never sit in memory whole.
public final class ADBSync {
    private let socket: ADBSocket
    private let features: Set<String>

    init(socket: ADBSocket, features: Set<String>) {
        self.socket = socket
        self.features = features
    }

    public var supportsLargeStat: Bool {
        features.contains("ls_v2") && features.contains("stat_v2")
    }

    public func close() {
        if socket.isOpen { try? socket.write(ADBWire.syncRequest("QUIT", Data())) }
        socket.close()
    }

    // MARK: LIST / STAT

    /// The entries of a directory, without "." and "..", with real sizes and dates.
    public func list(_ path: String) throws -> [ADBFileInfo] {
        let v2 = supportsLargeStat
        try requestPath(v2 ? "LIS2" : "LIST", path)
        var entries: [ADBFileInfo] = []
        for _ in 0..<100_000 {
            let id = String(decoding: try socket.readExact(4), as: UTF8.self)
            switch id {
            case "DENT":
                let rest = try socket.readExact(16)
                let nameLength = Int(try ADBWire.uint32(rest, at: 12))
                let name = try readName(nameLength)
                if name == "." || name == ".." { continue }
                entries.append(
                    ADBFileInfo(
                        name: name, mode: try ADBWire.uint32(rest, at: 0),
                        size: UInt64(try ADBWire.uint32(rest, at: 4)),
                        modified: ADBWire.date(Int64(try ADBWire.uint32(rest, at: 8)))))
            case "DNT2":
                let rest = try socket.readExact(72)
                let nameLength = Int(try ADBWire.uint32(rest, at: 68))
                let name = try readName(nameLength)
                let status = try ADBWire.uint32(rest, at: 0)
                if name == "." || name == ".." || status != 0 { continue }
                let stat = try ADBWire.parseStatV2(rest, at: 0)
                entries.append(
                    ADBFileInfo(
                        name: name, mode: stat.mode, size: stat.size, modified: stat.modified))
            case "DONE":
                _ = try socket.readExact(v2 ? 72 : 16)
                return entries
            case "FAIL": throw try readFailure()
            default: throw ADBError.protocolFailure("unexpected list reply \(id.debugDescription)")
            }
        }
        throw ADBError.protocolFailure("directory listing exceeded 100,000 entries")
    }

    private func readName(_ length: Int) throws -> String {
        guard (1...1024).contains(length),
            let name = String(data: try socket.readExact(length), encoding: .utf8),
            !name.contains("/"), !name.utf8.contains(0)
        else { throw ADBError.protocolFailure("invalid directory entry name") }
        return name
    }

    private func requestPath(_ command: String, _ path: String) throws {
        let bytes = Data(path.utf8)
        guard (1...1024).contains(bytes.count), !bytes.contains(0) else {
            throw ADBError.remote(
                "Android file path exceeds the sync protocol limit or is invalid.")
        }
        try socket.write(ADBWire.syncRequest(command, bytes))
    }

    /// Attributes of one path, or nil when it does not exist.
    public func stat(_ path: String) throws -> ADBFileInfo? {
        let name = (path as NSString).lastPathComponent
        if supportsLargeStat {
            try requestPath("STA2", path)
            let id = String(decoding: try socket.readExact(4), as: UTF8.self)
            if id == "FAIL" { throw try readFailure() }
            guard id == "STA2" else { throw ADBError.protocolFailure("unexpected stat reply") }
            let rest = try socket.readExact(68)
            guard try ADBWire.uint32(rest, at: 0) == 0 else { return nil }
            let stat = try ADBWire.parseStatV2(rest, at: 0)
            return stat.mode == 0
                ? nil
                : ADBFileInfo(name: name, mode: stat.mode, size: stat.size, modified: stat.modified)
        }
        try requestPath("STAT", path)
        let id = String(decoding: try socket.readExact(4), as: UTF8.self)
        if id == "FAIL" { throw try readFailure() }
        guard id == "STAT" else { throw ADBError.protocolFailure("unexpected stat reply") }
        let rest = try socket.readExact(12)
        let mode = try ADBWire.uint32(rest, at: 0)
        guard mode != 0 else { return nil }
        return ADBFileInfo(
            name: name, mode: mode, size: UInt64(try ADBWire.uint32(rest, at: 4)),
            modified: ADBWire.date(Int64(try ADBWire.uint32(rest, at: 8))))
    }

    // MARK: RECV

    /// Download `remote` to `local`, streamed in chunks. The local file is created when the
    /// first data arrives in a temporary sibling. Replace the destination only after DONE,
    /// so a refusal or a canceled or failed transfer preserves any existing file. Progress is
    /// (bytes so far, total or -1 when unknown).
    public func pull(
        _ remote: String, to local: URL, progress: ((Int64, Int64) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws {
        let total = (try? stat(remote)).flatMap { $0 }.map { Int64($0.size) } ?? -1
        let staging = local.deletingLastPathComponent().appendingPathComponent(
            ".pathem-adb-\(UUID().uuidString)")
        var handle: FileHandle?
        defer {
            try? handle?.close()
            if handle != nil { try? FileManager.default.removeItem(at: staging) }
        }
        func openIfNeeded() throws -> FileHandle {
            if let handle { return handle }
            let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let opened = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            handle = opened
            return opened
        }

        try requestPath("RECV", remote)
        var done: Int64 = 0
        progress?(0, total)
        while true {
            if isCancelled() {
                socket.close()  // the server drops the rest; this session is finished
                throw ADBError.cancelled
            }
            let id = String(decoding: try socket.readExact(4), as: UTF8.self)
            switch id {
            case "DATA":
                let length = Int(try socket.readUInt32())
                guard (1...ADBWire.maxChunk).contains(length) else {
                    throw ADBError.protocolFailure("oversized data chunk")
                }
                try openIfNeeded().write(contentsOf: try socket.readExact(length))
                done += Int64(length)
                progress?(done, total)
            case "DONE":
                _ = try socket.readUInt32()
                guard !isCancelled() else { throw ADBError.cancelled }
                let output = try openIfNeeded()  // an empty remote file still creates the local one
                try output.close()
                guard Darwin.rename(staging.path, local.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return
            case "FAIL": throw try readFailure()
            default: throw ADBError.protocolFailure("unexpected data reply \(id.debugDescription)")
            }
        }
    }

    // MARK: SEND

    /// Upload `local` to `remote`, streamed, keeping its permissions and modification time.
    public func push(
        _ local: URL, to remote: String, progress: ((Int64, Int64) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
        let total = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let permissions =
            ((attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644) & 0o777
        let mtime = Int64((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }

        let spec = "\(remote),\(0o100000 | permissions)"
        guard !isCancelled() else { throw ADBError.cancelled }
        try requestPath("SEND", spec)
        var done: Int64 = 0
        progress?(0, total)
        while let chunk = try handle.read(upToCount: ADBWire.maxChunk), !chunk.isEmpty {
            if isCancelled() {
                socket.close()
                throw ADBError.cancelled
            }
            try socket.write(ADBWire.syncRequest("DATA", chunk))
            done += Int64(chunk.count)
            progress?(done, total)
        }
        guard !isCancelled() else {
            socket.close()
            throw ADBError.cancelled
        }
        try socket.write(ADBWire.syncHeader("DONE", UInt32(clamping: mtime)))
        let id = String(decoding: try socket.readExact(4), as: UTF8.self)
        switch id {
        case "OKAY": _ = try socket.readUInt32()
        case "FAIL": throw try readFailure()
        default: throw ADBError.protocolFailure("unexpected send reply \(id.debugDescription)")
        }
    }

    private func readFailure() throws -> ADBError {
        let length = Int(try socket.readUInt32())
        guard length < 64 * 1024 else { return .protocolFailure("oversized failure message") }
        let text = String(decoding: try socket.readExact(length), as: UTF8.self)
        return .remote(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
