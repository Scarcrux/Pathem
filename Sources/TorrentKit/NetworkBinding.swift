import Foundation

#if canImport(Network)
    import Network

    /// Process-wide interface binding for every torrent socket. When an interface is set, all peer,
    /// DHT, and µTP connections are pinned to it (the VPN tunnel), so traffic physically cannot leave
    /// over any other interface even if the routing table would allow it -- the enforcement half of
    /// the VPN kill-switch. `nil` (the default) means unbound: sockets follow the system route.
    ///
    /// This is deliberately a process-global: interface binding is an all-or-nothing property of the
    /// whole torrent engine, and threading an interface through every connection call site would only
    /// obscure that. Reads happen on many connection queues, so access is lock-guarded.
    final class NetworkBinding: @unchecked Sendable {
        static let shared = NetworkBinding()
        private let lock = NSLock()
        private var _interface: NWInterface?

        var requiredInterface: NWInterface? {
            get { lock.lock(); defer { lock.unlock() }; return _interface }
            set { lock.lock(); _interface = newValue; lock.unlock() }
        }

        /// Return `base`, pinned to the bound interface if one is set. Call at every NWConnection /
        /// NWListener creation site so binding is uniform.
        func pin(_ base: NWParameters) -> NWParameters {
            if let iface = requiredInterface { base.requiredInterface = iface }
            return base
        }
    }
#endif
