import Foundation

#if canImport(Network)
    import Network

    /// Watches the network and reports which VPN tunnel, if any, is currently the *anonymizing* VPN
    /// -- so the engine can bind torrent traffic to it and pull a kill-switch when it drops.
    ///
    /// Detecting the right VPN on macOS takes two filters:
    ///
    /// 1. **It must carry the default route.** A full-tunnel anonymizing VPN (AdGuard, Nord, Proton,
    ///    ...) takes over the default route so *all* traffic is tunneled. A split-tunnel overlay like
    ///    Tailscale stays up but never becomes the default route -- binding torrents to it would be
    ///    wrong, so it must be ignored. The default-route interface is the signal that separates them.
    /// 2. **It must be a real tunnel.** The default-route interface then has to be a point-to-point,
    ///    up interface with a VPN-style name and a routable address (not a physical `enN`), confirmed
    ///    from `getifaddrs` -- and matched to an `NWInterface` the path layer exposes so it can be
    ///    bound.
    public actor VPNMonitor {
        private let monitor = NWPathMonitor()
        private var currentName: String?
        private var onChange: (@Sendable (String?) -> Void)?
        private var started = false

        public init() {}

        /// Start watching. Whenever the active VPN tunnel changes, this updates `NetworkBinding`
        /// (so new sockets pin to the tunnel) and calls `onChange` with the tunnel's name -- or `nil`
        /// when it drops -- on the monitor's queue. Setting the binding here keeps the non-Sendable
        /// `NWInterface` on this side of the actor boundary; only the name crosses. Idempotent.
        public func start(onChange: @escaping @Sendable (String?) -> Void) {
            guard !started else { return }
            started = true
            self.onChange = onChange
            monitor.pathUpdateHandler = { [weak self] path in
                Task { await self?.evaluate(path) }
            }
            monitor.start(queue: Self.queue)
        }

        /// Evaluate the current path right now and always notify (deterministic initial resolution:
        /// binding is set and the engine hears the result -- even "no VPN" -- immediately, rather than
        /// waiting for the first async path callback).
        public func evaluateNow() {
            evaluate(monitor.currentPath, force: true)
        }

        /// Stop watching and clear any binding this monitor set.
        public func stop() {
            monitor.cancel()
            started = false
            currentName = nil
            NetworkBinding.shared.requiredInterface = nil
        }

        /// The active anonymizing VPN's name right now (nil if none), computed on demand.
        public func activeVPNName() -> String? { Self.anonymizingVPNName() }

        private func evaluate(_ path: NWPath, force: Bool = false) {
            let name = Self.anonymizingVPNName()
            // We can only enforce binding if the path layer exposes an NWInterface for the tunnel; if
            // it doesn't, treat it as no-VPN so the kill-switch engages rather than running unbound.
            let iface = name.flatMap { n in path.availableInterfaces.first { $0.name == n } }
            let boundName = iface != nil ? name : nil
            // `force` fires even on nil->nil so enabling with no VPN still engages the kill-switch.
            guard force || boundName != currentName else { return }
            currentName = boundName
            NetworkBinding.shared.requiredInterface = iface  // pin new sockets to the tunnel (or unbind)
            onChange?(boundName)
        }

        /// The anonymizing VPN interface: the one actually carrying internet traffic, but only when
        /// it's a confirmed VPN tunnel. Returns nil when the internet egress is a physical interface
        /// (no full-tunnel VPN) or a split-tunnel overlay that doesn't carry general traffic.
        static func anonymizingVPNName() -> String? {
            guard let egress = internetEgressInterfaceName(), isVPNName(egress),
                vpnInterfaces(from: enumerate()).contains(egress)
            else { return nil }
            return egress
        }

        /// The interface that would actually carry a connection to the public internet right now.
        ///
        /// A connected (but never-sending) UDP socket to a public address lets the kernel pick the
        /// egress, then getsockname reports the source it chose; we map that address back to an
        /// interface. This respects the *real* routing -- including the split-default trick full-tunnel
        /// VPNs like AdGuard use (they route public traffic through the tunnel via 0.0.0.0/1 +
        /// 128.0.0.0/1 while leaving the literal default route on the physical interface). Reading the
        /// literal default route would miss those and see the physical interface instead.
        static func internetEgressInterfaceName() -> String? {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var dest = sockaddr_in()
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = in_port_t(53).bigEndian
            inet_pton(AF_INET, "8.8.8.8", &dest.sin_addr)  // a public address; no packet is ever sent
            let connected = withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return nil }
            var local = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            guard named == 0 else { return nil }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(buf.count))
            return interfaceName(forIPv4: String(cString: buf))
        }

        /// The interface that owns a given IPv4 address (via getifaddrs), or nil.
        static func interfaceName(forIPv4 ip: String) -> String? {
            var head: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&head) == 0, let start = head else { return nil }
            defer { freeifaddrs(head) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = start
            while let ptr = cursor {
                let ifa = ptr.pointee
                cursor = ifa.ifa_next
                guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                    String(cString: host) == ip {
                    return String(cString: ifa.ifa_name)
                }
            }
            return nil
        }

        // MARK: classification (pure, unit-tested)

        /// One address of one interface, reduced to the flags that decide VPN-ness.
        struct Addr: Equatable {
            let name: String
            let isUp: Bool
            let isPointToPoint: Bool
            let isRoutable: Bool  // has a non-link-local, non-loopback address
        }

        /// Names of interfaces that look like a live VPN tunnel: a VPN-style name that is up,
        /// point-to-point, and carries at least one routable address. Grouping by name lets a tunnel
        /// with only an IPv6 link-local address (a system utun) be told apart from a real one.
        static func vpnInterfaces(from addrs: [Addr]) -> Set<String> {
            var byName: [String: (up: Bool, p2p: Bool, routable: Bool)] = [:]
            for a in addrs where isVPNName(a.name) {
                var e = byName[a.name] ?? (false, false, false)
                e.up = e.up || a.isUp
                e.p2p = e.p2p || a.isPointToPoint
                e.routable = e.routable || a.isRoutable
                byName[a.name] = e
            }
            return Set(byName.filter { $0.value.up && $0.value.p2p && $0.value.routable }.keys)
        }

        /// Whether an interface name matches a VPN tunnel family (utun, ppp, ipsec, tun, tap, wg).
        static func isVPNName(_ name: String) -> Bool {
            ["utun", "ppp", "ipsec", "tun", "tap", "wg"].contains { name.hasPrefix($0) }
        }

        /// Whether a numeric address string is link-local or loopback (i.e. not routable).
        static func isLinkLocalOrLoopback(_ addr: String) -> Bool {
            let a = addr.lowercased()
            return a.hasPrefix("127.") || a.hasPrefix("169.254.")
                || a.hasPrefix("fe80:") || a == "::1" || a.hasPrefix("::1%")
        }

        // MARK: getifaddrs

        /// Snapshot every interface address on the host, reduced to `Addr` flags.
        static func enumerate() -> [Addr] {
            var head: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&head) == 0, let start = head else { return [] }
            defer { freeifaddrs(head) }
            var out: [Addr] = []
            var cursor: UnsafeMutablePointer<ifaddrs>? = start
            while let ptr = cursor {
                let ifa = ptr.pointee
                cursor = ifa.ifa_next
                guard let sa = ifa.ifa_addr else { continue }
                let family = sa.pointee.sa_family
                guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
                let name = String(cString: ifa.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
                else { continue }
                let addr = String(cString: host)
                let up = (ifa.ifa_flags & UInt32(IFF_UP)) != 0
                let p2p = (ifa.ifa_flags & UInt32(IFF_POINTOPOINT)) != 0
                out.append(Addr(name: name, isUp: up, isPointToPoint: p2p, isRoutable: !isLinkLocalOrLoopback(addr)))
            }
            return out
        }

        private static let queue = DispatchQueue(label: "com.pathem.torrent.vpnmonitor")
    }
#endif
