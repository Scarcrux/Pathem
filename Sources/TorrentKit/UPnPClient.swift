import Foundation

#if canImport(Network)
    import Network

    /// Best-effort UPnP-IGD port mapping: discovers the gateway over SSDP multicast, fetches its
    /// description, and POSTs a SOAP AddPortMapping. Used as a fallback when NAT-PMP gets no answer.
    /// Routers without UPnP simply yield nothing.
    public actor UPnPClient {
        public init() {}

        /// Try to map `port` (TCP) via UPnP. Returns true on a successful AddPortMapping.
        public func mapTCP(port: UInt16, timeout: TimeInterval = 5) async -> Bool {
            guard let location = await discover(timeout: timeout),
                let descriptionURL = URL(string: location),
                let (xml, _) = try? await fetch(descriptionURL),
                let (controlURL, serviceType) = UPnP.controlURL(fromDescription: xml, descriptionURL: descriptionURL),
                let localIP = Self.primaryIPv4()
            else { return false }

            let body = UPnP.addPortMappingBody(
                serviceType: serviceType, externalPort: port, internalPort: port, internalClient: localIP)
            var request = URLRequest(url: controlURL)
            request.httpMethod = "POST"
            request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
            request.setValue(UPnP.addPortMappingAction(serviceType: serviceType), forHTTPHeaderField: "SOAPAction")
            request.httpBody = body
            request.timeoutInterval = timeout
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                let http = response as? HTTPURLResponse
            else { return false }
            return http.statusCode == 200
        }

        /// SSDP: multicast an M-SEARCH and return the first gateway's description LOCATION.
        private func discover(timeout: TimeInterval) async -> String? {
            guard
                let group = try? NWMulticastGroup(
                    for: [.hostPort(host: .init(UPnP.ssdpHost), port: .init(rawValue: UPnP.ssdpPort)!)])
            else { return nil }
            let connection = NWConnectionGroup(with: group, using: .udp)
            let box = LocationBox()

            connection.setReceiveHandler(maximumMessageSize: 65536, rejectOversizedMessages: true) { _, content, _ in
                if let content, let location = UPnP.parseLocation(content) { box.resume(location) }
            }
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: UPnP.searchRequest(), completion: { _ in })
                }
            }
            connection.start(queue: Self.queue)
            Self.queue.asyncAfter(deadline: .now() + timeout) { box.resume(nil) }
            let result = await box.value()
            connection.cancel()
            return result
        }

        private func fetch(_ url: URL) async throws -> (Data, URLResponse) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            return try await URLSession.shared.data(for: request)
        }

        /// Our primary non-loopback IPv4 address (for NewInternalClient in the SOAP request).
        static func primaryIPv4() -> String? {
            var address: String?
            var ifaddr: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
            defer { freeifaddrs(ifaddr) }
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let flags = Int32(ptr.pointee.ifa_flags)
                guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                    let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
                else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254") {  // skip link-local
                        address = ip
                        let name = String(cString: ptr.pointee.ifa_name)
                        if name == "en0" { break }  // prefer the main interface
                    }
                }
            }
            return address
        }

        private static let queue = DispatchQueue(label: "com.pathem.torrent.upnp")
    }

    /// One-shot async box for the first SSDP location.
    private final class LocationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        private var settled = false
        private var pending: String??
        func value() async -> String? {
            await withCheckedContinuation { cont in
                lock.lock()
                if let pending { lock.unlock(); cont.resume(returning: pending) }
                else { continuation = cont; lock.unlock() }
            }
        }
        func resume(_ value: String?) {
            lock.lock()
            if settled { lock.unlock(); return }
            settled = true
            let cont = continuation
            continuation = nil
            if cont == nil { pending = .some(value) }
            lock.unlock()
            cont?.resume(returning: value)
        }
    }
#endif
