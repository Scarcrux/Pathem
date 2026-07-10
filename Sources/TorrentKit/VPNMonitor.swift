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

        /// The anonymizing VPN interface: the one carrying the default route, but only when it's a
        /// confirmed VPN tunnel. Returns nil when the default route is a physical interface (no
        /// full-tunnel VPN) or a split-tunnel overlay that isn't the default route.
        static func anonymizingVPNName() -> String? {
            guard let route = defaultRouteInterfaceName(), isVPNName(route),
                vpnInterfaces(from: enumerate()).contains(route)
            else { return nil }
            return route
        }

        /// The name of the interface carrying the IPv4 default route (0.0.0.0/0), via the routing
        /// table. This is the interface a full-tunnel VPN takes over when it connects.
        static func defaultRouteInterfaceName() -> String? {
            var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
            var needed = 0
            guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: needed)
            guard sysctl(&mib, u_int(mib.count), &buf, &needed, nil, 0) == 0 else { return nil }
            var result: String?
            buf.withUnsafeBytes { raw in
                var offset = 0
                while offset + MemoryLayout<rt_msghdr>.size <= needed {
                    let hdr = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                    guard hdr.rtm_msglen > 0 else { break }
                    // The first sockaddr after the header is the destination; 0.0.0.0 marks default.
                    let saOffset = offset + MemoryLayout<rt_msghdr>.size
                    if saOffset + MemoryLayout<sockaddr_in>.size <= needed {
                        let dst = raw.loadUnaligned(fromByteOffset: saOffset, as: sockaddr_in.self)
                        if dst.sin_family == UInt8(AF_INET), dst.sin_addr.s_addr == 0 {
                            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                            if if_indextoname(UInt32(hdr.rtm_index), &name) != nil {
                                result = String(cString: name)
                                return
                            }
                        }
                    }
                    offset += Int(hdr.rtm_msglen)
                }
            }
            return result
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
