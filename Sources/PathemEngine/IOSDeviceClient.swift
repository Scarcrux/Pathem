import Foundation
import Security

#if canImport(Darwin)
    import Darwin
#endif

// SecureTransport over a raw usbmux fd. It's deprecated, but it's the only API that does
// TLS over a custom transport (our usbmux tunnel) with a client certificate; Network.framework
// can't wrap an existing socket. This whole client is meant to run in an out-of-process helper.

private final class TLSBox { let fd: Int32; init(_ fd: Int32) { self.fd = fd } }

private func tlsRead(_ conn: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ len: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Unmanaged<TLSBox>.fromOpaque(conn).takeUnretainedValue().fd
    let want = len.pointee
    var got = 0
    while got < want {
        let n = read(fd, data.advanced(by: got), want - got)
        if n > 0 { got += n; continue }
        if n == 0 { len.pointee = got; return errSSLClosedGraceful }
        if errno == EINTR { continue }
        len.pointee = got
        return errSSLClosedAbort
    }
    len.pointee = got
    return noErr
}

private func tlsWrite(_ conn: SSLConnectionRef, _ data: UnsafeRawPointer, _ len: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Unmanaged<TLSBox>.fromOpaque(conn).takeUnretainedValue().fd
    let want = len.pointee
    var sent = 0
    while sent < want {
        let n = write(fd, data.advanced(by: sent), want - sent)
        if n > 0 { sent += n; continue }
        if errno == EINTR { continue }
        len.pointee = sent
        return errSSLClosedAbort
    }
    len.pointee = sent
    return noErr
}

public enum IOSDeviceError: Error, Sendable {
    case noDevice
    case handshake(String)
    case afc(UInt64)  // AFC STATUS error code
    case tls(OSStatus)
}

/// A byte channel to a device service: a usbmux tunnel, optionally wrapped in TLS.
final class DeviceChannel {
    private let connection: USBMux.Connection
    private var ssl: SSLContext?
    private var box: Unmanaged<TLSBox>?

    init(_ connection: USBMux.Connection) { self.connection = connection }
    var fd: Int32 { connection.descriptor }

    func write(_ data: Data) throws {
        guard let ssl else { try connection.writeRaw(data); return }
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                var processed = 0
                let status = SSLWrite(ssl, raw.baseAddress!.advanced(by: sent), data.count - sent, &processed)
                guard status == errSecSuccess else { throw IOSDeviceError.tls(status) }
                sent += processed
            }
        }
    }

    func read(_ count: Int) throws -> Data {
        guard let ssl else { return try connection.readRaw(count) }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            var processed = 0
            let status = buffer.withUnsafeMutableBytes {
                SSLRead(ssl, $0.baseAddress!.advanced(by: got), count - got, &processed)
            }
            guard status == errSecSuccess || status == -9803 else { throw IOSDeviceError.tls(status) }  // -9803 = wouldBlock
            got += processed
        }
        return Data(buffer)
    }

    func startTLS(identity: SecIdentity) throws {
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw IOSDeviceError.tls(-1)
        }
        let box = TLSBox(fd)
        let retained = Unmanaged.passRetained(box)
        self.box = retained
        SSLSetConnection(context, retained.toOpaque())
        SSLSetIOFuncs(context, tlsRead, tlsWrite)
        guard SSLSetCertificate(context, [identity] as CFArray) == errSecSuccess else {
            throw IOSDeviceError.tls(-2)
        }
        SSLSetSessionOption(context, .breakOnServerAuth, true)  // device cert is self-signed; we don't verify
        let peerAuthCompleted: OSStatus = -9841
        let clientCertRequested: OSStatus = -9842
        var status = SSLHandshake(context)
        while status == peerAuthCompleted || status == clientCertRequested { status = SSLHandshake(context) }
        guard status == errSecSuccess else { throw IOSDeviceError.tls(status) }
        ssl = context
    }

    func close() {
        if let ssl { SSLClose(ssl) }
        box?.release()
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
        guard process.terminationStatus == 0 else { throw IOSDeviceError.handshake("openssl pkcs12 failed") }

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
        guard let device = try USBMux.listDevices().first(where: { $0.udid == udid }) else {
            throw IOSDeviceError.noDevice
        }
        trace("device found")
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
        trace("StartSession ssl=\(isTrue(session["EnableSessionSSL"]))")
        if isTrue(session["EnableSessionSSL"]) {
            try lockdown.startTLS(identity: DeviceIdentity.make(certPEM: certPEM, keyPEM: keyPEM))
            trace("session TLS up")
        }

        try lockdownSend(lockdown, ["Request": "StartService", "Service": "com.apple.afc"])
        let service = try lockdownReceive(lockdown)
        guard let port = service["Port"] as? Int else {
            throw IOSDeviceError.handshake("StartService returned no port")
        }
        trace("StartService port=\(port) ssl=\(isTrue(service["EnableServiceSSL"]))")
        let afc = DeviceChannel(try USBMux.connect(deviceID: device.deviceID, port: port))
        if isTrue(service["EnableServiceSSL"]) {
            try afc.startTLS(identity: DeviceIdentity.make(certPEM: certPEM, keyPEM: keyPEM))
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
        let names = AFCPacket.directoryEntries(try expectData(.readDir, AFCPacket.pathPayload(path)))
        Self.trace("readDir \(path) -> \(names.count) names")
        let base = path.hasSuffix("/") ? path : path + "/"
        return names.enumerated().map { index, name in
            let info = (try? fileInfo(base + name)) ?? [:]
            Self.trace("  info[\(index)] \(name) dir=\(AFCPacket.isDirectory(info))")
            return Entry(name: name, isDirectory: AFCPacket.isDirectory(info), size: AFCPacket.size(info))
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
            let chunk = try expectData(.fileRead, AFCPacket.readPayload(handle: handle, length: 1 << 18))
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
                .fileWrite, packetNum: packetNum, header: handleHeader, data: data.subdata(in: offset..<end))
            let reply = try transactRaw(packet)
            if reply.op == AFCPacket.Op.status.rawValue, let code = AFCPacket.status(reply.payload), code != 0 {
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
    private func transact(_ op: AFCPacket.Op, _ payload: Data) throws -> (op: UInt64, payload: Data) {
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
    let payload = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    var frame = Data()
    var beLength = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &beLength) { frame.append(contentsOf: $0) }
    frame.append(payload)
    try channel.write(frame)
}

private func lockdownReceive(_ channel: DeviceChannel) throws -> [String: Any] {
    let header = try channel.read(4)
    let length = (UInt32(header[0]) << 24) | (UInt32(header[1]) << 16) | (UInt32(header[2]) << 8) | UInt32(header[3])
    let payload = try channel.read(Int(length))
    return (try PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any]) ?? [:]
}

private func isTrue(_ value: Any?) -> Bool {
    if let flag = value as? Bool { return flag }
    if let number = value as? Int { return number != 0 }
    return false
}
