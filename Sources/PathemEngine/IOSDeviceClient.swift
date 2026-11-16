import Foundation
import Network
import Security

#if canImport(Darwin)
import Darwin
#endif

// TLS to a device runs over a usbmux tunnel, which is an already-connected socket, and after a
// plaintext lockdown exchange on that same socket. Network.framework cannot adopt an existing
// descriptor, so the tunnel is bridged: a private Unix-domain socket pair of our own stands
// in for the peer, NWConnection does TLS (with the pairing record's client identity) against
// that local endpoint, and two pump threads copy bytes between it and the usbmux descriptor.
// This replaced SecureTransport, which Apple deprecated in macOS 10.15. This whole client is
// meant to run in an out-of-process helper.

public enum IOSDeviceError: Error, Sendable {
    case noDevice
    case handshake(String)
    case afc(UInt64)  // AFC STATUS error code
    case tls(OSStatus)
}

/// Copies bytes between the usbmux tunnel and a local socket that NWConnection talks TLS to.
private final class TunnelBridge: @unchecked Sendable {
    let endpointPath: String
    private let directory: URL
    private let listener: Int32
    private let tunnel: Int32
    private var local: Int32 = -1
    private let lock = NSLock()
    private var closed = false

    init(tunnel: Int32) throws {
        self.tunnel = tunnel
        // A directory only this user can enter, so no other local process can connect first.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-afc-tls-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        endpointPath = directory.appendingPathComponent("s").path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw IOSDeviceError.handshake("bridge socket failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let limit = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard endpointPath.utf8.count <= limit else {
            Darwin.close(listener)
            throw IOSDeviceError.handshake("bridge path too long")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            endpointPath.withCString { memcpy(dst, $0, strlen($0)) }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, length)
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else {
            Darwin.close(listener)
            throw IOSDeviceError.handshake("bridge bind failed")
        }
    }

    static func trace(_ message: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["PATHEM_AFC_TRACE"] == "2" {
            FileHandle.standardError.write(Data(("[bridge] " + message() + "\n").utf8))
        }
    }

    /// Accept the one local connection (NWConnection's) and start copying in both directions.
    func start() {
        Thread.detachNewThread { [self] in
            let accepted = Darwin.accept(listener, nil, nil)
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: directory)  // the path is no longer needed
            TunnelBridge.trace("accepted fd=\(accepted) errno=\(errno)")
            guard accepted >= 0 else { return }
            lock.withLock { local = accepted }
            Thread.detachNewThread { [self] in pump(from: tunnel, to: accepted) }
            pump(from: accepted, to: tunnel)
        }
    }

    private func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            // EAGAIN is the tunnel's receive timeout: keep waiting while the session is open.
            if count < 0, errno == EAGAIN, !lock.withLock({ closed }) { continue }
            guard count > 0 else {
                TunnelBridge.trace(
                    "pump \(source)->\(destination) ended count=\(count) errno=\(errno)")
                break
            }
            TunnelBridge.trace("pump \(source)->\(destination) \(count) bytes")
            var sent = 0
            while sent < count {
                let written = buffer.withUnsafeBytes {
                    write(destination, $0.baseAddress!.advanced(by: sent), count - sent)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                sent += written
            }
        }
        shutdown(destination, SHUT_WR)
    }

    func close() {
        let fd: Int32 = lock.withLock {
            closed = true
            return local
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

/// A blocking TLS client stream over Network.framework, for the synchronous device protocol.
private final class TLSStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "pathem.afc.tls")
    private(set) var negotiatedVersion = ""

    init(path: String, identity: SecIdentity) throws {
        let tls = NWProtocolTLS.Options()
        guard let local = sec_identity_create(identity) else {
            throw IOSDeviceError.handshake("client identity unusable")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        // The device presents a self-signed certificate from the pairing record; as before,
        // it is not verified against a trust store.
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        connection = NWConnection(
            to: .unix(path: path), using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
    }

    func start(timeout: TimeInterval = 25) throws {
        let done = DispatchSemaphore(value: 0)
        let failure = Box<NWError?>(nil)
        connection.stateUpdateHandler = { state in
            TunnelBridge.trace("nw state \(state)")
            switch state {
            case .ready: done.signal()
            case .failed(let error), .waiting(let error):
                failure.value = error
                done.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        guard done.wait(timeout: .now() + timeout) == .success else {
            connection.cancel()
            throw IOSDeviceError.handshake("TLS handshake timed out")
        }
        connection.stateUpdateHandler = nil
        if let error = failure.value {
            connection.cancel()
            throw IOSDeviceError.handshake("TLS handshake failed: \(error)")
        }
        if let metadata = connection.metadata(definition: NWProtocolTLS.definition)
            as? NWProtocolTLS.Metadata
        {
            let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(
                metadata.securityProtocolMetadata)
            negotiatedVersion = String(describing: version)
        }
    }

    func write(_ data: Data, timeout: TimeInterval = 25) throws {
        let done = DispatchSemaphore(value: 0)
        let failure = Box<NWError?>(nil)
        connection.send(
            content: data,
            completion: .contentProcessed { error in
                failure.value = error
                done.signal()
            })
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw IOSDeviceError.handshake("TLS write timed out")
        }
        if let error = failure.value {
            throw IOSDeviceError.handshake("TLS write failed: \(error)")
        }
    }

    func read(_ count: Int, timeout: TimeInterval = 25) throws -> Data {
        var collected = Data()
        collected.reserveCapacity(count)
        while collected.count < count {
            let done = DispatchSemaphore(value: 0)
            let chunk = Box<Data?>(nil)
            let failure = Box<String?>(nil)
            connection.receive(minimumIncompleteLength: 1, maximumLength: count - collected.count) {
                data, _, isComplete, error in
                chunk.value = data
                if let error {
                    failure.value = "TLS read failed: \(error)"
                } else if isComplete, data?.isEmpty != false {
                    failure.value = "device closed the TLS stream"
                }
                done.signal()
            }
            guard done.wait(timeout: .now() + timeout) == .success else {
                throw IOSDeviceError.handshake("TLS read timed out")
            }
            if let data = chunk.value { collected.append(data) }
            if let message = failure.value, collected.count < count {
                throw IOSDeviceError.handshake(message)
            }
        }
        return collected
    }

    func close() { connection.cancel() }
}

/// A value shared between a completion handler and the thread waiting on it.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// A byte channel to a device service: a usbmux tunnel, optionally wrapped in TLS.
final class DeviceChannel {
    private let connection: USBMux.Connection
    private var tls: TLSStream?
    private var bridge: TunnelBridge?

    init(_ connection: USBMux.Connection) { self.connection = connection }
    var fd: Int32 { connection.descriptor }
    /// The negotiated TLS version once `startTLS` has succeeded, for tracing.
    var tlsVersion: String { tls?.negotiatedVersion ?? "" }

    func write(_ data: Data) throws {
        guard let tls else {
            try connection.writeRaw(data)
            return
        }
        try tls.write(data)
    }

    func read(_ count: Int) throws -> Data {
        guard let tls else { return try connection.readRaw(count) }
        return try tls.read(count)
    }

    func startTLS(identity: SecIdentity) throws {
        let bridge = try TunnelBridge(tunnel: fd)
        let stream = try TLSStream(path: bridge.endpointPath, identity: identity)
        bridge.start()
        do {
            try stream.start()
        } catch {
            bridge.close()
            throw error
        }
        self.bridge = bridge
        tls = stream
    }

    func close() {
        tls?.close()
        bridge?.close()
        connection.close()
    }
}

/// Build a client identity (cert + key) from the pairing record's PEM, via LibreSSL's
/// pkcs12 export + SecPKCS12Import (no keychain involvement).
enum DeviceIdentity {
    static func make(certPEM: Data, keyPEM: Data) throws -> SecIdentity {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-afc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let cert = dir.appendingPathComponent("cert.pem")
        let key = dir.appendingPathComponent("key.pem")
        let p12 = dir.appendingPathComponent("id.p12")
        try certPEM.write(to: cert)
        try keyPEM.write(to: key)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "pkcs12", "-export", "-inkey", key.path, "-in", cert.path,
            "-passout", "pass:pathem", "-name", "pathem", "-out", p12.path,
        ]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IOSDeviceError.handshake("openssl pkcs12 failed")
        }

        var items: CFArray?
        let status = SecPKCS12Import(
            try Data(contentsOf: p12) as CFData,
            [kSecImportExportPassphrase as String: "pathem"] as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]],
            let identity = array.first?[kSecImportItemIdentity as String]
        else { throw IOSDeviceError.handshake("SecPKCS12Import failed (\(status))") }
        return identity as! SecIdentity
    }
}

/// iOS device queries that don't need the AFC service.
public enum IOSDevice {
    /// The friendly device name via a lightweight pre-SSL lockdown GetValue (no pairing/TLS),
    /// best-effort. Returns nil if unavailable.
    public static func name(udid: String) -> String? {
        guard let device = (try? USBMux.listDevices())?.first(where: { $0.udid == udid }),
            let channel = try? DeviceChannel(USBMux.connect(deviceID: device.deviceID, port: 62078))
        else { return nil }
        defer { channel.close() }
        do {
            try lockdownSend(channel, ["Request": "QueryType"])
            _ = try lockdownReceive(channel)
            try lockdownSend(channel, ["Request": "GetValue", "Key": "DeviceName"])
            let reply = try lockdownReceive(channel)
            if let name = reply["Value"] as? String, !name.isEmpty { return name }
        } catch {}
        return nil
    }
}

/// An open AFC session over a paired iOS device's media filesystem. One persistent
/// connection, so typed listings (name + dir + size) are cheap. Synchronous + blocking;
/// intended to run in the out-of-process helper.
public final class AFCSession {
    private let lockdown: DeviceChannel  // kept open for the lifetime of the service
    private let afc: DeviceChannel
    private var packetNum: UInt64 = 0

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let isDirectory: Bool
        public let size: Int64
    }

    init(lockdown: DeviceChannel, afc: DeviceChannel) {
        self.lockdown = lockdown
        self.afc = afc
    }

    private static func trace(_ message: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["PATHEM_AFC_TRACE"] != nil {
            FileHandle.standardError.write(Data(("[afc] " + message() + "\n").utf8))
        }
    }

    /// Open an AFC session to the device with the given UDID (full lockdown + TLS handshake).
    public static func open(udid: String) throws -> AFCSession {
        // A device can be attached twice, over USB and over the network. PATHEM_AFC_CONNECTION
        // (USB or Network) picks one for diagnostics; the network path is the one where the
        // device asks for TLS on the service channel as well.
        let attached = try USBMux.listDevices().filter { $0.udid == udid }
        let wanted = ProcessInfo.processInfo.environment["PATHEM_AFC_CONNECTION"]
        guard let device = attached.first(where: { $0.connectionType == wanted }) ?? attached.first
        else { throw IOSDeviceError.noDevice }
        trace("device found (\(device.connectionType))")
        let record = try USBMux.readPairRecord(udid: udid)
        trace("pair record read")
        guard let hostID = record["HostID"] as? String,
            let certPEM = record["HostCertificate"] as? Data,
            let keyPEM = record["HostPrivateKey"] as? Data
        else { throw IOSDeviceError.handshake("incomplete pairing record") }

        let lockdown = DeviceChannel(try USBMux.connect(deviceID: device.deviceID, port: 62078))
        try lockdownSend(lockdown, ["Request": "QueryType"])
        _ = try lockdownReceive(lockdown)
        trace("QueryType ok")

        var start: [String: Any] = ["Request": "StartSession", "HostID": hostID]
        if let buid = record["SystemBUID"] as? String { start["SystemBUID"] = buid }
        try lockdownSend(lockdown, start)
        let session = try lockdownReceive(lockdown)
        trace("StartSession ssl=\(LockdownFraming.isTrue(session["EnableSessionSSL"]))")
        if LockdownFraming.isTrue(session["EnableSessionSSL"]) {
            try lockdown.startTLS(identity: DeviceIdentity.make(certPEM: certPEM, keyPEM: keyPEM))
            trace("session TLS up (Network.framework, \(lockdown.tlsVersion))")
        }

        try lockdownSend(lockdown, ["Request": "StartService", "Service": "com.apple.afc"])
        let service = try lockdownReceive(lockdown)
        guard let port = service["Port"] as? Int else {
            throw IOSDeviceError.handshake("StartService returned no port")
        }
        trace(
            "StartService port=\(port) ssl=\(LockdownFraming.isTrue(service["EnableServiceSSL"]))")
        let afc = DeviceChannel(try USBMux.connect(deviceID: device.deviceID, port: port))
        if LockdownFraming.isTrue(service["EnableServiceSSL"]) {
            try afc.startTLS(identity: DeviceIdentity.make(certPEM: certPEM, keyPEM: keyPEM))
            trace("service TLS up (Network.framework, \(afc.tlsVersion))")
        }
        trace("afc connected")
        return AFCSession(lockdown: lockdown, afc: afc)
    }

    public func close() {
        afc.close()
        lockdown.close()
    }

    // MARK: AFC operations

    /// Directory entries with type and size (one READ_DIR + a GET_FILE_INFO per child).
    public func list(_ path: String) throws -> [Entry] {
        let names = AFCPacket.directoryEntries(
            try expectData(.readDir, AFCPacket.pathPayload(path)))
        Self.trace("readDir \(path) -> \(names.count) names")
        let base = path.hasSuffix("/") ? path : path + "/"
        return names.enumerated().map { index, name in
            let info = (try? fileInfo(base + name)) ?? [:]
            Self.trace("  info[\(index)] \(name) dir=\(AFCPacket.isDirectory(info))")
            return Entry(
                name: name, isDirectory: AFCPacket.isDirectory(info), size: AFCPacket.size(info))
        }
    }

    public func fileInfo(_ path: String) throws -> [String: String] {
        AFCPacket.fileInfo(try expectData(.getFileInfo, AFCPacket.pathPayload(path)))
    }

    public func makeDirectory(_ path: String) throws {
        try expectStatus(.makeDir, AFCPacket.pathPayload(path))
    }

    public func remove(_ path: String) throws {
        try expectStatus(.removePath, AFCPacket.pathPayload(path))
    }

    public func rename(from: String, to: String) throws {
        try expectStatus(.renamePath, AFCPacket.renamePayload(from: from, to: to))
    }

    public func readFile(_ path: String) throws -> Data {
        let handle = try openFile(path, mode: .read)
        defer { try? closeFile(handle) }
        var data = Data()
        while true {
            let chunk = try expectData(
                .fileRead, AFCPacket.readPayload(handle: handle, length: 1 << 18))
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    public func writeFile(_ path: String, data: Data) throws {
        let handle = try openFile(path, mode: .write)
        defer { try? closeFile(handle) }
        let handleHeader = AFCPacket.handlePayload(handle)
        var offset = 0
        let chunkSize = 1 << 18
        repeat {
            let end = Swift.min(offset + chunkSize, data.count)
            // FILE_WRITE: handle is the header, the bytes are the data payload.
            let packet = AFCPacket.encode(
                .fileWrite, packetNum: packetNum, header: handleHeader,
                data: data.subdata(in: offset..<end))
            let reply = try transactRaw(packet)
            if reply.op == AFCPacket.Op.status.rawValue, let code = AFCPacket.status(reply.payload),
                code != 0
            {
                throw IOSDeviceError.afc(code)
            }
            offset = end
        } while offset < data.count
    }

    // MARK: AFC framing

    private func openFile(_ path: String, mode: AFCPacket.OpenMode) throws -> UInt64 {
        let payload = try expectData(.fileOpen, AFCPacket.openPayload(mode: mode, path: path))
        guard let handle = AFCPacket.handle(payload) else { throw IOSDeviceError.afc(0) }
        return handle
    }

    private func closeFile(_ handle: UInt64) throws {
        try expectStatus(.fileClose, AFCPacket.handlePayload(handle))
    }

    /// Send an AFC request and return the raw (operation, payload) of the reply.
    private func transact(_ op: AFCPacket.Op, _ payload: Data) throws -> (op: UInt64, payload: Data)
    {
        try transactRaw(AFCPacket.encode(op, packetNum: packetNum, payload: payload))
    }

    /// Write a pre-built AFC packet and read the reply (operation, payload).
    private func transactRaw(_ packet: Data) throws -> (op: UInt64, payload: Data) {
        try afc.write(packet)
        packetNum += 1
        guard let header = AFCPacket.decodeHeader(try afc.read(AFCPacket.headerSize)) else {
            throw IOSDeviceError.afc(0)
        }
        let body = Int(header.entireLength) - AFCPacket.headerSize
        return (header.operation, body > 0 ? try afc.read(body) : Data())
    }

    /// Expect a DATA reply; surface an AFC STATUS error code if one comes back instead.
    private func expectData(_ op: AFCPacket.Op, _ payload: Data) throws -> Data {
        let reply = try transact(op, payload)
        if reply.op == AFCPacket.Op.status.rawValue {
            let code = AFCPacket.status(reply.payload) ?? 0
            if code != 0 { throw IOSDeviceError.afc(code) }
            return Data()
        }
        return reply.payload
    }

    /// Expect a STATUS reply with code 0.
    private func expectStatus(_ op: AFCPacket.Op, _ payload: Data) throws {
        let reply = try transact(op, payload)
        let code = AFCPacket.status(reply.payload) ?? 0
        if reply.op == AFCPacket.Op.status.rawValue, code != 0 { throw IOSDeviceError.afc(code) }
    }
}

// MARK: lockdown plist framing ([uint32 big-endian length][XML plist])

private func lockdownSend(_ channel: DeviceChannel, _ plist: [String: Any]) throws {
    let payload = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
    try channel.write(LockdownFraming.frame(payload))
}

private func lockdownReceive(_ channel: DeviceChannel) throws -> [String: Any] {
    let header = try channel.read(4)
    let payload = try channel.read(LockdownFraming.payloadLength(Array(header)))
    return
        (try PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        ?? [:]
}

/// The lockdown wire framing: a 4-byte big-endian length prefix followed by an XML-plist
/// payload. Extracted so the byte math is unit-tested; a framing bug desyncs the whole
/// session (every subsequent read is off by the mistake).
enum LockdownFraming {
    /// Prefix `payload` with its length as a 4-byte big-endian header.
    static func frame(_ payload: Data) -> Data {
        var out = Data()
        var beLength = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &beLength) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Decode the payload length from a 4-byte big-endian header.
    static func payloadLength(_ header: [UInt8]) -> Int {
        Int(
            (UInt32(header[0]) << 24) | (UInt32(header[1]) << 16) | (UInt32(header[2]) << 8)
                | UInt32(header[3]))
    }

    /// Coerce a plist value to a boolean: lockdown replies use both real booleans and 0/1.
    static func isTrue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? Int { return number != 0 }
        return false
    }
}
