import Darwin
import Foundation

@testable import PathemEngine

/// A fake adb server on 127.0.0.1 speaking the real wire format: host services framed by
/// 4 hex digits (OKAY / FAIL replies), then the sync service (LIST, STAT, RECV, SEND with
/// DENT / DONE / DATA framing, v1 and v2). It needs no device and no adb binary.
final class FakeADBServer: @unchecked Sendable {
    struct Device {
        var serial: String
        var state: String = "device"
        var model: String = "Pixel_8"
    }

    enum Node {
        case file(Data, mtime: Int64, declaredSize: UInt64?)
        case directory(mtime: Int64)
    }

    private let lock = NSLock()
    private var listener: Int32 = -1
    private(set) var port: UInt16 = 0
    var devices: [Device] = [Device(serial: "ABC123")]
    var features: Set<String> = ["ls_v2", "stat_v2"]
    private var nodes: [String: Node] = [:]
    private var uploads: [String: (data: Data, mode: UInt32, mtime: UInt32)] = [:]
    private(set) var commandsSeen: [String] = []

    init(port requestedPort: UInt16 = 0) throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 8) == 0 else {
            throw NSError(domain: "FakeADBServer", code: Int(errno))
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)
        let socketFD = listener
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(socketFD, nil, nil)
                if client < 0 { return }
                var one: Int32 = 1
                setsockopt(
                    client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { [weak self] in
                    guard let self else {
                        Darwin.close(client)
                        return
                    }
                    self.serve(client)
                }
            }
        }
    }

    func stop() {
        if listener >= 0 {
            _ = shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
            listener = -1
        }
    }

    // MARK: Content

    func addFile(
        _ path: String, _ data: Data, mtime: Int64 = 1_700_000_000, declaredSize: UInt64? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        nodes[path] = .file(data, mtime: mtime, declaredSize: declaredSize)
    }

    func addDirectory(_ path: String, mtime: Int64 = 1_700_000_000) {
        lock.lock()
        defer { lock.unlock() }
        nodes[path] = .directory(mtime: mtime)
    }

    func upload(_ path: String) -> (data: Data, mode: UInt32, mtime: UInt32)? {
        lock.lock()
        defer { lock.unlock() }
        return uploads[path]
    }

    private func node(_ path: String) -> Node? {
        lock.lock()
        defer { lock.unlock() }
        return nodes[path]
    }

    private func children(of path: String) -> [(String, Node)] {
        lock.lock()
        defer { lock.unlock() }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return nodes.compactMap { key, value in
            guard key.hasPrefix(prefix), !key.dropFirst(prefix.count).contains("/") else {
                return nil
            }
            return (String(key.dropFirst(prefix.count)), value)
        }.sorted { $0.0 < $1.0 }
    }

    private func record(_ command: String) {
        lock.lock()
        commandsSeen.append(command)
        lock.unlock()
    }

    // MARK: I/O

    private func readExact(_ fd: Int32, _ count: Int) -> Data? {
        var buffer = Data(count: count)
        var offset = 0
        let ok = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            while offset < count {
                let n = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? buffer : nil
    }

    private func send(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, data.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    private func okay(_ fd: Int32, payload: String? = nil) {
        var out = Data("OKAY".utf8)
        if let payload { out += ADBWire.hostRequest(payload) }
        send(fd, out)
    }

    private func fail(_ fd: Int32, _ message: String) {
        send(fd, Data("FAIL".utf8) + ADBWire.hostRequest(message))
    }

    private func le32(_ value: UInt32) -> Data { ADBWire.syncHeader("XXXX", value).dropFirst(4) }
    private func le64(_ value: UInt64) -> Data {
        le32(UInt32(truncatingIfNeeded: value)) + le32(UInt32(value >> 32))
    }

    // MARK: Conversation

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        guard let prefix = readExact(fd, 4), let length = try? ADBWire.hexLength(prefix),
            let body = readExact(fd, length)
        else { return }
        let request = String(decoding: body, as: UTF8.self)
        record(request)
        switch request {
        case "host:version": okay(fd, payload: "0029")
        case "host:devices-l":
            let text = devices.map {
                "\($0.serial)\t\($0.state) usb:1-1 product:x model:\($0.model) device:y transport_id:1"
            }.joined(separator: "\n")
            okay(fd, payload: text + "\n")
        case _ where request.hasPrefix("host-serial:") && request.hasSuffix(":features"):
            okay(fd, payload: features.sorted().joined(separator: ","))
        case _ where request.hasPrefix("host:transport:"):
            let serial = String(request.dropFirst("host:transport:".count))
            guard let device = devices.first(where: { $0.serial == serial }) else {
                return fail(fd, "device '\(serial)' not found")
            }
            switch device.state {
            case "unauthorized":
                return fail(
                    fd, "device unauthorized.\nPlease check the confirmation dialog on your device."
                )
            case "offline": return fail(fd, "device offline")
            default: break
            }
            okay(fd)
            guard let next = readExact(fd, 4), let n = try? ADBWire.hexLength(next),
                let service = readExact(fd, n), String(decoding: service, as: UTF8.self) == "sync:"
            else { return }
            okay(fd)
            syncLoop(fd)
        default: fail(fd, "unknown host service")
        }
    }

    private func syncLoop(_ fd: Int32) {
        while let header = readExact(fd, 8) {
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            let length = Int((try? ADBWire.uint32(header, at: 4)) ?? 0)
            switch id {
            case "QUIT": return
            case "LIST", "LIS2", "STAT", "STA2", "RECV":
                guard let raw = readExact(fd, length) else { return }
                let path = String(decoding: raw, as: UTF8.self)
                record("\(id) \(path)")
                switch id {
                case "LIST": list(fd, path, v2: false)
                case "LIS2": list(fd, path, v2: true)
                case "STAT": stat(fd, path, v2: false)
                case "STA2": stat(fd, path, v2: true)
                default: recv(fd, path)
                }
            case "SEND":
                guard let raw = readExact(fd, length) else { return }
                record("SEND \(String(decoding: raw, as: UTF8.self))")
                guard receiveUpload(fd, spec: String(decoding: raw, as: UTF8.self)) else { return }
            default: return
            }
        }
    }

    private func attributes(_ node: Node) -> (mode: UInt32, size: UInt64, mtime: Int64) {
        switch node {
        case .directory(let mtime): return (0o040755, 4096, mtime)
        case .file(let data, let mtime, let declared):
            return (0o100644, declared ?? UInt64(data.count), mtime)
        }
    }

    private func statV2Body(error: UInt32, _ a: (mode: UInt32, size: UInt64, mtime: Int64)) -> Data
    {
        var data = le32(error)
        data.append(le64(1))
        data.append(le64(2))
        for field: UInt32 in [a.mode, 1, 0, 0] { data.append(le32(field)) }
        data.append(le64(a.size))
        for _ in 0..<3 { data.append(le64(UInt64(bitPattern: a.mtime))) }
        return data
    }

    private func list(_ fd: Int32, _ path: String, v2: Bool) {
        guard let dir = node(path), case .directory = dir else {
            return send(
                fd,
                Data("FAIL".utf8) + le32(UInt32("No such directory".utf8.count))
                    + Data("No such directory".utf8))
        }
        let selfEntries: [(String, Node)] = [(".", dir), ("..", dir)]
        for (name, child) in selfEntries + children(of: path) {
            let a = attributes(child)
            let nameData = Data(name.utf8)
            if v2 {
                send(
                    fd,
                    Data("DNT2".utf8) + statV2Body(error: 0, a) + le32(UInt32(nameData.count))
                        + nameData)
            } else {
                send(
                    fd,
                    Data("DENT".utf8) + le32(a.mode) + le32(UInt32(truncatingIfNeeded: a.size))
                        + le32(UInt32(truncatingIfNeeded: a.mtime)) + le32(UInt32(nameData.count))
                        + nameData)
            }
        }
        send(fd, Data("DONE".utf8) + Data(count: v2 ? 72 : 16))
    }

    private func stat(_ fd: Int32, _ path: String, v2: Bool) {
        let a = node(path).map(attributes) ?? (mode: 0, size: 0, mtime: 0)
        if v2 {
            send(fd, Data("STA2".utf8) + statV2Body(error: a.mode == 0 ? 2 : 0, a))
        } else {
            send(
                fd,
                Data("STAT".utf8) + le32(a.mode) + le32(UInt32(truncatingIfNeeded: a.size))
                    + le32(UInt32(truncatingIfNeeded: a.mtime)))
        }
    }

    private func recv(_ fd: Int32, _ path: String) {
        guard let found = node(path), case .file(let data, _, _) = found else {
            let message = "No such file or directory"
            return send(
                fd, Data("FAIL".utf8) + le32(UInt32(message.utf8.count)) + Data(message.utf8))
        }
        var offset = 0
        while offset < data.count {
            let end = min(offset + ADBWire.maxChunk, data.count)
            send(fd, Data("DATA".utf8) + le32(UInt32(end - offset)) + data[offset..<end])
            offset = end
        }
        send(fd, Data("DONE".utf8) + le32(0))
    }

    private func receiveUpload(_ fd: Int32, spec: String) -> Bool {
        let parts = spec.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2, let mode = UInt32(parts[1]) else { return false }
        var data = Data()
        while let header = readExact(fd, 8) {
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            let value = (try? ADBWire.uint32(header, at: 4)) ?? 0
            if id == "DATA" {
                guard let chunk = readExact(fd, Int(value)) else { return false }
                data += chunk
            } else if id == "DONE" {
                lock.lock()
                uploads[parts[0]] = (data, mode, value)
                lock.unlock()
                send(fd, Data("OKAY".utf8) + le32(0))
                return true
            } else {
                return false
            }
        }
        return false
    }
}
