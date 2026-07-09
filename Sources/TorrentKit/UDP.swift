import Foundation

#if canImport(Network)
    import Network

    /// A one-shot UDP request/response helper shared by the DHT and NAT-PMP clients: send a
    /// datagram to host:port and return the first datagram that comes back (nil on timeout/failure).
    enum UDP {
        static func query(host: String, port: UInt16, payload: Data, timeout: TimeInterval) async -> Data? {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
            let conn = NWConnection(host: .init(host), port: nwPort, using: .udp)
            let box = DatagramBox()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: payload, completion: .contentProcessed { _ in })
                    conn.receiveMessage { data, _, _, _ in box.resume(data) }
                case .failed, .cancelled:
                    box.resume(nil)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { box.resume(nil) }
            conn.start(queue: queue)
            let result = await box.value()
            conn.cancel()
            return result
        }

        static let queue = DispatchQueue(label: "com.pathem.torrent.udp", attributes: .concurrent)
    }

    /// One-shot async box for a single UDP datagram (resumes with nil on timeout/failure).
    final class DatagramBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var settled = false
        private var pending: Data??  // holds a value delivered before value() is awaited

        func value() async -> Data? {
            await withCheckedContinuation { cont in
                lock.lock()
                if let pending {
                    lock.unlock()
                    cont.resume(returning: pending)
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }

        func resume(_ data: Data?) {
            lock.lock()
            if settled { lock.unlock(); return }
            settled = true
            let cont = continuation
            continuation = nil
            if cont == nil { pending = .some(data) }
            lock.unlock()
            cont?.resume(returning: data)
        }
    }
#endif
