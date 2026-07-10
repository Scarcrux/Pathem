import Foundation

#if canImport(Network)
    import Network

    /// Watches the network and reports which VPN tunnel, if any, is currently active -- so the engine
    /// can bind torrent traffic to it and pull a kill-switch when it drops.
    ///
    /// Detecting a VPN on macOS is subtler than "the name starts with utun": a Mac routinely has half
    /// a dozen `utunN` interfaces for Continuity, iCloud Private Relay, and the like, all carrying
    /// only an IPv6 link-local address. A real tunnel is a **point-to-point, up interface with a
    /// VPN-style name AND a routable (non-link-local) address**. We confirm that from `getifaddrs`,
    /// then match it to an `NWInterface` that `NWPathMonitor` reports so it can actually be bound.
    public actor VPNMonitor {
        private let monitor = NWPathMonitor()
        private var currentName: String?
        private var onChange: (@Sendable (NWInterface?) -> Void)?
        private var started = false

        public init() {}

        /// Start watching. `onChange` fires whenever the active VPN interface changes (including to
        /// `nil` when the tunnel drops), on the monitor's queue. Idempotent.
        public func start(onChange: @escaping @Sendable (NWInterface?) -> Void) {
            guard !started else { return }
            started = true
            self.onChange = onChange
            monitor.pathUpdateHandler = { [weak self] path in
                Task { await self?.evaluate(path) }
            }
            monitor.start(queue: Self.queue)
        }

        public func stop() {
            monitor.cancel()
            started = false
        }

        /// The active VPN interface name right now (nil if none), computed on demand from getifaddrs.
        public func activeVPNName() -> String? {
            Self.vpnInterfaces(from: Self.enumerate()).sorted().first
        }

        private func evaluate(_ path: NWPath) {
            let confirmed = Self.vpnInterfaces(from: Self.enumerate())
            // Bind only to a tunnel the path layer also exposes (so we have an NWInterface for it).
            let iface = path.availableInterfaces.first { confirmed.contains($0.name) }
            if iface?.name != currentName {
                currentName = iface?.name
                onChange?(iface)
            }
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
