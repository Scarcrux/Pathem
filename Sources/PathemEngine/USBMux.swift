import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Minimal client for macOS's `usbmuxd` (the `/var/run/usbmuxd` Unix socket that multiplexes
/// connections to attached iOS devices over USB). This is layer 1 of a native AFC client:
/// it lists devices, reads a pairing record, and opens a tunnel to a device port. The frame
/// codec is pure and unit-tested; `listDevices()` does a real round-trip with the daemon.
///
/// Wire format: a 16-byte little-endian header { length, version=1, message=8(plist), tag }
/// followed by an XML/binary property list payload.
public enum USBMux {
    public static let socketPath = "/var/run/usbmuxd"

    public struct Device: Sendable, Equatable {
        public let deviceID: Int
        public let udid: String
        public let connectionType: String
    }

    public enum USBMuxError: Error, Sendable {
        case socket(String)
        case badResponse
        case refused(Int)  // usbmuxd Result number != 0
    }

    // MARK: Pure frame codec (tested without a socket)

    enum Frame {
        static let version: UInt32 = 1
        static let messagePlist: UInt32 = 8

        /// Encode a plist payload into a tagged usbmux packet.
        static func encode(tag: UInt32, plist: [String: Any]) throws -> Data {
            let payload = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            var data = Data()
            append(&data, UInt32(16 + payload.count))
            append(&data, version)
            append(&data, messagePlist)
            append(&data, tag)
            data.append(payload)
            return data
        }

        /// Total packet length declared in a 16-byte header (or nil if malformed).
        static func payloadLength(header: Data) -> Int? {
            guard header.count >= 16 else { return nil }
            let total = Int(readUInt32(header, at: header.startIndex))
            return total >= 16 ? total - 16 : nil
        }

        static func decodePlist(_ payload: Data) -> [String: Any]? {
            (try? PropertyListSerialization.propertyList(from: payload, format: nil)) as? [String: Any]
        }

        private static func append(_ data: inout Data, _ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        static func readUInt32(_ data: Data, at index: Data.Index) -> UInt32 {
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(data[index + i]) << (8 * i) }
            return value
        }
    }

    /// Parse a `ListDevices` reply plist into Device values (pure, tested).
    static func parseDeviceList(_ reply: [String: Any]) -> [Device] {
        guard let list = reply["DeviceList"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let id = entry["DeviceID"] as? Int,
                let props = entry["Properties"] as? [String: Any],
                let udid = props["SerialNumber"] as? String
            else { return nil }
            return Device(
                deviceID: id, udid: udid,
                connectionType: (props["ConnectionType"] as? String) ?? "USB")
        }
    }

    // MARK: Live transport

    /// List attached iOS devices by round-tripping `ListDevices` with usbmuxd. Returns an
    /// empty array when nothing is attached; throws only on a transport failure.
    public static func listDevices() throws -> [Device] {
        let connection = try Connection()
        defer { connection.close() }
        let request: [String: Any] = [
            "MessageType": "ListDevices", "ClientVersionString": "Pathem", "ProgName": "Pathem",
            "kLibUSBMuxVersion": 3,
        ]
        try connection.send(Frame.encode(tag: 1, plist: request))
        guard let reply = try connection.receivePlist() else { throw USBMuxError.badResponse }
        return parseDeviceList(reply)
    }

    /// Read the device's pairing record (HostID, SystemBUID, certificates) that usbmuxd
    /// stores, used for the lockdown TLS handshake.
    public static func readPairRecord(udid: String) throws -> [String: Any] {
        let connection = try Connection()
        defer { connection.close() }
        try connection.send(
            Frame.encode(tag: 1, plist: ["MessageType": "ReadPairRecord", "PairRecordID": udid]))
        guard let reply = try connection.receivePlist() else { throw USBMuxError.badResponse }
        guard let recordData = reply["PairRecordData"] as? Data,
            let record = try PropertyListSerialization.propertyList(from: recordData, format: nil)
                as? [String: Any]
        else { throw USBMuxError.badResponse }
        return record
    }

    /// Open a raw tunnel to `port` on the device. After this returns, the connection carries
    /// the device service's bytes directly (lockdown on 62078, then the AFC service port).
    public static func connect(deviceID: Int, port: Int) throws -> Connection {
        let connection = try Connection()
        // usbmuxd wants the port in network byte order.
        let networkPort = Int(UInt16(port).bigEndian)
        try connection.send(
            Frame.encode(
                tag: 1, plist: ["MessageType": "Connect", "DeviceID": deviceID, "PortNumber": networkPort]))
        guard let reply = try connection.receivePlist(), let number = reply["Number"] as? Int else {
            connection.close()
            throw USBMuxError.badResponse
        }
        guard number == 0 else {
            connection.close()
            throw USBMuxError.refused(number)
        }
        return connection
    }

    /// A connected usbmuxd socket. Not Sendable; used within a single call. After `connect`,
    /// it is a raw byte tunnel to a device port (`writeRaw`/`readRaw`).
    public final class Connection {
        private let fd: Int32
        /// The underlying descriptor, for layering TLS over the tunnel.
        public var descriptor: Int32 { fd }

        init() throws {
            #if canImport(Darwin)
                let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
                guard descriptor >= 0 else { throw USBMuxError.socket("socket() failed") }
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let limit = MemoryLayout.size(ofValue: addr.sun_path) - 1
                _ = withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                    USBMux.socketPath.withCString { src in
                        memcpy(dst, src, Swift.min(strlen(src), limit))
                    }
                }
                let length = socklen_t(MemoryLayout<sockaddr_un>.size)
                let result = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, length) }
                }
                guard result == 0 else {
                    Darwin.close(descriptor)
                    throw USBMuxError.socket("connect(\(USBMux.socketPath)) failed")
                }
                // Bound reads/writes so a locked device (AFC stalls when the data partition
                // re-encrypts) fails fast instead of hanging.
                var timeout = timeval(tv_sec: 25, tv_usec: 0)
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                fd = descriptor
            #else
                throw USBMuxError.socket("usbmux is only available on macOS")
            #endif
        }

        public func close() {
            #if canImport(Darwin)
                Darwin.close(fd)
            #endif
        }

        /// Write all of `data` to the raw tunnel.
        public func writeRaw(_ data: Data) throws { try send(data) }

        /// Read exactly `count` bytes from the raw tunnel.
        public func readRaw(_ count: Int) throws -> Data { try readExactly(count) }

        func send(_ data: Data) throws {
            #if canImport(Darwin)
                try data.withUnsafeBytes { raw in
                    var sent = 0
                    let base = raw.bindMemory(to: UInt8.self).baseAddress!
                    while sent < data.count {
                        let n = write(fd, base + sent, data.count - sent)
                        if n < 0 {
                            if errno == EINTR { continue }
                            throw USBMuxError.socket("write() failed")
                        }
                        sent += n
                    }
                }
            #endif
        }

        /// Read one framed packet and decode its plist payload.
        func receivePlist() throws -> [String: Any]? {
            let header = try readExactly(16)
            guard let payloadLength = Frame.payloadLength(header: header) else { throw USBMuxError.badResponse }
            let payload = payloadLength > 0 ? try readExactly(payloadLength) : Data()
            return Frame.decodePlist(payload)
        }

        private func readExactly(_ count: Int) throws -> Data {
            #if canImport(Darwin)
                var buffer = [UInt8](repeating: 0, count: count)
                var got = 0
                while got < count {
                    let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw USBMuxError.socket("read() failed")
                    }
                    if n == 0 { throw USBMuxError.badResponse }  // closed early
                    got += n
                }
                return Data(buffer)
            #else
                throw USBMuxError.socket("unavailable")
            #endif
        }
    }
}
